# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from `1.0.0` onwards.

## [Unreleased]

## [1.2.0] — 2026-09-01

### Added

- `protoc-gen-connect-swift-server` now emits **metadata-aware** handler
  signatures for unary and server-streaming methods
  (`ServerRequest`/`ServerResponse`, trailing `Metadata`), so generated
  handlers can read request headers — auth tokens, locales — and return
  trailing metadata. Client-streaming and bidi keep the stream-based
  signatures.
- Generator options, matching protoc-gen-swift conventions:
  `Visibility=Internal|Public|Package`, `ProtoPathModuleMappings=<path>`,
  and `ExtraModuleImports=<Module>` (repeatable) — generated bindings can
  now live in a separate module from the generated messages.
- The generator honours the `swift_prefix` file option for service type
  names, matching how the message types are named.
- Generator logic extracted into a `ConnectServerGenerator` library
  target with a unit-test suite; the executable is a thin wrapper.

### Fixed

- **Streaming producers are torn down when the client disconnects.** The
  drain loop's write failure unwound the response body but left the
  handler's producer task running forever against an unbounded stream,
  with `context.cancellation` never firing. All five streaming bodies now
  cancel both the RPC handle and the producer task on early drain exit.
- **`serve()` no longer claims process signals.** It ran the Hummingbird
  application via `runService()`, whose convenience `ServiceGroup`
  installs its own `SIGTERM`/`SIGINT` handlers — capturing the signal at
  the wrong layer when embedded under an application-owned lifecycle.
  `serve()` now runs the `Application` directly; termination is by task
  cancellation or graceful shutdown, owned by the caller.
- Non-`RPCError` handler failures now serialise a generic
  `internal error` message instead of `String(describing:)`, which could
  put internal detail (e.g. database errors) on the wire. The
  `errorLogger` still receives the original error.

## [1.1.0] — 2026-05-10

### Added

- Optional `errorLogger` callback on `ConnectRouter`, invoked with the
  original error and method descriptor before serialisation — the
  router's hook for centralised error reporting.

### Changed

- Error reporting deduplicated across the three protocol handlers via an
  internal `WireProtocolHandler` protocol.

## [1.0.0] — 2026-05-06

Initial stable release.

- Serves grpc-swift-2 service handlers over **Connect** (JSON/proto),
  **gRPC-Web**, and **native gRPC** on a single Hummingbird HTTP port,
  with content-type-based protocol detection.
- `ConnectRouter` type-safe registration API for unary, server-streaming,
  client-streaming, and bidirectional methods.
- `protoc-gen-connect-swift-server` protoc/buf plugin emitting
  registration bindings per service.
- CORS (permissive/strict/custom), `grpc.health.v1` health service,
  Connect and gRPC deadline handling, `maxMessageBytes` guard, and
  plaintext HTTP/1.1, plaintext HTTP/2 (h2c), and TLS (ALPN) transports.
- Distributed-tracing integration: incoming context extraction and a
  server span per RPC.
- `serve()` normalises cancellation so an enclosing `ServiceGroup`
  classifies shutdown as expected.

[Unreleased]: https://github.com/monagle-au/connect-swift-server/compare/1.2.0...HEAD
[1.2.0]: https://github.com/monagle-au/connect-swift-server/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/monagle-au/connect-swift-server/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/monagle-au/connect-swift-server/releases/tag/1.0.0
