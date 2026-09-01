// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Hummingbird
import HummingbirdCore
import HummingbirdHTTP2
import NIOSSL

// MARK: - ConnectServer

/// An HTTP server that serves grpc-swift-2 service handlers over Connect, gRPC-Web, and gRPC.
///
/// Minimal usage:
/// ```swift
/// var router = ConnectRouter()
/// router.registerUnary(method: ..., requestType: ..., responseType: ...) { req, ctx in ... }
/// let server = ConnectServer(address: .hostname("0.0.0.0", port: 8080), router: router)
/// try await server.serve()
/// ```
public struct ConnectServer: Sendable {
    private let address: BindAddress
    private let transportSecurity: TransportSecurity
    private let router: ConnectRouter

    // MARK: - Init

    public init(
        address: BindAddress = .hostname("127.0.0.1", port: 8080),
        transportSecurity: TransportSecurity = .plaintext,
        router: ConnectRouter
    ) {
        self.address = address
        self.transportSecurity = transportSecurity
        self.router = router
    }

    // MARK: - Lifecycle

    /// Starts the server and runs until cancelled or shutdown is requested.
    ///
    /// Runs the Hummingbird `Application` directly as a
    /// `ServiceLifecycle.Service` — deliberately NOT `runService()`, whose
    /// convenience `ServiceGroup` installs its own `SIGTERM`/`SIGINT`
    /// handlers. A library must not capture process signals: when embedded
    /// under an application-owned `ServiceGroup`, that inner registration
    /// steals the signal, drains only the HTTP listener, and leaves the rest
    /// of the application running. Signal handling belongs to the caller;
    /// this method terminates on task cancellation or graceful shutdown.
    public func serve() async throws {
        let serverBuilder: HTTPServerBuilder = try transportSecurity.makeServerBuilder()
        let configuration = ApplicationConfiguration(address: address)
        let app = Application(
            responder: router,
            server: serverBuilder,
            configuration: configuration
        )
        // Re-surface task cancellation as CancellationError so an outer
        // ServiceGroup classifies the termination as expected. Hummingbird
        // sometimes returns cleanly on cancel and sometimes throws a
        // ServiceGroupError if one of its internal services (e.g. DateCache)
        // exits before the group's cancel signal propagates — normalize both.
        do {
            try await app.run()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
    }
}

// MARK: - TransportSecurity

/// Configures TLS or plaintext for the ConnectServer.
public enum TransportSecurity: Sendable {
    case plaintext
    case plaintextHTTP2
    case tls(TLSConfiguration)

    fileprivate func makeServerBuilder() throws -> HTTPServerBuilder {
        switch self {
        case .plaintext:
            return .http1()
        case .plaintextHTTP2:
            return .plaintextHTTP2()
        case .tls(let tlsConfig):
            return try .http2Upgrade(tlsConfiguration: tlsConfig)
        }
    }
}
