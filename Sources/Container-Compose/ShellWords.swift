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
//  ShellWords.swift
//  Container-Compose
//
//  Splits the string form of `command` and `entrypoint` into an argument
//  vector, matching how Docker Compose treats them.
//

import Foundation

public enum ShellWordsError: Error, LocalizedError, Equatable {
    case unterminatedQuote(Character)

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote(let quote):
            return "unterminated \(quote == "'" ? "single" : "double") quote"
        }
    }
}

/// Splits `input` into words using POSIX shell quoting rules, without any
/// expansion.
///
/// Docker Compose treats `command: npm run dev` as `["npm", "run", "dev"]`,
/// not as a single argument, and the same goes for `entrypoint`. Only
/// quoting is interpreted: no variables, globs, pipes or operators, so
/// `sh -c "a && b"` yields `["sh", "-c", "a && b"]`.
///
/// - Unquoted whitespace separates words.
/// - Single quotes preserve everything up to the next single quote.
/// - Double quotes preserve everything except `\`, which escapes only
///   `"`, `\`, `$`, `` ` `` and newline (the latter is removed).
/// - Outside quotes, `\` makes the next character literal; `\` followed by a
///   newline is removed.
/// - Quotes delimit but do not end a word, and `""` or `''` yields an empty
///   argument.
///
/// These are POSIX quoting rules. Docker Compose's own parser can differ in
/// rare cases, such as a backslash before an ordinary character inside double
/// quotes; common command lines split the same way.
///
/// - Throws: `ShellWordsError.unterminatedQuote` if a quote is never closed.
func splitShellWords(_ input: String) throws -> [String] {
    var words: [String] = []
    var current = ""
    // Tracks whether a word has started, so that `""` still yields an argument.
    var inWord = false
    var quote: Character?

    var characters = Array(input)[...]
    while let character = characters.popFirst() {
        switch quote {
        case "'":
            if character == "'" {
                quote = nil
            } else {
                current.append(character)
            }

        case "\"":
            if character == "\"" {
                quote = nil
            } else if character == "\\", let next = characters.first, "\"\\$`\n".contains(next) {
                characters.removeFirst()
                if next != "\n" { current.append(next) }
            } else {
                current.append(character)
            }

        default:
            if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == "\\" {
                // A trailing backslash has nothing to escape and stays literal.
                guard let next = characters.popFirst() else {
                    current.append(character)
                    inWord = true
                    break
                }
                if next != "\n" {
                    current.append(next)
                    inWord = true
                }
            } else if character.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(character)
                inWord = true
            }
        }
    }

    if let quote {
        throw ShellWordsError.unterminatedQuote(quote)
    }
    if inWord {
        words.append(current)
    }
    return words
}
