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

import Testing
@testable import ContainerComposeCore

@Suite("Anonymous volumes")
struct AnonymousVolumeTests {

    @Test("A container path alone, optionally with ro or rw, is anonymous")
    func recognized() {
        #expect(AnonymousVolume("/app/node_modules")?.destination == "/app/node_modules")
        #expect(AnonymousVolume("/app/node_modules")?.mode == nil)
        #expect(AnonymousVolume("/data:ro")?.mode == "ro")
        #expect(AnonymousVolume("/data:rw")?.mode == "rw")
    }

    @Test("Bind mounts, named volumes and relative paths are not anonymous")
    func notAnonymous() {
        #expect(AnonymousVolume("/host/path:/container") == nil)
        #expect(AnonymousVolume("/host/path:/container:ro") == nil)
        #expect(AnonymousVolume("./frontend:/app") == nil)
        #expect(AnonymousVolume("pgdata:/var/lib/postgresql/data") == nil)
        #expect(AnonymousVolume("relative/path") == nil)
        #expect(AnonymousVolume("") == nil)
    }

    @Test("The name is stable, valid for Apple Container, and distinct per path and service")
    func naming() throws {
        let modules = try #require(AnonymousVolume("/app/node_modules"))
        let next = try #require(AnonymousVolume("/app/.next"))
        let name = modules.volumeName(projectName: "ai-vid", serviceName: "frontend")

        #expect(name == modules.volumeName(projectName: "ai-vid", serviceName: "frontend"))
        #expect(name.hasPrefix("ai-vid_frontend_anon_"))
        #expect(name.count == "ai-vid_frontend_anon_".count + 12)
        #expect(name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]*/) != nil)
        #expect(name != next.volumeName(projectName: "ai-vid", serviceName: "frontend"))
        #expect(name != modules.volumeName(projectName: "ai-vid", serviceName: "worker"))
    }

    @Test("The mount argument keeps the access mode")
    func mountArgument() throws {
        #expect(try #require(AnonymousVolume("/data")).mountArgument(volumeName: "v") == "v:/data")
        #expect(try #require(AnonymousVolume("/data:ro")).mountArgument(volumeName: "v") == "v:/data:ro")
    }

    @Test("Labels tie the volume to its project, service and path")
    func labels() throws {
        let labels = try #require(AnonymousVolume("/data")).labels(projectName: "p", serviceName: "s")
        #expect(labels["com.docker.compose.project"] == "p")
        #expect(labels["com.docker.compose.service"] == "s")
        #expect(labels[AnonymousVolume.destinationLabel] == "/data")
    }

    @Test("Seeding runs the service image and passes the paths as arguments, not in the script")
    func seedArguments() throws {
        let volume = try #require(AnonymousVolume("/app/node_modules"))
        let arguments = volume.seedArguments(volumeName: "v", image: "web:latest", platform: "linux/arm64")

        #expect(arguments.prefix(4) == ["run", "--rm", "--platform", "linux/arm64"])
        #expect(arguments.contains("v:\(AnonymousVolume.seedMountPoint)"))
        let image = try #require(arguments.firstIndex(of: "web:latest"))
        #expect(arguments[image - 2 ..< image] == ["--entrypoint", "/bin/sh"])
        #expect(arguments.suffix(3) == ["seed", "/app/node_modules", AnonymousVolume.seedMountPoint])
        let script = try #require(arguments.firstIndex(of: "-c")).advanced(by: 1)
        #expect(arguments[script].hasPrefix(#"rmdir "$2/lost+found""#))

        let withoutPlatform = volume.seedArguments(volumeName: "v", image: "web:latest", platform: nil)
        #expect(!withoutPlatform.contains("--platform"))
    }
}
