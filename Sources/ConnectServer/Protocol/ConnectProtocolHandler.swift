// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import HummingbirdCore
import NIOCore
import Synchronization

// MARK: - ConnectProtocolHandler

/// Handles the Connect RPC protocol (https://connectrpc.com/docs/protocol/) for unary RPCs.
///
/// - Validates `Connect-Protocol-Version: 1` header.
/// - Reads `Connect-Timeout-Ms` header.
/// - Passes request headers (minus framing headers) as `GRPCCore.Metadata` to handlers.
/// - Returns trailing metadata as `Trailer-*` prefixed response headers.
/// - Returns errors as JSON error envelopes with appropriate HTTP status codes.
struct ConnectProtocolHandler: WireProtocolHandler {
    let errorLogger: ConnectRouter.ErrorLogger?

    func handle(
        request: Request,
        body: ByteBuffer,
        handler: MethodHandler,
        codec: any MessageCodec
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseConnect(request.headers[HTTPField.Name("connect-timeout-ms")!])

        return await withServerContextRPCCancellationHandle { cancellationHandle in
            let context = ServerContext(
                descriptor: handler.descriptor,
                remotePeer: "unknown",
                localPeer: "unknown",
                cancellation: cancellationHandle
            )
            guard let unaryFn = handler.handleUnary else {
                return errorResponse(RPCError(code: .internalError, message: "Handler is not unary"))
            }
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await unaryFn(body, metadata, codec, context)
                }
                return successResponse(
                    bytes: outputBytes,
                    contentType: codec.contentType,
                    trailingMetadata: trailingMetadata
                )
            } catch {
                return errorResponse(reportRPCError(error, descriptor: handler.descriptor))
            }
        }
    }

    // MARK: - Response building

    private func successResponse(
        bytes: ByteBuffer,
        contentType: String,
        trailingMetadata: GRPCCore.Metadata
    ) -> Response {
        var headers = HTTPFields()
        if let name = HTTPField.Name("content-type") {
            headers[name] = contentType
        }
        headers.appendTrailingMetadata(trailingMetadata)
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: bytes))
    }

    // MARK: - Server-streaming

    /// Connect server-streaming response format:
    ///   - Each output message: `[0x00, len(BE), bytes]`
    ///   - Final frame: `[0x02, len(BE), JSON({metadata?, error?})]` (EndStreamResponse)
    ///   - HTTP status is always 200; errors travel in the EndStreamResponse JSON.
    func handleServerStreaming(
        request: Request,
        body: ByteBuffer,
        handler: MethodHandler,
        codec: any MessageCodec
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseConnect(request.headers[HTTPField.Name("connect-timeout-ms")!])
        let descriptor = handler.descriptor
        guard let serverStreamingHandler = handler.handleServerStreaming else {
            return errorResponse(RPCError(code: .internalError, message: "Handler is not server-streaming"))
        }

        // Connect server-streaming requests use the enveloped streaming wire format.
        // Parse the single input envelope from the request body.
        let inputPayload: ByteBuffer
        do {
            var b = body
            if b.readableBytes >= Envelope.headerSize {
                let (header, payload) = try Envelope.readMessage(from: &b)
                guard !header.isCompressed else {
                    return errorResponse(RPCError(code: .unimplemented, message: "Compression not supported"))
                }
                inputPayload = payload
            } else {
                // Tolerate a non-enveloped body — pass raw bytes through.
                inputPayload = body
            }
        } catch {
            return errorResponse(RPCError(code: .invalidArgument, message: "Failed to decode Connect envelope: \(error)"))
        }

        // Connect server-streaming uses application/connect+(proto|json) for the response.
        let connectStreamingContentType: String
        if codec is JSONCodec {
            connectStreamingContentType = "application/connect+json"
        } else {
            connectStreamingContentType = "application/connect+proto"
        }

        var headers = HTTPFields()
        headers[.contentType] = connectStreamingContentType

        // Capture the logger for the @Sendable body closure (self can't
        // cross that boundary cleanly under strict concurrency).
        let logger = errorLogger

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
                            inputPayload, metadata, codec, context,
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

            // Build and write the EndStreamResponse envelope (flag 0x02).
            let endStream: ByteBuffer
            do {
                let trailingMetadata = try await task.value
                endStream = Self.endStreamFrame(metadata: trailingMetadata, error: nil)
            } catch {
                let rpc = Self.reportRPCError(error, descriptor: descriptor, logger: logger)
                endStream = Self.endStreamFrame(metadata: rpc.metadata, error: rpc)
            }
            try await streamWriter.write(endStream)
            try await streamWriter.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    /// Builds the final EndStreamResponse envelope `[0x02, len(BE), JSON]`.
    private static func endStreamFrame(metadata: GRPCCore.Metadata, error: RPCError?) -> ByteBuffer {
        // EndStreamResponse JSON: { "metadata": {key: [value, ...]}?, "error": {...}? }
        var dict: [String: any Sendable] = [:]

        var metadataDict: [String: [String]] = [:]
        for entry in metadata {
            switch entry.value {
            case .string(let s):
                metadataDict[entry.key, default: []].append(s)
            case .binary(let bytes):
                metadataDict[entry.key, default: []].append(Data(bytes).base64EncodedString())
            }
        }
        if !metadataDict.isEmpty {
            dict["metadata"] = metadataDict
        }
        if let error {
            var errorDict: [String: any Sendable] = [
                "code": StatusMapping.connectCode(for: error.code),
            ]
            if !error.message.isEmpty {
                errorDict["message"] = error.message
            }
            dict["error"] = errorDict
        }

        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: dict, options: [])
        } catch {
            json = Data("{}".utf8)
        }
        var payload = ByteBufferAllocator().buffer(capacity: json.count)
        payload.writeBytes(json)

        var frame = ByteBufferAllocator().buffer(capacity: Envelope.headerSize + payload.readableBytes)
        Envelope.write(flags: 0x02, payload: payload, into: &frame)
        return frame
    }

    // MARK: - Client-streaming

    /// Connect client-streaming response: one data frame + EndStreamResponse envelope.
    /// Content-Type: application/connect+(proto|json).
    func handleClientStreaming(
        request: Request,
        handler: MethodHandler,
        codec: any MessageCodec,
        maxMessageBytes: Int
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseConnect(request.headers[HTTPField.Name("connect-timeout-ms")!])
        let descriptor = handler.descriptor
        guard let clientStreamingHandler = handler.handleClientStreaming else {
            return errorResponse(RPCError(code: .internalError, message: "Handler is not client-streaming"))
        }

        let inputBytesStream = EnvelopeStream.messages(from: request.body, maxMessageBytes: maxMessageBytes)

        let connectStreamingContentType = (codec is JSONCodec) ? "application/connect+json" : "application/connect+proto"

        var headers = HTTPFields()
        headers[.contentType] = connectStreamingContentType

        return await withServerContextRPCCancellationHandle { handle in
            let context = ServerContext(
                descriptor: descriptor, remotePeer: "unknown", localPeer: "unknown", cancellation: handle
            )
            do {
                let (outputBytes, trailingMetadata) = try await Timeout.withDeadline(deadline) {
                    try await clientStreamingHandler(inputBytesStream, metadata, codec, context)
                }
                // Single output as enveloped data frame, then EndStreamResponse.
                let dataFrame = Envelope.frameMessage(outputBytes)
                let endStream = Self.endStreamFrame(metadata: trailingMetadata, error: nil)
                let body = ResponseBody { writer in
                    try await writer.write(dataFrame)
                    try await writer.write(endStream)
                    try await writer.finish(nil)
                }
                return Response(status: .ok, headers: headers, body: body)
            } catch {
                let rpc = reportRPCError(error, descriptor: descriptor)
                return connectStreamingErrorResponse(rpc, contentType: connectStreamingContentType)
            }
        }
    }

    // MARK: - Bidirectional

    /// Connect bidirectional: simultaneous read of input envelopes and write of output envelopes.
    /// Note: full duplex requires HTTP/2 (over HTTP/1.1, half-duplex behavior occurs naturally).
    func handleBidi(
        request: Request,
        handler: MethodHandler,
        codec: any MessageCodec,
        maxMessageBytes: Int
    ) async -> Response {
        let metadata = GRPCCore.Metadata(httpHeaders: request.headers)
        let deadline = Timeout.parseConnect(request.headers[HTTPField.Name("connect-timeout-ms")!])
        let descriptor = handler.descriptor
        guard let bidiHandler = handler.handleBidi else {
            return errorResponse(RPCError(code: .internalError, message: "Handler is not bidirectional"))
        }

        let inputBytesStream = EnvelopeStream.messages(from: request.body, maxMessageBytes: maxMessageBytes)
        let connectStreamingContentType = (codec is JSONCodec) ? "application/connect+json" : "application/connect+proto"

        var headers = HTTPFields()
        headers[.contentType] = connectStreamingContentType

        let logger = errorLogger

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

            let endStream: ByteBuffer
            do {
                let trailingMetadata = try await task.value
                endStream = Self.endStreamFrame(metadata: trailingMetadata, error: nil)
            } catch {
                let rpc = Self.reportRPCError(error, descriptor: descriptor, logger: logger)
                endStream = Self.endStreamFrame(metadata: rpc.metadata, error: rpc)
            }
            try await streamWriter.write(endStream)
            try await streamWriter.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    /// Builds a streaming error response: empty body + EndStreamResponse with error.
    private func connectStreamingErrorResponse(_ rpcError: RPCError, contentType: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = contentType
        let endStream = Self.endStreamFrame(metadata: rpcError.metadata, error: rpcError)
        let body = ResponseBody { writer in
            try await writer.write(endStream)
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    private func errorResponse(_ rpcError: RPCError) -> Response {
        let connectError = ConnectError(rpcError: rpcError)
        let httpStatus = StatusMapping.httpStatus(for: rpcError.code)
        guard let jsonBytes = try? connectError.jsonBytes() else {
            return Response(status: .internalServerError)
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        var body = ByteBufferAllocator().buffer(capacity: jsonBytes.count)
        body.writeBytes(jsonBytes)
        return Response(status: httpStatus, headers: headers, body: ResponseBody(byteBuffer: body))
    }
}
