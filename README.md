# connect-swift-server

A Swift server library that serves grpc-swift-2 service handlers over **Connect**, **gRPC-Web**, and **gRPC** simultaneously on a single HTTP port — so browsers and native clients can talk to one Swift backend without a translation proxy.

## Protocol support

| Protocol | Unary | Server streaming | Client streaming | Bidirectional |
|---|---|---|---|---|
| **Connect** | ✅ JSON + proto | ✅ JSON + proto | ✅ JSON + proto | ✅ JSON + proto |
| **gRPC-Web** | ✅ proto | ✅ proto | ✅ proto | ❌ (not part of spec) |
| **gRPC** | ✅ HTTP/2 | ✅ HTTP/2 | ✅ HTTP/2 | ✅ HTTP/2 |

Other features:
- **Distributed tracing** — one span per RPC via `swift-distributed-tracing`, with OpenTelemetry RPC semantic conventions
- **Timeouts** — `Connect-Timeout-Ms` (Connect) and `grpc-timeout` (gRPC, gRPC-Web) honored, returning `deadline_exceeded` on expiry
- **CORS** — built-in, configurable via `ConnectRouter(cors:)`, spec-compliant defaults for `@connectrpc/connect-web` and `grpc-web`
- **Health checks** — full `grpc.health.v1.Health` (`Check` + `Watch`) via the `HealthService` helper
- **Max-message-size enforcement** — per-message cap (default 4 MiB) returning `resource_exhausted` on violation
- **swift-configuration integration** — optional `init(reader:)` overloads that read settings from any `ConfigReader`
- **Protoc plugin** — `protoc-gen-connect-swift-server` generates registration helpers from `.proto` files

## Requirements

- Swift 6.2+
- macOS 15.0+

## Usage

```swift
import ConnectServer
import GRPCCore

// 1. Implement the service (identical code to using GRPCServer)
struct Greeter: Helloworld_Greeter.SimpleServiceProtocol {
    func sayHello(
        request: Helloworld_HelloRequest,
        context: ServerContext
    ) async throws -> Helloworld_HelloReply {
        .with { $0.message = "Hello, \(request.name)!" }
    }
}

// 2. Register methods with a ConnectRouter
let greeter = Greeter()
var router = ConnectRouter()

router.registerUnary(
    method: MethodDescriptor(fullyQualifiedService: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self
) { message, context in
    try await greeter.sayHello(request: message, context: context)
}

// 3. Start the server
let server = ConnectServer(
    address: .hostname("0.0.0.0", port: 8080),
    transportSecurity: .plaintext,
    router: router
)
try await server.serve()
```

### With TLS (HTTP/2 ALPN for browsers)

```swift
var tlsConfig = TLSConfiguration.makeServerConfiguration(
    certificateChain: [...],
    privateKey: ...
)
let server = ConnectServer(
    address: .hostname("0.0.0.0", port: 443),
    transportSecurity: .tls(tlsConfig),
    router: router
)
try await server.serve()
```

### Server-streaming

```swift
router.registerServerStreaming(
    method: MethodDescriptor(fullyQualifiedService: "list.Items", method: "List"),
    requestType: ListRequest.self,
    responseType: Item.self
) { request, context, writer in
    for item in items {
        try await writer.write(item)
    }
    // Throw to terminate the stream with an error;
    // for gRPC/gRPC-Web the error appears in the trailer frame,
    // for Connect it appears in the EndStreamResponse JSON.
}
```

### Health checks

```swift
let health = HealthService()
health.setStatus(.serving, for: "")                       // overall server
health.setStatus(.serving, for: "helloworld.Greeter")     // per-service

var router = ConnectRouter()
health.register(with: &router)
// Now responds to /grpc.health.v1.Health/Check
```

### Timeouts

Set `Connect-Timeout-Ms: <ms>` (Connect) or `grpc-timeout: 5S` / `100m` (gRPC / gRPC-Web)
on the request. The handler is wrapped in `withDeadline(...)`. On expiry the server
returns `deadline_exceeded` (HTTP 408 for Connect, `grpc-status: 4` for the others).

### With metadata access

Use the `ServerRequest` / `ServerResponse` variant to read request headers or return trailing metadata:

```swift
router.registerUnary(
    method: MethodDescriptor(fullyQualifiedService: "helloworld.Greeter", method: "SayHello"),
    requestType: Helloworld_HelloRequest.self,
    responseType: Helloworld_HelloReply.self,
    handler: { (request: ServerRequest<Helloworld_HelloRequest>, context: ServerContext)
        -> ServerResponse<Helloworld_HelloReply> in

        let auth = request.metadata["authorization"] // first value for the key
        let reply = Helloworld_HelloReply.with { $0.message = "Hello, \(request.message.name)!" }
        return ServerResponse(
            message: reply,
            trailingMetadata: ["x-cost": "1"]
        )
    }
)
```

## Testing with buf curl

```sh
# Connect JSON
buf curl --protocol connect http://localhost:8080/helloworld.Greeter/SayHello \
  -d '{"name":"World"}'

# gRPC
grpcurl -plaintext -d '{"name":"World"}' \
  localhost:8080 helloworld.Greeter/SayHello
```

## Browser (connect-web)

```typescript
import { createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { GreeterService } from "./gen/helloworld_connect";

const transport = createConnectTransport({ baseUrl: "http://localhost:8080" });
const client = createClient(GreeterService, transport);
const response = await client.sayHello({ name: "World" });
```

## CORS

For browser clients on a different origin, configure CORS on the router:

```swift
// Permissive — any origin, no credentials. Good for development or public APIs.
var router = ConnectRouter(cors: .permissive())

// Strict — specific origins only.
var router = ConnectRouter(cors: .strict(allowedOrigins: ["https://app.example.com"]))

// Custom matcher (e.g. allow any subdomain).
var router = ConnectRouter(cors: CORSConfiguration(
    allowedOrigins: .matching { $0.hasSuffix(".example.com") },
    allowCredentials: true
))
```

The router handles `OPTIONS` preflight requests and adds the right
`Access-Control-Allow-*` headers to all responses. Defaults match the
[Connect CORS recommendations](https://connectrpc.com/docs/cors). When `cors` is `nil`
(the default), no CORS headers are sent — useful for backend-to-backend calls.

## Distributed tracing

ConnectServer creates one span per RPC using [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing). Each span gets standard OpenTelemetry RPC semantic attributes (`rpc.system`, `rpc.service`, `rpc.method`). Zero overhead when no tracer is bootstrapped (uses NoOpTracer by default).

```swift
// Bootstrap a tracer at startup (e.g. OpenTelemetry)
import Tracing
InstrumentationSystem.bootstrap(myOTelTracer)
```

## Configuration

`maxMessageBytes` (default 4 MiB) caps per-message size on both unary and streaming
methods. Requests exceeding it return `resource_exhausted` (HTTP 429 / `grpc-status: 8`).

```swift
var router = ConnectRouter(maxMessageBytes: 16 * 1024 * 1024)  // 16 MiB
```

### swift-configuration integration

The package ships a `ConfigurationSupport` SwiftPM trait (default-on) which adds
`init(reader:)` overloads to `ConnectRouter` and `CORSConfiguration`:

```swift
import Configuration

let reader = ConfigReader(provider: EnvironmentVariablesProvider())
var router = ConnectRouter(reader: reader.scoped(to: "connect-server"))
```

Configuration keys (relative to whatever scope you pass):

| Key | Type | Default |
|---|---|---|
| `max-message-bytes` | int | `4194304` (4 MiB) |
| `cors.enabled` | bool | `false` |
| `cors.allowed-origins` | string array | `["*"]` |
| `cors.allowed-headers` | string array | spec defaults |
| `cors.exposed-headers` | string array | spec defaults |
| `cors.allow-credentials` | bool | `false` |
| `cors.max-age-seconds` | int | `7200` |

To drop the swift-configuration dependency entirely, build with
`--disable-default-traits`. The `init(reader:)` overloads disappear; the plain-value
initializers remain unchanged.

## Codegen

Manual registration is fine for small services, but for anything non-trivial use the
included **protoc plugin**, `protoc-gen-connect-swift-server`. It works with `protoc`
or `buf generate`.

```yaml
# buf.gen.yaml
version: v2
plugins:
  - local: protoc-gen-connect-swift-server  # built via swift build --product
    opt:
      - Visibility=Public
      - ProtoPathModuleMappings=module_mappings.asciipb
    out: gen
```

The plugin emits one `<Service>ConnectService` struct per service, with a closure
parameter per RPC method and a `register(with:&router)` helper. Unary and
server-streaming closures use the metadata-aware signatures
(`ServerRequest`/`ServerResponse`, trailing `Metadata`), so handlers can read
request headers — auth tokens, locales — and return trailing metadata.

Options (matching protoc-gen-swift / protoc-gen-grpc-swift-2 conventions):

| Option | Meaning |
|---|---|
| `Visibility=Internal\|Public\|Package` | Access level of generated declarations (default `Public`) |
| `ProtoPathModuleMappings=<path>` | Module-mappings file; foreign-module types are qualified and their modules imported |
| `ExtraModuleImports=<Module>` | Additional module to import in generated files; repeatable |

The generator lives in the [`ConnectServerGenerator`](Sources/ConnectServerGenerator)
library target (unit-tested in `Tests/ConnectServerGeneratorTests`); the
executable is a thin wrapper.

## Examples

- **`Examples/SmokeTest/`** — a runnable example server with all four streaming kinds,
  CORS enabled, and a built-in self-test:
  ```sh
  swift run smoke-test                # interactive — prints copy-paste curl commands
  swift run smoke-test --self-test    # one-shot pass/fail check via URLSession
  ```
- **`Examples/Browser/`** — a static HTML page that drives the smoke-test server from
  a browser via `fetch()`, exercising real cross-origin CORS preflights. See
  [`Examples/Browser/README.md`](Examples/Browser/README.md).

## Limitations & known gaps

These are documented and tracked; none of them block typical browser/native-client
deployments, but you should know about them:

| Gap | Impact | Workaround |
|---|---|---|
| **Compression** (`gzip` content-encoding) | More bandwidth than necessary on slow networks | Defer to a reverse proxy (nginx, CloudFront) terminating compression upstream |
| **Server reflection** (`grpc.reflection.v1.ServerReflection`) | `grpcurl --reflect` / `buf curl --reflect` won't work | Distribute the `.proto` files to clients |
| **Connect GET requests** (idempotency_level=NO_SIDE_EFFECTS) | Idempotent unary RPCs can't be CDN-cached | Use POST as today |
| **gRPC-Web text mode** (`application/grpc-web-text`, base64) | Niche edge case for some restrictive browser environments | Use `application/grpc-web+proto` |
| **Compression in envelope** (per-message gzip flag) | Same as content-encoding above | Same |
| **Per-RPC interceptors / middleware** | Cross-cutting concerns (auth, rate limit) require manual handler wrapping | Wrap your handler closure |

These will be addressed in 1.1+. Pull requests welcome.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design document: protocol detection strategy, service adapter design, tracing integration, and phased rollout.

## License

MIT. See [LICENSE](LICENSE).
