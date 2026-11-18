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
//  ServiceContainers.swift
//  Container-Compose
//
//  Maps service names to the existing containers of a compose project, for
//  the subcommands that act on containers `up` already created: `exec`,
//  `logs`, `start`, `stop` and `restart`.
//

import ContainerAPIClient
import ContainerResource
import Foundation

/// A service paired with one of its existing containers.
struct ServiceContainer {
    let target: ComposeProject.ServiceTarget
    let snapshot: ContainerSnapshot

    var serviceName: String { target.serviceName }
    var id: String { snapshot.id }
    var isRunning: Bool { snapshot.status == .running }
}

extension ComposeProject {
    /// The services a container-level command acts on, in dependency order.
    ///
    /// Unlike `up`, these commands do not pull in dependencies:
    /// `stop backend` stops only `backend`, as with `docker compose`. An empty
    /// `requested` selects every resolved service.
    func targets(named requested: [String]) -> [ServiceTarget] {
        guard !requested.isEmpty else { return services }
        let wanted = Set(requested)
        return services.filter { wanted.contains($0.serviceName) }
    }

    /// Pairs each target with the containers it owns, keeping the targets'
    /// order. Generic over the container representation so the matching is
    /// unit-testable without daemon types.
    func pair<Container>(
        _ containers: [Container],
        with targets: [ServiceTarget],
        id: (Container) -> String,
        labels: (Container) -> [String: String]
    ) -> [(target: ServiceTarget, container: Container)] {
        targets.flatMap { target in
            containers
                .filter { target.matches(containerID: id($0), labels: labels($0), projectName: projectName) }
                .map { (target, $0) }
        }
    }
}

extension ComposeProjectOptions {
    /// Resolves `requested` service names to the project's existing containers.
    ///
    /// - Throws: `ComposeError.noSuchService` for a name the compose file does
    ///   not define, and `ComposeError.noContainers` when none of the selected
    ///   services has a container yet.
    /// - Returns: The project, and the matched containers in dependency order.
    ///   A selected service without a container is reported with a warning.
    func resolveContainers(
        for requested: [String]
    ) async throws -> (project: ComposeProject, containers: [ServiceContainer]) {
        let project = try resolve(filteringBy: requested)
        let defined: [(serviceName: String, service: Service)] = project.compose.services.compactMap { name, service in
            service.map { (name, $0) }
        }
        try Service.validateRequestedServices(requested, against: defined)

        let targets = project.targets(named: requested)
        let snapshots = try await ContainerClient().list()
        let containers = project.pair(snapshots, with: targets, id: \.id, labels: \.configuration.labels)
            .map { ServiceContainer(target: $0.target, snapshot: $0.container) }

        guard !containers.isEmpty else {
            throw ComposeError.noContainers(targets.map(\.serviceName))
        }
        let found = Set(containers.map(\.serviceName))
        for target in targets where !found.contains(target.serviceName) {
            print("Warning: No container found for service '\(target.serviceName)'.")
        }
        return (project, containers)
    }
}
