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

import Foundation
import Testing
import Yams
@testable import ContainerComposeCore

@Suite("Service to container mapping")
struct ServiceContainersTests {

    private struct FakeContainer {
        let id: String
        let labels: [String: String]
    }

    private func labels(_ service: String, project: String = "demo") -> [String: String] {
        ["com.docker.compose.project": project, "com.docker.compose.service": service]
    }

    /// Project `demo` with `web` depending on `db`, resolved in start order.
    private func demoProject() throws -> ComposeProject {
        let compose = try YAMLDecoder().decode(
            DockerCompose.self,
            from: """
            name: demo
            services:
              web:
                image: nginx
                depends_on: [db]
              db:
                image: postgres
            """)
        return ComposeProject(
            compose: compose, projectName: "demo",
            services: [
                .init(serviceName: "db", service: Service(image: "postgres"), candidateContainerNames: ["demo-db"]),
                .init(serviceName: "web", service: Service(image: "nginx"), candidateContainerNames: ["demo-web"]),
            ])
    }

    @Test("No requested names selects every service in dependency order")
    func allTargets() throws {
        #expect(try demoProject().targets(named: []).map(\.serviceName) == ["db", "web"])
    }

    @Test("Requested names select only those services, without their dependencies")
    func onlyRequestedTargets() throws {
        #expect(try demoProject().targets(named: ["web"]).map(\.serviceName) == ["web"])
    }

    @Test("Containers pair with their service in target order, foreign projects excluded")
    func pairing() throws {
        let project = try demoProject()
        let containers = [
            FakeContainer(id: "web.demo", labels: labels("web")),
            FakeContainer(id: "demo-db", labels: [:]),  // unlabeled, matched by name
            FakeContainer(id: "other-web", labels: labels("web", project: "other")),
        ]
        let pairs = project.pair(containers, with: project.targets(named: []), id: \.id, labels: \.labels)
        #expect(pairs.map(\.target.serviceName) == ["db", "web"])
        #expect(pairs.map(\.container.id) == ["demo-db", "web.demo"])
    }
}

@Suite("Compose exec arguments")
struct ComposeExecTests {

    private func exec(_ arguments: [String]) throws -> ComposeExec {
        try ComposeExec.parse(arguments)
    }

    @Test("Service and command are split; the command's own flags are kept")
    func passthrough() throws {
        let command = try exec(["backend", "python", "-m", "pytest", "-q"])
        #expect(command.service == "backend")
        #expect(command.command == ["python", "-m", "pytest", "-q"])
        #expect(
            command.execArguments(containerID: "c1", stdinIsTerminal: false)
                == ["--interactive", "c1", "python", "-m", "pytest", "-q"])
    }

    @Test("A terminal stdin gets a TTY unless -T is given")
    func ttyAllocation() throws {
        #expect(try exec(["web", "sh"]).execArguments(containerID: "c1", stdinIsTerminal: true)
            == ["--interactive", "--tty", "c1", "sh"])
        #expect(try exec(["-T", "web", "sh"]).execArguments(containerID: "c1", stdinIsTerminal: true)
            == ["--interactive", "c1", "sh"])
    }

    @Test("Detached exec attaches neither stdin nor a TTY")
    func detached() throws {
        #expect(try exec(["-d", "web", "touch", "/tmp/x"]).execArguments(containerID: "c1", stdinIsTerminal: true)
            == ["--detach", "c1", "touch", "/tmp/x"])
    }

    @Test("Environment and user options are forwarded")
    func forwardedOptions() throws {
        let command = try exec(["-e", "A=1", "--env", "B", "-u", "app", "web", "env"])
        #expect(
            command.execArguments(containerID: "c1", stdinIsTerminal: false)
                == ["--interactive", "--env", "A=1", "--env", "B", "--user", "app", "c1", "env"])
    }

    @Test("A missing command is rejected")
    func missingCommand() {
        #expect(throws: (any Error).self) { try exec(["web"]) }
    }
}

@Suite("Compose logs formatting")
struct ComposeLogsTests {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test("All lines are returned without a trailing empty line")
    func allLines() {
        #expect(ComposeLogs.lastLines(of: data("a\nb\n"), count: nil) == ["a", "b"])
        #expect(ComposeLogs.lastLines(of: data(""), count: nil) == [])
    }

    @Test("Tail keeps the last lines, blank lines included, CRLF stripped")
    func tail() {
        #expect(ComposeLogs.lastLines(of: data("1\n\n3\r\n4\n"), count: 3) == ["", "3", "4"])
        #expect(ComposeLogs.lastLines(of: data("1\n2\n"), count: 0) == [])
        #expect(ComposeLogs.lastLines(of: data("1\n2"), count: 5) == ["1", "2"])
    }

    @Test("Prefixes pad service names to the same width")
    func prefixes() {
        let prefixes = ComposeLogs.prefixes(for: ["db", "backend"], enabled: true)
        #expect(prefixes.count == 2)
        #expect(prefixes[0].contains("db      | "))
        #expect(prefixes[1].contains("backend | "))
    }

    @Test("--no-log-prefix prints bare lines")
    func noPrefix() throws {
        let command = try ComposeLogs.parse(["--no-log-prefix", "--follow", "-n", "5", "web"])
        #expect(command.noLogPrefix && command.follow && command.tail == 5)
        #expect(ComposeLogs.prefixes(for: ["web"], enabled: false) == [""])
    }

    @Test("A negative tail is rejected")
    func negativeTail() {
        #expect(throws: (any Error).self) { try ComposeLogs.parse(["-n", "-1"]) }
    }
}

@Suite("Lifecycle command parsing")
struct ComposeLifecycleTests {

    @Test("stop and restart accept --timeout and service names")
    func timeout() throws {
        let stop = try ComposeStop.parse(["--timeout", "3", "web", "db"])
        #expect(stop.timeout == 3 && stop.services == ["web", "db"])
        let restart = try ComposeRestart.parse(["web"])
        #expect(restart.timeout == nil && restart.services == ["web"])
    }

    @Test("start accepts service names")
    func start() throws {
        #expect(try ComposeStart.parse(["db"]).services == ["db"])
    }
}
