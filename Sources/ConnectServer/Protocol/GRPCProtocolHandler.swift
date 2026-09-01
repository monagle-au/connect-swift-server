// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes
import HummingbirdCore
import NIOCore
import Synchronization

// MARK: - GRPCProtocolHandler

/// Handles native gRPC unary RPCs over HTTP/2.
///
/// Wire format:
/// - Request body:  [5-byte header: flags + length][protobuf message]
/// - Response body: [5-byte header][proto response]
/// - Trailers (HTTP/2): grpc-status, grpc-message, and any trailing metadata
///
/// Note: gRPC requires HTTP/2. Hummingbird passes HTTP/2 trailers via
/// `ResponseBodyWriter.finish(_ trailingHeaders: HTTPFields?)`.
struct GRPCProtocolHandler: WireProtocolHandler {
    let errorLogger: ConnectRouter.ErrorLogger?

    func handle(
        request: Request,
        body: ByteBuffer,
        handler: MethodHandler,
        codec: any MessageCodec
    ) async -> Response {
        var mutableBody = body
        let messagePayload: ByteBuffer
        do {
            let (header, payload) = try Envelope.readMessage(from: &mutableBody)
            guard !header.isCompressed else {
                return grpcErrorResponse(RPCError(code: .unimplemented, message: "Compression not supported"))
            }
            messagePayload = payload
        } catch {
            return grpcErrorResponse(reportRPCError(
                RPCError(code: .internalError, message: "Failed to decode gRPC frame: \(error)"),
                descriptor: handler.descriptor
            ))
        }

        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])

        let responseHeaders: HTTPFields = {
            var h = HTTPFields()
            h[.contentType] = "application/grpc+proto"
            return h
        }()

        return await withServerContextRPCCancellationHandle { cancellationHandle in
            let context = ServerContext(
                descriptor: handler.descriptor,
                remotePeer: "unknown",
                localPeer: "unknown",
                cancellation: cancellationHandle
            )
            guard let unaryFn = handler.handleUnary else {
                return grpcErrorResponse(RPCError(code: .internalError, message: "Handler is not unary"))
            }
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await unaryFn(messagePayload, metadata, codec, context)
                }
                let dataFrame = Envelope.frameMessage(outputBytes)
                let trailers = Self.trailerFields(status: 0, message: nil, metadata: trailingMetadata)
                let body = ResponseBody { writer in
                    try await writer.write(dataFrame)
                    try await writer.finish(trailers)
                }
                return Response(status: .ok, headers: responseHeaders, body: body)
            } catch {
                return grpcErrorResponse(reportRPCError(error, descriptor: handler.descriptor))
            }
        }
    }

    // MARK: - Trailer building

    private static func trailerFields(
        status: Int,
        message: String?,
        metadata: GRPCCore.Metadata
    ) -> HTTPFields {
        var fields = HTTPFields()
        // HTTPField.Name must be constructed from lowercase strings
        if let grpcStatus = HTTPField.Name("grpc-status") {
            fields[grpcStatus] = "\(status)"
        }
        if let msg = message, !msg.isEmpty, let grpcMessage = HTTPField.Name("grpc-message") {
            fields[grpcMessage] = msg
        }
        for element in metadata {
            let key = element.key.lowercased()
            switch element.value {
            case .string(let v):
                if let name = HTTPField.Name(key) {
                    fields.append(HTTPField(name: name, value: v))
                }
            case .binary(let bytes):
                if let name = HTTPField.Name(key) {
                    fields.append(HTTPField(name: name, value: Data(bytes).base64EncodedString()))
                }
            }
        }
        return fields
    }

    // MARK: - Server-streaming

    func handleServerStreaming(
        request: Request,
        body: ByteBuffer,
        handler: MethodHandler,
        codec: any MessageCodec
    ) async -> Response {
        var mutableBody = body
        let messagePayload: ByteBuffer
        do {
            let (header, payload) = try Envelope.readMessage(from: &mutableBody)
            guard !header.isCompressed else {
                return grpcErrorResponse(RPCError(code: .unimplemented, message: "Compression not supported"))
            }
            messagePayload = payload
        } catch {
            return grpcErrorResponse(reportRPCError(
                RPCError(code: .internalError, message: "Failed to decode gRPC frame: \(error)"),
                descriptor: handler.descriptor
            ))
        }

        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])
        let descriptor = handler.descriptor
        let logger = errorLogger
        guard let serverStreamingHandler = handler.handleServerStreaming else {
            return grpcErrorResponse(RPCError(code: .internalError, message: "Handler is not server-streaming"))
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/grpc+proto"

        let body = ResponseBody { writer in
            var streamWriter = writer

            var continuation: AsyncStream<ByteBuffer>.Continuation!
            let stream = AsyncStream<ByteBuffer> { c in continuation = c }
            let cont = continuation!

            let cancellationBox = Mutex<ServerContext.RPCCancellationHandle?>(nil)
            let task = Task<GRPCCore.Metadata, any Error> {
                // Always finish the stream so the drain loop exits, even on throw.
                defer { cont.finish() }
                return try await withServerContextRPCCancellationHandle { cancellationHandle in
                    cancellationBox.withLock { $0 = cancellationHandle }
                    let context = ServerContext(
                        descriptor: descriptor,
                        remotePeer: "unknown",
                        localPeer: "unknown",
                        cancellation: cancellationHandle
                    )
                    return try await Timeout.withDeadline(deadline) {
                        try await serverStreamingHandler(
                            messagePayload, metadata, codec, context,
                            { bytes in
                                cont.yield(Envelope.frameMessage(bytes))
                            }
                        )
                    }
                }
            }
            // If the drain below exits early — the peer vanished and a write
            // threw — tear the producer down: cancel the RPC handle (wakes
            // handlers watching context.cancellation) and the producer task.
            // Idempotent no-op on the happy path.
            defer {
                cancellationBox.withLock { $0 }?.cancel()
                task.cancel()
            }

            for await frame in stream {
                try await streamWriter.write(frame)
            }

            // Final HTTP/2 trailers carry status; no trailer frame in body for native gRPC.
            let trailerFields: HTTPFields
            do {
                let trailingMetadata = try await task.value
                trailerFields = Self.trailerFields(status: 0, message: nil, metadata: trailingMetadata)
            } catch {
                let rpc = Self.reportRPCError(error, descriptor: descriptor, logger: logger)
                trailerFields = Self.trailerFields(
                    status: StatusMapping.grpcStatusCode(for: rpc.code),
                    message: rpc.message,
                    metadata: GRPCCore.Metadata()
                )
            }
            try await streamWriter.finish(trailerFields)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - Client-streaming

    func handleClientStreaming(
        request: Request,
        handler: MethodHandler,
        codec: any MessageCodec,
        maxMessageBytes: Int
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])
        let descriptor = handler.descriptor
        guard let clientStreamingHandler = handler.handleClientStreaming else {
            return grpcErrorResponse(RPCError(code: .internalError, message: "Handler is not client-streaming"))
        }

        let inputBytesStream = EnvelopeStream.messages(from: request.body, maxMessageBytes: maxMessageBytes)

        var headers = HTTPFields()
        headers[.contentType] = "application/grpc+proto"

        return await withServerContextRPCCancellationHandle { handle in
            let context = ServerContext(
                descriptor: descriptor, remotePeer: "unknown", localPeer: "unknown", cancellation: handle
            )
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await clientStreamingHandler(inputBytesStream, metadata, codec, context)
                }
                let dataFrame = Envelope.frameMessage(outputBytes)
                let trailers = Self.trailerFields(status: 0, message: nil, metadata: trailingMetadata)
                let body = ResponseBody { writer in
                    try await writer.write(dataFrame)
                    try await writer.finish(trailers)
                }
                return Response(status: .ok, headers: headers, body: body)
            } catch {
                return grpcErrorResponse(reportRPCError(error, descriptor: descriptor))
            }
        }
    }

    // MARK: - Bidirectional

    func handleBidi(
        request: Request,
        handler: MethodHandler,
        codec: any MessageCodec,
        maxMessageBytes: Int
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])
        let descriptor = handler.descriptor
        let logger = errorLogger
        guard let bidiHandler = handler.handleBidi else {
            return grpcErrorResponse(RPCError(code: .internalError, message: "Handler is not bidirectional"))
        }

        let inputBytesStream = EnvelopeStream.messages(from: request.body, maxMessageBytes: maxMessageBytes)

        var headers = HTTPFields()
        headers[.contentType] = "application/grpc+proto"

        let body = ResponseBody { writer in
            var streamWriter = writer

            var continuation: AsyncStream<ByteBuffer>.Continuation!
            let stream = AsyncStream<ByteBuffer> { c in continuation = c }
            let cont = continuation!

            let cancellationBox = Mutex<ServerContext.RPCCancellationHandle?>(nil)
            let task = Task<GRPCCore.Metadata, any Error> {
                defer { cont.finish() }
                return try await withServerContextRPCCancellationHandle { cancellationHandle in
                    cancellationBox.withLock { $0 = cancellationHandle }
                    let context = ServerContext(
                        descriptor: descriptor,
                        remotePeer: "unknown",
                        localPeer: "unknown",
                        cancellation: cancellationHandle
                    )
                    return try await Timeout.withDeadline(deadline) {
                        try await bidiHandler(
                            inputBytesStream, metadata, codec, context,
                            { bytes in
                                cont.yield(Envelope.frameMessage(bytes))
                            }
                        )
                    }
                }
            }
            // Tear the producer down if the drain exits early (dead peer).
            defer {
                cancellationBox.withLock { $0 }?.cancel()
                task.cancel()
            }

            for await frame in stream {
                try await streamWriter.write(frame)
            }

            let trailerFields: HTTPFields
            do {
                let trailingMetadata = try await task.value
                trailerFields = Self.trailerFields(status: 0, message: nil, metadata: trailingMetadata)
            } catch {
                let rpc = Self.reportRPCError(error, descriptor: descriptor, logger: logger)
                trailerFields = Self.trailerFields(
                    status: StatusMapping.grpcStatusCode(for: rpc.code),
                    message: rpc.message,
                    metadata: GRPCCore.Metadata()
                )
            }
            try await streamWriter.finish(trailerFields)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    private func grpcErrorResponse(_ rpcError: RPCError) -> Response {
        let statusCode = StatusMapping.grpcStatusCode(for: rpcError.code)
        let trailers = Self.trailerFields(
            status: statusCode,
            message: rpcError.message,
            metadata: GRPCCore.Metadata()
        )
        var responseHeaders = HTTPFields()
        responseHeaders[.contentType] = "application/grpc+proto"
        let body = ResponseBody { writer in
            try await writer.finish(trailers)
        }
        return Response(status: .ok, headers: responseHeaders, body: body)
    }
}

import Foundation
