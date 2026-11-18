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
//  ComposeExec.swift
//  Container-Compose
//
//  Implements the `exec` subcommand, which runs a command in a service's
//  running container.
//

import ArgumentParser
import ContainerCommands
import Foundation

public struct ComposeExec: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "exec",
        abstract: "Execute a command in a running service container"
    )

    @Flag(name: [.customShort("d"), .customLong("detach")], help: "Run the command in the background")
    var detach: Bool = false

    @Flag(
        name: [.customShort("T"), .customLong("no-tty")],
        help: "Disable pseudo-TTY allocation (by default a TTY is allocated when stdin is a terminal)")
    var noTTY: Bool = false

    // Supplies -e/--env, -u/--user, --uid, --gid, -i and -t, which are passed
    // on to the container. Its -w/--cwd selects the project directory, as for
    // every other subcommand, not the working directory inside the container.
    @OptionGroup
    var project: ComposeProjectOptions

    @Argument(help: "The service to run the command in")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments")
    var command: [String] = []

    /// The command to run. Passthrough parsing keeps a leading `--`
    /// (`exec web -- ls`), which separates options and is not part of it.
    var commandArguments: [String] {
        command.first == "--" ? Array(command.dropFirst()) : command
    }

    public func validate() throws {
        guard !commandArguments.isEmpty else {
            throw ValidationError("Missing the command to execute in '\(service)'.")
        }
    }

    public func run() async throws {
        let (_, containers) = try await project.resolveContainers(for: [service])
        guard let container = containers.first(where: \.isRunning) else {
            throw ComposeError.serviceNotRunning(service)
        }

        let arguments = execArguments(containerID: container.id, stdinIsTerminal: isatty(STDIN_FILENO) == 1)
        // ContainerExec ends by throwing ExitCode with the command's status,
        // which becomes this process's exit status.
        try await Application.ContainerExec.parse(arguments).run()
    }

    /// Arguments for `container exec`, mirroring `docker compose exec`:
    /// stdin stays attached unless detached, and a TTY is allocated when
    /// stdin is a terminal unless `-T` is given.
    func execArguments(containerID: String, stdinIsTerminal: Bool) -> [String] {
        let process = project.process
        var arguments: [String] = []

        if detach {
            arguments.append("--detach")
        } else {
            arguments.append("--interactive")
            if process.tty || (stdinIsTerminal && !noTTY) {
                arguments.append("--tty")
            }
        }
        for variable in process.env {
            arguments.append(contentsOf: ["--env", variable])
        }
        if let user = process.user {
            arguments.append(contentsOf: ["--user", user])
        }
        if let uid = process.uid {
            arguments.append(contentsOf: ["--uid", String(uid)])
        }
        if let gid = process.gid {
            arguments.append(contentsOf: ["--gid", String(gid)])
        }

        arguments.append(containerID)
        arguments.append(contentsOf: commandArguments)
        return arguments
    }
}
