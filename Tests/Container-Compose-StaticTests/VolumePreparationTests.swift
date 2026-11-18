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

@Suite("New volume preparation")
struct VolumePreparationTests {

    @Test("lost+found removal runs the service image and only removes an empty directory")
    func removalArguments() throws {
        let arguments = lostFoundRemovalArguments(volumeName: "p_pgdata", image: "postgres:16-alpine", platform: nil)

        #expect(arguments.prefix(2) == ["run", "--rm"])
        #expect(!arguments.contains("--platform"))
        #expect(arguments.contains("p_pgdata:\(volumeHelperMountPoint)"))
        let image = try #require(arguments.firstIndex(of: "postgres:16-alpine"))
        #expect(arguments[image - 2 ..< image] == ["--entrypoint", "/bin/sh"])

        let script = try #require(arguments.firstIndex(of: "-c")).advanced(by: 1)
        #expect(arguments[script].contains(#"rmdir "$1/lost+found""#))
        #expect(!arguments[script].contains("rm -"))
        #expect(arguments.last == volumeHelperMountPoint)
    }

    @Test("The service platform is passed to the helper container")
    func platform() {
        let arguments = lostFoundRemovalArguments(volumeName: "v", image: "img", platform: "linux/amd64")
        #expect(arguments.prefix(4) == ["run", "--rm", "--platform", "linux/amd64"])
    }

    @Test("Named volume mounts are recognized; bind mounts are not")
    func namedVolumeSourceOfRunArgs() {
        #expect(namedVolumeSource(ofRunArgs: ["-v", "p_pgdata:/var/lib/postgresql/data"]) == "p_pgdata")
        #expect(namedVolumeSource(ofRunArgs: ["-v", "p_cache:/cache:ro"]) == "p_cache")
        #expect(namedVolumeSource(ofRunArgs: ["-v", "/Users/me/app:/app"]) == nil)
        #expect(namedVolumeSource(ofRunArgs: []) == nil)
    }

    @Test("The volume name matches what composeVolumeToRunArgs mounts")
    func roundTripWithRunArgs() throws {
        let args = try composeVolumeToRunArgs(
            "pgdata:/var/lib/postgresql/data",
            composeDirectory: "/tmp",
            projectName: "ai-vid",
            volumeDefinitions: ["pgdata": nil]
        )
        #expect(namedVolumeSource(ofRunArgs: args) == "ai-vid_pgdata")
    }
}
