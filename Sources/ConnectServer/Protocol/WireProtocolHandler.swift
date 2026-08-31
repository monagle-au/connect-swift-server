// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import GRPCCore

/// Shared surface for the three wire-protocol handlers (Connect, gRPC-Web,
/// native gRPC).
///
/// Each handler holds an optional `errorLogger` set by the router at
/// construction time and shares the report-and-convert helper used in
/// every catch block. The protocol exists purely to dedupe that helper
/// — registration, dispatch, and error-response shape stay in the
/// concrete types because each protocol's wire format is different.
protocol WireProtocolHandler: Sendable {
    /// Per-router callback invoked from every catch block before the
    /// error is serialised to the wire. `nil` is the default and means
    /// "don't report".
    var errorLogger: ConnectRouter.ErrorLogger? { get }
}

extension WireProtocolHandler {
    /// Report a thrown handler error and convert it to an `RPCError`
    /// ready for serialisation.
    ///
    /// `RPCError`s pass through unchanged so the wire response keeps
    /// the handler's chosen code/message; everything else is wrapped as
    /// `.internalError` with a **generic** message — the description of
    /// an arbitrary error (a database failure, say) can carry internal
    /// detail that must not reach the wire. Always reports the original
    /// error (not the wrapped one) to the logger so consumers can match
    /// on their own error types and log the real detail.
    @inline(__always)
    func reportRPCError(
        _ error: any Error,
        descriptor: MethodDescriptor
    ) -> RPCError {
        errorLogger?(error, descriptor)
        return (error as? RPCError)
            ?? RPCError(code: .internalError, message: "internal error")
    }

    /// Static variant for use from `@Sendable` closures (streaming body
    /// writers) that can't capture `self`. Pass the captured logger in.
    @inline(__always)
    static func reportRPCError(
        _ error: any Error,
        descriptor: MethodDescriptor,
        logger: ConnectRouter.ErrorLogger?
    ) -> RPCError {
        logger?(error, descriptor)
        return (error as? RPCError)
            ?? RPCError(code: .internalError, message: "internal error")
    }
}
