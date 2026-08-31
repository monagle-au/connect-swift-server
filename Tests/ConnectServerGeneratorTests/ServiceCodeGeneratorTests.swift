// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import SwiftProtobuf
import SwiftProtobufPluginLibrary
import Testing

@testable import ConnectServerGenerator

/// Builds a two-file descriptor set: `models.proto` holds the messages,
/// `service.proto` imports it and declares the services. This mirrors the
/// cross-module layout where messages are generated into a separate models
/// module from the Connect bindings.
private func makeDescriptorSet() -> DescriptorSet {
    var models = Google_Protobuf_FileDescriptorProto()
    models.name = "models.proto"
    models.package = "budgetforward.api.v1"
    models.syntax = "proto3"
    for message in ["GetPlansRequest", "GetPlansResponse", "WatchRequest", "PlanUpdate"] {
        var descriptor = Google_Protobuf_DescriptorProto()
        descriptor.name = message
        models.messageType.append(descriptor)
    }

    var service = Google_Protobuf_FileDescriptorProto()
    service.name = "service.proto"
    service.package = "budgetforward.api.v1"
    service.syntax = "proto3"
    service.dependency = ["models.proto"]

    var plans = Google_Protobuf_ServiceDescriptorProto()
    plans.name = "PlansService"
    var getPlans = Google_Protobuf_MethodDescriptorProto()
    getPlans.name = "GetPlans"
    getPlans.inputType = ".budgetforward.api.v1.GetPlansRequest"
    getPlans.outputType = ".budgetforward.api.v1.GetPlansResponse"
    var watch = Google_Protobuf_MethodDescriptorProto()
    watch.name = "Watch"
    watch.inputType = ".budgetforward.api.v1.WatchRequest"
    watch.outputType = ".budgetforward.api.v1.PlanUpdate"
    watch.serverStreaming = true
    plans.method = [getPlans, watch]
    service.service = [plans]

    return DescriptorSet(protos: [models, service])
}

private func generate(options: GeneratorOptions) -> String {
    let set = makeDescriptorSet()
    let file = set.fileDescriptor(named: "service.proto")!
    let namer = SwiftProtobufNamer(
        currentFile: file,
        protoFileToModuleMappings: options.protoFileToModuleMappings
    )
    return ServiceCodeGenerator.generate(file: file, namer: namer, options: options)
}

private func modelsMappings() -> SwiftProtobuf_GenSwift_ModuleMappings {
    var entry = SwiftProtobuf_GenSwift_ModuleMappings.Entry()
    entry.moduleName = "TestModels"
    entry.protoFilePath = ["models.proto"]
    var mappings = SwiftProtobuf_GenSwift_ModuleMappings()
    mappings.mapping = [entry]
    return mappings
}

@Suite("Service code generation")
struct ServiceCodeGeneratorTests {
    @Test("Unary methods use the metadata-aware ServerRequest/ServerResponse signature")
    func unaryIsMetadataAware() throws {
        let out = generate(options: try GeneratorOptions())
        #expect(out.contains(
            "public let getPlans: @Sendable (ServerRequest<Budgetforward_Api_V1_GetPlansRequest>, ServerContext) async throws -> ServerResponse<Budgetforward_Api_V1_GetPlansResponse>"
        ))
    }

    @Test("Server-streaming methods use the metadata-aware trailing-Metadata signature")
    func serverStreamingIsMetadataAware() throws {
        let out = generate(options: try GeneratorOptions())
        #expect(out.contains(
            "public let watch: @Sendable (ServerRequest<Budgetforward_Api_V1_WatchRequest>, ServerContext, ServerStreamWriter<Budgetforward_Api_V1_PlanUpdate>) async throws -> GRPCCore.Metadata"
        ))
    }

    @Test("Register calls carry the fully qualified service name")
    func registerCalls() throws {
        let out = generate(options: try GeneratorOptions())
        #expect(out.contains("router.registerUnary("))
        #expect(out.contains("router.registerServerStreaming("))
        #expect(out.contains(
            "MethodDescriptor(fullyQualifiedService: \"budgetforward.api.v1.PlansService\", method: \"GetPlans\")"
        ))
        #expect(out.contains("public struct Budgetforward_Api_V1_PlansServiceConnectService: Sendable"))
    }

    @Test("Default imports without mappings")
    func defaultImports() throws {
        let out = generate(options: try GeneratorOptions())
        #expect(out.contains("import ConnectServer\nimport GRPCCore\nimport SwiftProtobuf\n"))
        #expect(!out.contains("import TestModels"))
    }

    @Test("Module mappings qualify foreign types and add their import")
    func moduleMappings() throws {
        let out = generate(options: try GeneratorOptions(moduleMappings: modelsMappings()))
        #expect(out.contains("import TestModels"))
        #expect(out.contains("ServerRequest<TestModels.Budgetforward_Api_V1_GetPlansRequest>"))
    }

    @Test("ExtraModuleImports are emitted once each")
    func extraImports() throws {
        let out = generate(options: try GeneratorOptions(extraModuleImports: ["BudgetForwardAPI"]))
        #expect(out.contains("import BudgetForwardAPI"))
    }

    @Test("swift_prefix file option overrides the package-derived type prefix")
    func swiftPrefixNaming() throws {
        var models = Google_Protobuf_FileDescriptorProto()
        models.name = "prefixed.proto"
        models.package = "budgetforward.api.v1"
        models.syntax = "proto3"
        models.options.swiftPrefix = "ProtoV1"
        var request = Google_Protobuf_DescriptorProto()
        request.name = "PingRequest"
        var response = Google_Protobuf_DescriptorProto()
        response.name = "PingResponse"
        models.messageType = [request, response]
        var svc = Google_Protobuf_ServiceDescriptorProto()
        svc.name = "PingService"
        var ping = Google_Protobuf_MethodDescriptorProto()
        ping.name = "Ping"
        ping.inputType = ".budgetforward.api.v1.PingRequest"
        ping.outputType = ".budgetforward.api.v1.PingResponse"
        svc.method = [ping]
        models.service = [svc]

        let set = DescriptorSet(protos: [models])
        let file = set.fileDescriptor(named: "prefixed.proto")!
        let options = try GeneratorOptions()
        let namer = SwiftProtobufNamer(
            currentFile: file,
            protoFileToModuleMappings: options.protoFileToModuleMappings
        )
        let out = ServiceCodeGenerator.generate(file: file, namer: namer, options: options)
        #expect(out.contains("public struct ProtoV1PingServiceConnectService: Sendable"))
        #expect(out.contains("ServerRequest<ProtoV1PingRequest>"))
    }

    @Test("Internal visibility applies to every generated declaration")
    func internalVisibility() throws {
        let out = generate(options: try GeneratorOptions(visibility: .internal))
        #expect(out.contains("internal struct Budgetforward_Api_V1_PlansServiceConnectService"))
        #expect(out.contains("internal let getPlans"))
        #expect(out.contains("internal init("))
        #expect(out.contains("internal func register(with router: inout ConnectRouter)"))
        #expect(!out.contains("public "))
    }
}

@Suite("Generator options")
struct GeneratorOptionsTests {
    @Test("Defaults")
    func defaults() throws {
        let options = try GeneratorOptions(pairs: [])
        #expect(options.visibility == .public)
        #expect(options.extraModuleImports.isEmpty)
    }

    @Test("Visibility parsing")
    func visibility() throws {
        #expect(try GeneratorOptions(pairs: [("Visibility", "Internal")]).visibility == .internal)
        #expect(try GeneratorOptions(pairs: [("Visibility", "Package")]).visibility == .package)
        #expect(throws: GeneratorOptions.OptionError.invalidParameterValue(name: "Visibility", value: "private")) {
            try GeneratorOptions(pairs: [("Visibility", "private")])
        }
    }

    @Test("Repeated ExtraModuleImports accumulate; invalid module names are rejected")
    func extraModuleImports() throws {
        let options = try GeneratorOptions(pairs: [
            ("ExtraModuleImports", "ModuleA"),
            ("ExtraModuleImports", "ModuleB"),
        ])
        #expect(options.extraModuleImports == ["ModuleA", "ModuleB"])
        #expect(throws: GeneratorOptions.OptionError.invalidParameterValue(
            name: "ExtraModuleImports", value: "not a module"
        )) {
            try GeneratorOptions(pairs: [("ExtraModuleImports", "not a module")])
        }
    }

    @Test("Unknown parameters are rejected")
    func unknownParameter() {
        #expect(throws: GeneratorOptions.OptionError.unknownParameter(name: "Bogus")) {
            try GeneratorOptions(pairs: [("Bogus", "value")])
        }
    }

    @Test("Missing mappings file is an invalid parameter value")
    func missingMappingsFile() {
        #expect(throws: GeneratorOptions.OptionError.invalidParameterValue(
            name: "ProtoPathModuleMappings", value: "/nonexistent/mappings.asciipb"
        )) {
            try GeneratorOptions(pairs: [("ProtoPathModuleMappings", "/nonexistent/mappings.asciipb")])
        }
    }
}
