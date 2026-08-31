// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import SwiftProtobufPluginLibrary

/// Options accepted by `protoc-gen-connect-swift-server`, passed via protoc's
/// `--connect-swift-server_opt` / buf's `opt:` list.
///
/// Supported options (names match protoc-gen-swift / protoc-gen-grpc-swift-2):
/// - `Visibility=Internal|Public|Package` — access level of generated declarations (default `Public`).
/// - `ProtoPathModuleMappings=<path>` — module-mappings file so types generated
///   into other modules are qualified and imported.
/// - `ExtraModuleImports=<Module>` — additional module to import in generated
///   files; may be given multiple times.
public struct GeneratorOptions {
    public enum Visibility: String {
        case `internal` = "Internal"
        case `public` = "Public"
        case `package` = "Package"

        var keyword: String { rawValue.lowercased() }
    }

    public enum OptionError: Error, CustomStringConvertible, Equatable {
        case unknownParameter(name: String)
        case invalidParameterValue(name: String, value: String)

        public var description: String {
            switch self {
            case .unknownParameter(let name):
                return "Unknown generation parameter '\(name)'"
            case .invalidParameterValue(let name, let value):
                return "Unknown value for generation parameter '\(name)': '\(value)'"
            }
        }
    }

    public private(set) var visibility: Visibility = .public
    public private(set) var protoFileToModuleMappings = ProtoFileToModuleMappings()
    public private(set) var extraModuleImports: [String] = []

    public init(parameter: any CodeGeneratorParameter) throws {
        try self.init(pairs: parameter.parsedPairs)
    }

    public init(pairs: [(key: String, value: String)]) throws {
        for pair in pairs {
            switch pair.key {
            case "Visibility":
                guard let visibility = Visibility(rawValue: pair.value) else {
                    throw OptionError.invalidParameterValue(name: pair.key, value: pair.value)
                }
                self.visibility = visibility
            case "ProtoPathModuleMappings":
                do {
                    self.protoFileToModuleMappings = try ProtoFileToModuleMappings(path: pair.value)
                } catch {
                    throw OptionError.invalidParameterValue(name: pair.key, value: pair.value)
                }
            case "ExtraModuleImports":
                guard isValidModuleName(pair.value) else {
                    throw OptionError.invalidParameterValue(name: pair.key, value: pair.value)
                }
                self.extraModuleImports.append(pair.value)
            default:
                throw OptionError.unknownParameter(name: pair.key)
            }
        }
    }

    /// Testing convenience: options with a mappings proto instead of a file path.
    public init(
        visibility: Visibility = .public,
        moduleMappings: SwiftProtobuf_GenSwift_ModuleMappings? = nil,
        extraModuleImports: [String] = []
    ) throws {
        self.visibility = visibility
        if let moduleMappings {
            self.protoFileToModuleMappings = try ProtoFileToModuleMappings(moduleMappingsProto: moduleMappings)
        }
        self.extraModuleImports = extraModuleImports
    }

    private func isValidModuleName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
