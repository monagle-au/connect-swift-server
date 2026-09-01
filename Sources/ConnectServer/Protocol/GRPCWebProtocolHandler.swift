// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore
import HTTPTypes
import HummingbirdCore
import NIOCore
import Synchronization

// MARK: - GRPCWebProtocolHandler

/// Handles gRPC-Web unary RPCs (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md).
///
/// Wire format:
/// - Request body:  [5-byte header: flags + length][protobuf message]
/// - Response body: [5-byte header][proto response] [5-byte trailer header 0x80][trailer block]
struct GRPCWebProtocolHandler: WireProtocolHandler {
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
            // Reject compressed frames — compression not supported in Phase 1.
            guard !header.isCompressed else {
                return grpcWebErrorResponse(
                    RPCError(code: .unimplemented, message: "Compression not supported")
                )
            }
            messagePayload = payload
        } catch {
            return grpcWebErrorResponse(reportRPCError(
                RPCError(code: .internalError, message: "Failed to decode gRPC-Web frame: \(error)"),
                descriptor: handler.descriptor
            ))
        }

        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])

        return await withServerContextRPCCancellationHandle { cancellationHandle in
            let context = ServerContext(
                descriptor: handler.descriptor,
                remotePeer: "unknown",
                localPeer: "unknown",
                cancellation: cancellationHandle
            )
            guard let unaryFn = handler.handleUnary else {
                return grpcWebErrorResponse(RPCError(code: .internalError, message: "Handler is not unary"))
            }
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await unaryFn(messagePayload, metadata, codec, context)
                }
                return grpcWebSuccessResponse(
                    responseBytes: outputBytes,
                    trailingMetadata: trailingMetadata,
                    contentType: request.headers[.contentType] ?? "application/grpc-web+proto"
                )
            } catch {
                return grpcWebErrorResponse(reportRPCError(error, descriptor: handler.descriptor))
            }
        }
    }

    // MARK: - Response building

    private func grpcWebSuccessResponse(
        responseBytes: ByteBuffer,
        trailingMetadata: GRPCCore.Metadata,
        contentType: String
    ) -> Response {
        let dataFrame = Envelope.frameMessage(responseBytes)
        let trailerFrame = GRPCWebTrailers.frame(status: 0, message: nil, metadata: trailingMetadata)

        var headers = HTTPFields()
        if let name = HTTPField.Name("content-type") {
            headers[name] = contentType
        }

        let body = ResponseBody { writer in
            try await writer.write(dataFrame)
            try await writer.write(trailerFrame)
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - Server-streaming

    func handleServerStreaming(
        request: Request,
        body: ByteBuffer,
        handler: MethodHandler,
        codec: any MessageCodec
    ) async -> Response {
        // Parse single input frame from the request body (same as unary).
        var mutableBody = body
        let messagePayload: ByteBuffer
        do {
            let (header, payload) = try Envelope.readMessage(from: &mutableBody)
            guard !header.isCompressed else {
                return grpcWebErrorResponse(RPCError(code: .unimplemented, message: "Compression not supported"))
            }
            messagePayload = payload
        } catch {
            return grpcWebErrorResponse(reportRPCError(
                RPCError(code: .internalError, message: "Failed to decode gRPC-Web frame: \(error)"),
                descriptor: handler.descriptor
            ))
        }

        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseGRPC(request.headers[HTTPField.Name("grpc-timeout")!])
        let descriptor = handler.descriptor
        // Capture for the @Sendable ResponseBody closure — see WireProtocolHandler
        // for the static helper that takes the captured logger.
        let logger = errorLogger
        guard let serverStreamingHandler = handler.handleServerStreaming else {
            return grpcWebErrorResponse(RPCError(code: .internalError, message: "Handler is not server-streaming"))
        }

        var headers = HTTPFields()
        if let name = HTTPField.Name("content-type") {
            headers[name] = request.headers[.contentType] ?? "application/grpc-web+proto"
        }

        let body = ResponseBody { writer in
            // Bridge the user handler's output (raw message bytes) to the response writer
            // by framing each output and emitting it.
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
                                let frame = Envelope.frameMessage(bytes)
                                cont.yield(frame)
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

            // Drain frames as the handler emits them.
            for await frame in stream {
                try await streamWriter.write(frame)
            }

            // Wait for the handler's final result. Append a status trailer frame either way.
            let trailerFrame: ByteBuffer
            do {
                let trailingMetadata = try await task.value
                trailerFrame = GRPCWebTrailers.frame(status: 0, message: nil, metadata: trailingMetadata)
            } catch {
                let rpc = Self.reportRPCError(error, descriptor: descriptor, logger: logger)
                trailerFrame = GRPCWebTrailers.frame(
                    status: StatusMapping.grpcStatusCode(for: rpc.code),
                    message: rpc.message,
                    metadata: GRPCCore.Metadata()
                )
            }
            try await streamWriter.write(trailerFrame)
            try await streamWriter.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - Client-streaming

    /// gRPC-Web client-streaming: read enveloped messages from request body,
    /// return one data frame + trailer frame.
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
            return grpcWebErrorResponse(RPCError(code: .internalError, message: "Handler is not client-streaming"))
        }

        let inputBytesStream = EnvelopeStream.messages(from: request.body, maxMessageBytes: maxMessageBytes)

        return await withServerContextRPCCancellationHandle { handle in
            let context = ServerContext(
                descriptor: descriptor, remotePeer: "unknown", localPeer: "unknown", cancellation: handle
            )
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await clientStreamingHandler(inputBytesStream, metadata, codec, context)
                }
                return grpcWebSuccessResponse(
                    responseBytes: outputBytes,
                    trailingMetadata: trailingMetadata,
                    contentType: request.headers[.contentType] ?? "application/grpc-web+proto"
                )
            } catch {
                return grpcWebErrorResponse(reportRPCError(error, descriptor: descriptor))
            }
        }
    }

    private func grpcWebErrorResponse(_ rpcError: RPCError) -> Response {
        let trailerFrame = GRPCWebTrailers.frame(
            status: StatusMapping.grpcStatusCode(for: rpcError.code),
            message: rpcError.message,
            metadata: GRPCCore.Metadata()
        )
        var headers = HTTPFields()
        headers[.contentType] = "application/grpc-web+proto"

        let body = ResponseBody { writer in
            try await writer.write(trailerFrame)
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }
}
