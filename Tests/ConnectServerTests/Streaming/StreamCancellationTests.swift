// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Foundation
import GRPCCore
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Synchronization
import Testing

@testable import ConnectServer

// MARK: - Streaming producer teardown

/// When a streaming client disconnects, the response-body drain loop's write
/// throws and the body closure unwinds. The handler's producer task — and the
/// RPC cancellation handle its `ServerContext` watches — must be torn down
/// with it, or the handler loops forever against a dead connection.
@Suite("Streaming producer teardown")
struct StreamCancellationTests {
    /// Accepts `failAfter` body buffers, then throws — simulating a peer that
    /// vanished mid-stream.
    final class DisconnectingWriter: ResponseBodyWriter, @unchecked Sendable {
        struct PeerGone: Error {}
        private var remaining: Int

        init(failAfter: Int) { self.remaining = failAfter }

        func write(_ buffer: ByteBuffer) async throws {
            guard remaining > 0 else { throw PeerGone() }
            remaining -= 1
        }

        func write(contentsOf buffers: some Sequence<ByteBuffer>) async throws {
            for buffer in buffers { try await write(buffer) }
        }

        func finish(_ trailingHeaders: HTTPFields?) async throws {}
    }

    @Test("Server-streaming handler observes cancellation when the drain fails")
    func producerTornDownOnDeadPeer() async throws {
        var exitContinuation: AsyncStream<Void>.Continuation!
        let exitStream = AsyncStream<Void> { c in exitContinuation = c }
        let exitCont = exitContinuation!

        var router = ConnectRouter()
        router.registerServerStreaming(
            method: MethodDescriptor(fullyQualifiedService: "test.Leak", method: "Run"),
            requestType: TestPingMessage.self,
            responseType: TestPingMessage.self
        ) { (_: TestPingMessage, context: ServerContext, writer: ServerStreamWriter<TestPingMessage>) in
            // Mirrors a live-update loop: emit until the RPC is cancelled.
            defer {
                exitCont.yield()
                exitCont.finish()
            }
            while !context.cancellation.isCancelled {
                do { try await writer.write(TestPingMessage(text: "tick")) } catch { return }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }

        let codec = ProtoCodec()
        let payload = try codec.serialize(TestPingMessage(text: "start"))
        var head = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/test.Leak/Run")
        head.headerFields[.contentType] = "application/grpc+proto"
        let request = Request(head: head, body: .init(buffer: Envelope.frameMessage(payload)))
        let context = BasicRequestContext(
            source: ApplicationRequestContextSource(
                channel: EmbeddedChannel(), logger: Logger(label: "test")))

        let response = try await router.respond(to: request, context: context)

        // Drive the body with a writer that dies after the first frame.
        // Native gRPC surfaces the failure by rethrowing from write(_:).
        await #expect(throws: (any Error).self) {
            try await response.body.write(DisconnectingWriter(failAfter: 1))
        }

        // The producer must exit promptly; without teardown it loops forever.
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exitStream { return true }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(exited, "streaming producer was not torn down after the peer disconnected")
    }
}
