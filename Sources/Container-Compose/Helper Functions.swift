//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import CryptoKit
import Foundation
import Yams
import Rainbow
import ContainerCommands
import ContainerAPIClient

public func resolvedPath(for path: String, relativeTo baseURL: URL) -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath, relativeTo: baseURL).standardizedFileURL.path
}


/// The standard executable directories appended as a fallback when building the
/// PATH for spawned `container` processes.
public let standardExecutablePathFallback = [
    "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
]

/// Builds the PATH used for spawned child processes by preserving the user's
/// inherited PATH and appending any standard fallback directories that are not
/// already present. This keeps `container` binaries installed outside the
/// standard locations (e.g. Nix at `/run/current-system/sw/bin`) reachable while
/// still guaranteeing the common Homebrew/system directories are available.
/// - Parameters:
///   - existing: The inherited PATH value (typically `$PATH`), or `nil` if unset.
///   - fallback: The standard directories to ensure are present.
/// - Returns: A `:`-separated PATH string preserving the user's order, followed
///   by any missing fallback directories.
public func mergedExecutablePath(
    existing: String?,
    fallback: [String] = standardExecutablePathFallback
) -> String {
    let existingEntries = (existing ?? "")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)

    var seen = Set(existingEntries)
    var merged = existingEntries

    for dir in fallback where !seen.contains(dir) {
        merged.append(dir)
        seen.insert(dir)
    }

    return merged.joined(separator: ":")
}

/// Loads environment variables from a .env file.
/// - Parameter path: The full path to the .env file.
/// - Returns: A dictionary of key-value pairs representing environment variables.
public func loadEnvFile(path: String) -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)
    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex])
                    let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                    envVars[key] = value
                }
            }
        }
    } catch {
        // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
        // Suppress error message if .env file is optional or missing
    }
    return envVars
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    var resolvedValue = value
    // Regex to find ${VAR}, ${VAR:-default}, ${VAR:?error}
    let regex = try! NSRegularExpression(pattern: #"\$\{([A-Za-z0-9_]+)(:?-(.*?))?(:\?(.*?))?\}"#, options: [])
    
    // Combine process environment with loaded .env file variables, prioritizing process environment
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }
    
    // Loop to resolve all occurrences of variables in the string
    while let match = regex.firstMatch(in: resolvedValue, options: [], range: NSRange(resolvedValue.startIndex..<resolvedValue.endIndex, in: resolvedValue)) {
        guard let varNameRange = Range(match.range(at: 1), in: resolvedValue) else { break }
        let varName = String(resolvedValue[varNameRange])
        
        if let envValue = combinedEnv[varName] {
            // Variable found in environment, replace with its value
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: envValue)
        } else if let defaultValueRange = Range(match.range(at: 3), in: resolvedValue) {
            // Variable not found, but default value is provided, replace with default
            let defaultValue = String(resolvedValue[defaultValueRange])
            resolvedValue.replaceSubrange(Range(match.range(at: 0), in: resolvedValue)!, with: defaultValue)
        } else if match.range(at: 5).location != NSNotFound, let errorMessageRange = Range(match.range(at: 5), in: resolvedValue) {
            // Variable not found, and error-on-missing syntax used, print error and exit
            let errorMessage = String(resolvedValue[errorMessageRange])
            fputs("Error: Missing required environment variable '\(varName)': \(errorMessage)\n", stderr)
            Application.exit(withError: "Error: Missing required environment variable '\(varName)': \(errorMessage)\n")
        } else {
            // Variable not found and no default/error specified, leave as is and break loop to avoid infinite loop
            break
        }
    }
    return resolvedValue
}

/// Assembles container variables from service files and explicit values.
/// The interpolation environment supplies substitutions without being injected.
func assembleServiceEnvironment(
    service: Service,
    composeDirectory: String,
    interpolationEnvironment: [String: String]
) -> [String: String] {
    var result: [String: String] = [:]
    for path in service.env_file ?? [] {
        let fullPath = resolvedPath(for: path, relativeTo: URL(fileURLWithPath: composeDirectory, isDirectory: true))
        result.merge(loadEnvFile(path: fullPath)) { _, later in later }
    }
    for (key, value) in service.environment ?? [:] {
        result[key] = resolveVariable(value, with: interpolationEnvironment)
    }
    return result
}

/// Derives a project name from the current working directory. It replaces any '.' characters with
/// '_' to ensure compatibility with container naming conventions.
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
public func deriveProjectName(cwd: String) -> String {
    // We need to replace '.' with _ because it is not supported in the container name
    let projectName = URL(fileURLWithPath: cwd).lastPathComponent.replacingOccurrences(of: ".", with: "_")
    return projectName
}

/// Converts Docker Compose port specification into a container run -p format.
/// Handles various formats: "PORT", "HOST:PORT", "IP:HOST:PORT", and optional protocol.
/// - Parameter portSpec: The port specification string from docker-compose.yml.
/// - Returns: A properly formatted port binding for `container run -p`.
public func composePortToRunArg(_ portSpec: String) -> String {
    // Check for protocol suffix (e.g., "/tcp" or "/udp")
    var protocolSuffix = ""
    var portBody = portSpec
    if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
        let afterSlash = portSpec[slashRange.lowerBound...]
        let protocolPart = String(afterSlash)
        if protocolPart == "/tcp" || protocolPart == "/udp" {
            protocolSuffix = protocolPart
            portBody = String(portSpec[..<slashRange.lowerBound])
        }
    }

    let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
    switch components.count {
    case 1:
        let containerPort = components[0]
        return "0.0.0.0:\(containerPort):\(containerPort)\(protocolSuffix)"
    case 2:
        let hostPart = components[0]
        let containerPart = components[1]
        let hasIPv4 = hostPart.contains(".")
        let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
        if hasIPv4 || hasIPv6 {
            return "\(hostPart):\(containerPart)\(protocolSuffix)"
        } else {
            return "0.0.0.0:\(hostPart):\(containerPart)\(protocolSuffix)"
        }
    case 3:
        let ipPart = components[0]
        let hostPart = components[1]
        let containerPart = components[2]
        return "\(ipPart):\(hostPart):\(containerPart)\(protocolSuffix)"
    default:
        return portSpec
    }
}

/// Converts a Docker Compose `volumes:` entry into the `--volume` arguments for `container run`.
/// Internal so tests can reach it via `@testable import ContainerComposeCore`.
func composeVolumeToRunArgs(
    _ volume: String,
    composeDirectory: String,
    fileManager: FileManager = .default,
    environmentVariables: [String: String] = [:],
    projectName: String?,
    volumeDefinitions: [String: Volume?]? = nil
) throws -> [String] {
    let resolvedVolume = resolveVariable(volume, with: environmentVariables)
    var args: [String] = []

    let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count >= 2 else {
        print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
        return []
    }

    let source = components[0]
    let destination = components[1]
    let mode = components.count == 3 ? components[2] : nil

    func bindMountArg(source: String) -> String {
        if let mode { return "\(source):\(destination):\(mode)" }
        return "\(source):\(destination)"
    }

    if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
        let fullHostPath = resolvedPath(for: source, relativeTo: URL(fileURLWithPath: composeDirectory, isDirectory: true))

        if fileManager.fileExists(atPath: fullHostPath) {
            args.append("-v")
            args.append(bindMountArg(source: fullHostPath))
        } else {
            do {
                try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                print("Info: Created missing host directory for volume: \(fullHostPath)")
                args.append("-v")
                args.append(bindMountArg(source: fullHostPath))
            } catch {
                print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
            }
        }
    } else {
        let volumeDefinition = volumeDefinitions?[source] ?? nil
        let actualVolumeName = composeNamedVolumeName(
            source: source,
            projectName: projectName,
            volumeDefinition: volumeDefinition
        )

        args.append("-v")
        args.append(bindMountArg(source: actualVolumeName))
    }

    return args
}

func composeNamedVolumeName(
    source: String,
    projectName: String?,
    volumeDefinition: Volume?
) -> String {
    if let explicitName = volumeDefinition?.name {
        return explicitName
    }

    if volumeDefinition?.external?.isExternal == true {
        return volumeDefinition?.external?.name ?? source
    }

    guard let projectName, !projectName.isEmpty else {
        return source
    }

    return "\(projectName)_\(source)"
}

/// A service volume entry that names only a container path, such as
/// `/app/node_modules` or `/app/node_modules:ro`.
///
/// Docker backs these with a fresh volume seeded from the image, typically to
/// keep a bind mount of the parent directory from hiding what the image
/// installed there.
struct AnonymousVolume: Equatable {
    let destination: String
    let mode: String?

    /// Parses `entry` (after variable resolution) as an anonymous volume.
    /// - Returns: `nil` for bind mounts and named volumes.
    init?(_ entry: String) {
        let components = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let destination = components.first, destination.hasPrefix("/") else { return nil }
        switch components.count {
        case 1:
            mode = nil
        case 2 where ["ro", "rw"].contains(components[1]):
            mode = components[1]
        default:
            return nil
        }
        self.destination = destination
    }

    /// The volume's name: stable across `up` runs, so a recreated container
    /// gets the same data back, and unique per project, service and path.
    func volumeName(projectName: String, serviceName: String) -> String {
        let digest = SHA256.hash(data: Data(destination.utf8))
        let hash = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(projectName)_\(serviceName)_anon_\(hash)"
    }

    /// The `-v` argument mounting `volumeName` at the destination.
    func mountArgument(volumeName: String) -> String {
        [volumeName, destination, mode].compactMap { $0 }.joined(separator: ":")
    }

    /// Labels identifying the volume as this service's anonymous volume.
    func labels(projectName: String, serviceName: String) -> [String: String] {
        [
            "com.docker.compose.project": projectName,
            "com.docker.compose.service": serviceName,
            Self.destinationLabel: destination,
        ]
    }

    static let destinationLabel = "container-compose.anonymous-volume"

    /// Mount point of the new volume inside the seeding container.
    static let seedMountPoint = "/__container_compose_seed"

    /// `container run` arguments that copy the image's content at the
    /// destination into a new volume, keeping ownership and permissions.
    ///
    /// Apple Container mounts new volumes empty, unlike Docker, which copies
    /// the image's files into an empty volume on first use. Without this a
    /// volume over `/app/node_modules` would hide the installed packages.
    /// The copy is skipped when the image has nothing at the destination.
    func seedArguments(volumeName: String, image: String, platform: String?) -> [String] {
        let script = #"[ -d "$1" ] || exit 0; cp -a "$1"/. "$2"/ && chown "$(stat -c %u:%g "$1")" "$2" && chmod "$(stat -c %a "$1")" "$2""#
        var arguments = ["run", "--rm"]
        if let platform {
            arguments.append(contentsOf: ["--platform", platform])
        }
        arguments.append(contentsOf: [
            "-v", "\(volumeName):\(Self.seedMountPoint)",
            "--entrypoint", "/bin/sh",
            image,
            "-c", script, "seed", destination, Self.seedMountPoint,
        ])
        return arguments
    }
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}

extension Flags.Logging {
    /// Generates an array of flags that allow us to pass down Logging options
    func passThroughCommands() -> [String] {
        var flags: [String] = []
        
        if debug {
            flags.append("--debug")
        }
        
        return flags
    }
}
