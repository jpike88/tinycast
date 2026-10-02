import Foundation

/// The bash built-in: one executor in-process, three tools it fronts. The schema is Raycast's
/// carried into proper JSON Schema casing; `__raycast_tool_call_description` is dropped because
/// its text is the model's own — the dialog shows the command, never a model-written summary of it.
/// A refusal is a message content the model is meant to read, never a thrown stack trace; a
/// String does not conform to `Error`, so this is its conforming envelope.
struct BashParseFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

enum BashToolSchema {
    static let toolName = "bash"
    static let getOutputToolName = "get_task_output"
    static let killTaskToolName = "kill_task"
    /// The pseudo-slug the per-chat tools menu switches it off with.
    static let slug = "bash"
    static let origin = "Bash"
    static let title = "Run command"
    static let defaultTimeout = 30_000
    static let timeoutCap = 600_000

    static func isBuiltinTool(_ name: String) -> Bool {
        name == toolName || name == getOutputToolName || name == killTaskToolName
    }

    static var tools: [AITool] {
        let timeout = [
            "type": JSONValue.string("integer"),
            "description": JSONValue.string(
                "Timeout in milliseconds. Defaults to 30000, capped at 600000."),
            "minimum": JSONValue.number(1),
            "maximum": JSONValue.number(Double(timeoutCap)),
        ]
        return [
            AITool(
                name: toolName,
                description:
                    "Run a shell command and return its output. Built-in to Tinycast, no MCP server. "
                    + "Set run_in_background for a long-lived command (dev server, watcher, long "
                    + "build) that must keep running after this call; read its output with "
                    + "get_task_output and stop it with kill_task. The timeout bounds a foreground "
                    + "command, never a background one.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"), "minLength": .number(1),
                        ]),
                        "cwd": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Working directory for the command; ~ expands to the home "
                                    + "directory, and the directory must already exist."),
                        ]),
                        "run_in_background": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Start in the background with no timeout and answer with a task "
                                    + "id instead."),
                        ]),
                        "timeout": .object(timeout),
                    ]),
                    "required": .array([.string("command")]),
                    "additionalProperties": .bool(false),
                ]),
                origin: Self.origin, title: Self.title),
            AITool(
                name: getOutputToolName,
                description:
                    "Read what a background task of this tool has written so far, and whether it "
                    + "has exited.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                    "additionalProperties": .bool(false),
                ]),
                origin: Self.origin, title: "Task output"),
            AITool(
                name: killTaskToolName,
                description: "Stop a background task of this tool, its children included.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                    "additionalProperties": .bool(false),
                ]),
                origin: Self.origin, title: "Stop task"),
        ]
    }

    /// One call of the `bash` tool, parsed and bounded before anything spawns.
    struct Invocation: Equatable, Sendable {
        let command: String
        var cwdPath: String?
        var timeout: Int?
        var isBackground: Bool
    }

    static func parse(_ arguments: String) -> Result<Invocation, BashParseFailure> {
        func refused(_ message: String) -> BashParseFailure { BashParseFailure(message: message) }
        guard !arguments.isEmpty else { return .failure(refused("No command was given.")) }
        guard
            let value = try? JSONSerialization.jsonObject(
                with: Data(arguments.utf8), options: []),
            let object = value as? [String: Any]
        else { return .failure(refused("Arguments were not a JSON object.")) }
        let allowed: Set<String> = ["command", "cwd", "run_in_background", "timeout"]
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            return .failure(refused("\u{201C}\(unknown)\u{201D} is not an argument this tool knows."))
        }
        guard let command = object["command"] as? String, !command.isEmpty else {
            return .failure(refused("No command was given."))
        }
        guard object["cwd"] == nil || object["cwd"] is String else {
            return .failure(refused("cwd was not a string."))
        }
        var cwdPath: String?
        if let given = (object["cwd"] as? String)?.trimmingCharacters(in: .whitespaces) {
            guard !given.isEmpty else { return .failure(refused("cwd was empty.")) }
            guard given.hasPrefix("/") || given == "~" || given.hasPrefix("~/") else {
                return .failure(refused("cwd was not an absolute path."))
            }
            cwdPath = given
        }
        if let given = object["run_in_background"], !(given is Bool) {
            return .failure(refused("run_in_background was not a boolean."))
        }
        var timeout: Int?
        if let given = object["timeout"] {
            guard let count = given as? Int else {
                return .failure(refused("timeout was not an integer."))
            }
            guard (1...timeoutCap).contains(count) else {
                return .failure(
                    refused("timeout is out of range; the cap is \(timeoutCap) milliseconds."))
            }
            timeout = count
        }
        return .success(
            Invocation(
                command: command, cwdPath: cwdPath, timeout: timeout,
                isBackground: object["run_in_background"] as? Bool ?? false))
    }

    /// `~` expands to the caller's home: only exactly `~` or `~/…` counts, never `~name`.
    static func resolveCWD(
        _ invocation: Invocation, homeDirectory: URL
    ) -> Result<URL, BashParseFailure> {
        guard let given = invocation.cwdPath else { return .success(homeDirectory) }
        let expanded: String
        if given == "~" {
            expanded = homeDirectory.path
        } else if given.hasPrefix("~/") {
            expanded = homeDirectory.appending(path: String(given.dropFirst(2))).path
        } else {
            expanded = given
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        guard exists else {
            return .failure(
                BashParseFailure(message: "cwd \u{201C}\(expanded)\u{201D} does not exist."))
        }
        guard isDirectory.boolValue else {
            return .failure(
                BashParseFailure(message: "\u{201C}\(expanded)\u{201D} is not a directory."))
        }
        return .success(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    /// The row's code block shows the command exactly as the model handed it over; this
    /// reads one key instead of running the full parse, so a malformed call still gets a row.
    static func command(in arguments: String) -> String? {
        guard
            let value = try? JSONSerialization.jsonObject(
                with: Data(arguments.utf8), options: []),
            let object = value as? [String: Any],
            let command = object["command"] as? String,
            !command.isEmpty
        else { return nil }
        return command
    }

    static func parseTaskID(_ arguments: String) -> Result<String, BashParseFailure> {
        guard
            let value = try? JSONSerialization.jsonObject(
                with: Data(arguments.utf8), options: []),
            let object = value as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty
        else { return .failure(BashParseFailure(message: "No task id was given.")) }
        return .success(id)
    }

    /// What the model reads back: the command's output, then how it ended.
    static func render(output: String, exitDescription: String) -> String {
        output.isEmpty
            ? exitDescription
            : output.trimmingCharacters(in: .newlines) + "\n[" + exitDescription + "]"
    }
}
