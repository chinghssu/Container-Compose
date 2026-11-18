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
//  ComposeLogs.swift
//  Container-Compose
//
//  Implements the `logs` subcommand, which prints the output of a project's
//  containers, each line prefixed with its service name.
//

import ArgumentParser
import ContainerAPIClient
import Foundation
import Rainbow

public struct ComposeLogs: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "logs",
        abstract: "View output from service containers"
    )

    @Argument(help: "Specify the services to show logs for")
    var services: [String] = []

    // Long form only: -f selects the compose file in every subcommand.
    @Flag(name: .customLong("follow"), help: "Follow log output")
    var follow: Bool = false

    @Option(name: [.customShort("n"), .customLong("tail")], help: "Number of lines to show from the end of each container's logs")
    var tail: Int?

    @Flag(name: .customLong("no-log-prefix"), help: "Don't print the service name before each line")
    var noLogPrefix: Bool = false

    @OptionGroup
    var project: ComposeProjectOptions

    public func validate() throws {
        if let tail, tail < 0 {
            throw ValidationError("--tail must be zero or greater.")
        }
    }

    public func run() async throws {
        let (_, containers) = try await project.resolveContainers(for: services)
        let client = ContainerClient()
        let prefixes = Self.prefixes(for: containers.map(\.serviceName), enabled: !noLogPrefix)

        var handles: [(prefix: String, handle: FileHandle)] = []
        for (container, prefix) in zip(containers, prefixes) {
            // The first handle is the container's stdio; the second is its boot log.
            let handle = try await client.logs(id: container.id)[0]
            let data = try handle.readToEnd() ?? Data()
            for line in Self.lastLines(of: data, count: tail) {
                print(prefix + line)
            }
            handles.append((prefix, handle))
        }
        fflush(stdout)

        if follow {
            setbuf(stdout, nil)
            for await line in Self.followLines(handles) {
                print(line)
            }
        }
    }

    /// The final `count` lines of `data`, or all lines when `count` is nil.
    /// Line endings are stripped; a trailing partial line is kept.
    static func lastLines(of data: Data, count: Int?) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        // Swift treats "\r\n" as a single Character, distinct from "\n".
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let count else { return lines }
        return Array(lines.suffix(count))
    }

    /// Line prefixes like `docker compose logs`: the service name padded to
    /// the longest one, followed by `| `, colored per service.
    static func prefixes(for serviceNames: [String], enabled: Bool) -> [String] {
        guard enabled else { return serviceNames.map { _ in "" } }
        let width = serviceNames.map(\.count).max() ?? 0
        let colors: [NamedColor] = [.cyan, .yellow, .green, .magenta, .blue, .red]
        var colorForService: [String: NamedColor] = [:]
        return serviceNames.map { name in
            let color = colorForService[name] ?? colors[colorForService.count % colors.count]
            colorForService[name] = color
            let padded = name.padding(toLength: width, withPad: " ", startingAt: 0)
            return "\(padded) | ".applyingColor(color)
        }
    }

    /// Streams lines appended to each handle after its current position,
    /// prefixed, until the process is interrupted.
    private static func followLines(_ handles: [(prefix: String, handle: FileHandle)]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for (prefix, handle) in handles {
                let buffer = LineBuffer()
                handle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        // A restarted container truncates its log; keep reading from the new end.
                        _ = try? handle.seekToEnd()
                        return
                    }
                    for line in buffer.append(data) {
                        continuation.yield(prefix + line)
                    }
                }
            }
        }
    }
}

/// Accumulates bytes read from a log and hands back complete lines, so a line
/// split across two reads is printed once, whole.
///
/// Each instance is used only by one file handle's readability handler, which
/// runs serially.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        return ComposeLogs.lastLines(of: Data(complete), count: nil)
    }
}
