// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT
//
// protoc-gen-connect-swift-server: a protoc plugin that emits Swift bindings
// for registering services on a `ConnectRouter` from `ConnectServer`.
//
// Output: for each `.proto` file containing services, a `<file>.connect.swift`
// containing one struct per service. The user constructs the struct with one
// closure per RPC method and calls `register(with:&router)`.
//
// Usage:
//   protoc --connect-swift-server_out=. helloworld.proto
//   buf generate                        # if configured in buf.gen.yaml
//
// Options (see `GeneratorOptions`): Visibility, ProtoPathModuleMappings,
// ExtraModuleImports.

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

public struct ConnectSwiftServerGenerator: CodeGenerator {
    public init() {}

    public var version: String? { "0.2.0" }
    public var projectURL: String? { "https://github.com/monagle-au/connect-swift-server" }
    public var supportedFeatures: [Google_Protobuf_Compiler_CodeGeneratorResponse.Feature] = [.proto3Optional]

    public func generate(
        files: [SwiftProtobufPluginLibrary.FileDescriptor],
        parameter: any CodeGeneratorParameter,
        protoCompilerContext: any ProtoCompilerContext,
        generatorOutputs: any GeneratorOutputs
    ) throws {
        let options = try GeneratorOptions(parameter: parameter)
        for file in files {
            guard !file.services.isEmpty else { continue }
            let namer = SwiftProtobufNamer(
                currentFile: file,
                protoFileToModuleMappings: options.protoFileToModuleMappings
            )
            let outputName = outputFilename(for: file.name)
            let content = ServiceCodeGenerator.generate(file: file, namer: namer, options: options)
            try generatorOutputs.add(fileName: outputName, contents: content)
        }
    }

    /// "foo/bar/baz.proto" → "foo/bar/baz.connect.swift"
    private func outputFilename(for protoName: String) -> String {
        var name = protoName
        if name.hasSuffix(".proto") { name.removeLast(".proto".count) }
        return name + ".connect.swift"
    }
}
