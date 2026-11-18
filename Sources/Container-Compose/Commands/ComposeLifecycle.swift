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
//  ComposeLifecycle.swift
//  Container-Compose
//
//  Implements `start`, `stop` and `restart`, which act on containers `up`
//  already created without recreating them.
//

import ArgumentParser
import ContainerAPIClient
import ContainerCommands
import Foundation

public struct ComposeStart: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "start",
        abstract: "Start existing containers for services"
    )

    @Argument(help: "Specify the services to start")
    var services: [String] = []

    @OptionGroup
    var project: ComposeProjectOptions

    public func run() async throws {
        let (_, containers) = try await project.resolveContainers(for: services)
        try await Self.start(containers)
    }

    /// Starts the stopped containers in dependency order.
    static func start(_ containers: [ServiceContainer]) async throws {
        for container in containers where !container.isRunning {
            print("Starting \(container.serviceName) (\(container.id))")
            // Detached by default; prints the container ID once started.
            try await Application.ContainerStart.parse([container.id]).run()
        }
    }
}

public struct ComposeStop: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "stop",
        abstract: "Stop running containers without removing them"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    // Long form only: -t is the TTY flag shared by every subcommand.
    @Option(name: .customLong("timeout"), help: "Seconds to wait before killing the container (default: the service's stop_grace_period)")
    var timeout: Int32?

    @OptionGroup
    var project: ComposeProjectOptions

    public func run() async throws {
        let (_, containers) = try await project.resolveContainers(for: services)
        await Self.stop(containers, timeout: timeout)
    }

    /// Stops the running containers in reverse dependency order, so a
    /// service stops before what it depends on. Failures are reported and do
    /// not stop the remaining containers, as with `down`.
    static func stop(_ containers: [ServiceContainer], timeout: Int32?) async {
        let client = ContainerClient()
        for container in containers.reversed() where container.isRunning {
            print("Stopping \(container.serviceName) (\(container.id))")
            let options = timeout.map { ComposeStopOptions.resolve(timeoutInSeconds: $0) }
                ?? ComposeStopOptions.resolve(for: container.target.service)
            do {
                try await client.stop(id: container.id, opts: options)
            } catch {
                print("Error: Could not stop \(container.id): \(error)")
            }
        }
    }
}

public struct ComposeRestart: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "restart",
        abstract: "Restart service containers"
    )

    @Argument(help: "Specify the services to restart")
    var services: [String] = []

    // Long form only: -t is the TTY flag shared by every subcommand.
    @Option(name: .customLong("timeout"), help: "Seconds to wait before killing the container (default: the service's stop_grace_period)")
    var timeout: Int32?

    @OptionGroup
    var project: ComposeProjectOptions

    /// Restarts every selected container, running or stopped, like
    /// `docker compose restart`. Configuration changes are not applied; use
    /// `up` to recreate containers.
    public func run() async throws {
        let (_, containers) = try await project.resolveContainers(for: services)
        await ComposeStop.stop(containers, timeout: timeout)

        // Re-read the state: stopping changed it, and a container that failed
        // to stop must not be started twice.
        let (_, stopped) = try await project.resolveContainers(for: services)
        try await ComposeStart.start(stopped)
    }
}
