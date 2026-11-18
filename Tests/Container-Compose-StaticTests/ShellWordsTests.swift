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
import Foundation
import Yams
@testable import ContainerComposeCore

@Suite("Shell word splitting")
struct ShellWordsTests {

    @Test("splits on runs of whitespace and trims the ends")
    func whitespace() throws {
        #expect(try splitShellWords("  npm   run\tdev\n") == ["npm", "run", "dev"])
    }

    @Test("empty and blank strings yield no words")
    func empty() throws {
        #expect(try splitShellWords("") == [])
        #expect(try splitShellWords("   ") == [])
    }

    @Test("double quotes keep spaces and operators in one word")
    func doubleQuotes() throws {
        #expect(
            try splitShellWords(#"sh -c "alembic upgrade head && uvicorn app.main:app""#)
                == ["sh", "-c", "alembic upgrade head && uvicorn app.main:app"]
        )
    }

    @Test("single quotes keep everything literally, including backslashes")
    func singleQuotes() throws {
        #expect(try splitShellWords(#"echo 'a "b" \n $HOME'"#) == ["echo", #"a "b" \n $HOME"#])
    }

    @Test("backslash escapes outside quotes")
    func backslashOutsideQuotes() throws {
        #expect(try splitShellWords(#"echo a\ b \"c\""#) == ["echo", "a b", #""c""#])
    }

    @Test("inside double quotes, backslash escapes only special characters")
    func backslashInsideDoubleQuotes() throws {
        #expect(try splitShellWords(#""\"q\" \\ \$x \d""#) == [#""q" \ $x \d"#])
    }

    @Test("adjacent quoted and unquoted parts join into one word")
    func concatenation() throws {
        #expect(try splitShellWords(#"--name="my app"'s'"#) == ["--name=my apps"])
    }

    @Test("empty quotes produce an empty argument")
    func emptyQuotes() throws {
        #expect(try splitShellWords(#"cmd "" ''"#) == ["cmd", "", ""])
    }

    @Test("variables are not expanded")
    func noExpansion() throws {
        #expect(try splitShellWords("echo $HOME ${USER} *") == ["echo", "$HOME", "${USER}", "*"])
    }

    @Test("backslash-newline is a line continuation")
    func lineContinuation() throws {
        #expect(try splitShellWords("echo a\\\nb") == ["echo", "ab"])
    }

    @Test("a trailing backslash stays literal")
    func trailingBackslash() throws {
        #expect(try splitShellWords("echo a\\") == ["echo", "a\\"])
    }

    @Test("unterminated quotes throw")
    func unterminated() {
        #expect(throws: ShellWordsError.unterminatedQuote("\"")) { try splitShellWords(#"sh -c "echo"#) }
        #expect(throws: ShellWordsError.unterminatedQuote("'")) { try splitShellWords("echo 'a") }
    }
}

@Suite("String-form command and entrypoint decoding")
struct StringFormCommandDecodingTests {

    private func service(_ yaml: String) throws -> Service? {
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        return compose.services["app"] ?? nil
    }

    @Test("string command is split into arguments")
    func stringCommand() throws {
        let app = try service("""
        services:
          app:
            image: node:22-alpine
            command: npm run dev
        """)
        #expect(app?.command == ["npm", "run", "dev"])
    }

    @Test("folded multi-line string command with a quoted script")
    func foldedCommand() throws {
        let app = try service("""
        services:
          app:
            image: python:3.12-slim
            command: >
              sh -c "alembic upgrade head &&
                     uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload"
        """)
        #expect(app?.command?.count == 3)
        #expect(app?.command?.prefix(2) == ["sh", "-c"])
        #expect(app?.command?.last?.hasPrefix("alembic upgrade head &&") == true)
        #expect(app?.command?.last?.hasSuffix("--port 8000 --reload") == true)
    }

    @Test("string entrypoint is split into arguments")
    func stringEntrypoint() throws {
        let app = try service("""
        services:
          app:
            image: alpine
            entrypoint: /bin/sh -c
            command: ["echo hi"]
        """)
        #expect(app?.entrypoint == ["/bin/sh", "-c"])

        let argv = ComposeUp.entrypointAndCommandArgs(entrypoint: app?.entrypoint, command: app?.command)
        #expect(argv.entrypointFlag == "/bin/sh")
        #expect(argv.positional == ["-c", "echo hi"])
    }

    @Test("array form is passed through unchanged")
    func arrayUnchanged() throws {
        let app = try service("""
        services:
          app:
            image: alpine
            command: ["echo", "a  b", "'c'"]
        """)
        #expect(app?.command == ["echo", "a  b", "'c'"])
    }

    @Test("unterminated quote is a decoding error naming the field")
    func unterminatedQuote() {
        do {
            _ = try service("""
            services:
              app:
                image: alpine
                command: sh -c "echo
            """)
            Issue.record("Expected a decoding error")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.last?.stringValue == "command")
            #expect(context.debugDescription.contains("unterminated double quote"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
