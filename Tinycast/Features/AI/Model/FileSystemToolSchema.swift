import Foundation

/// The `Files` built-ins: the eleven filesystem tools a chat's model may call on this Mac.
/// Every tool names a path or pattern; relative arguments resolve against the workspace root the
/// caller hands over. A refusal is a message content the model is meant to read, never a thrown stack
/// trace; a String does not conform to `Error`, so this is its conforming envelope.
struct FileToolParseFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

enum FileSystemToolSchema {
    /// The pseudo-slug the per-chat tools menu switches the set off with.
    static let slug = "files"
    static let origin = "Files"

    static func isBuiltinTool(_ name: String) -> Bool { names.contains(name) }
    /// Anything that changes what is on disk, or launches an app, needs the trust ladder's consent.
    static func isMutating(_ name: String) -> Bool { mutating.contains(name) }

    private static let names: Set<String> = [
        "read", "write", "edit", "glob", "grep", "create-directory", "delete-file",
        "get-file-info", "get-selected-items", "move-file", "open-item",
    ]
    private static let mutating: Set<String> = [
        "write", "edit", "create-directory", "delete-file", "move-file", "open-item",
    ]

    private static let workspaceNote =
        " Paths may be relative; a relative path is taken against the workspace root, which is "
        + "the home directory unless a call names a `path` root."

    static var tools: [AITool] {
        let path = [
            "type": JSONValue.string("string"),
            "description": JSONValue.string(
                "Absolute, `~/…`, or relative to the workspace root."),
        ]
        func stringTool(_ name: String, _ description: String, parameters: JSONValue) -> AITool {
            AITool(name: name, description: description, parameters: parameters, origin: origin)
        }
        return [
            stringTool(
                "read",
                "Read a text file or list a directory from the workspace. Files return cat -n"
                    + " style line-numbered content; directories return a sorted listing."
                    + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(path)]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "write",
                "Write content to a file, creating it (and any missing parent directories) or"
                    + " overwriting it if it already exists." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(path),
                        "content": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "edit",
                "Replace one unique string match or multiple non-overlapping matches inside a"
                    + " UTF-8 text file. Without replace_all the old text must match exactly once."
                    + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(path),
                        "old_text": .object(["type": .string("string")]),
                        "new_text": .object(["type": .string("string")]),
                        "replace_all": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("path"), .string("old_text"), .string("new_text")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "glob",
                "Find files by name pattern (supporting * and **) under a path or workspace"
                    + " root, most recently modified first. Without a / the pattern matches at any"
                    + " depth; a * never crosses a folder boundary." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "pattern": .object(["type": .string("string")]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Where the search starts; the workspace root when left out."),
                        ]),
                    ]),
                    "required": .array([.string("pattern")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "grep",
                "Search file contents by regular expression under a path or workspace root,"
                    + " returning path:line: text." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "pattern": .object(["type": .string("string")]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Where the search starts; the workspace root when left out."),
                        ]),
                        "case_insensitive": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("pattern")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "create-directory",
                "Creates a directory, including parent directories if needed." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(path)]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "delete-file",
                "Deletes a file. A directory is refused this way — its contents would go too."
                    + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(path)]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "get-file-info",
                "Gets information about a file or directory: kind, size, permissions, created"
                    + " and modified dates." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(path)]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "get-selected-items",
                "Gets the currently selected items in Finder, as one path per line; empty when"
                    + " nothing is selected.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "move-file",
                "Moves or renames a file or directory; the destination's parent must already"
                    + " exist, and an existing destination is never overwritten." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(path),
                        "destination": .object([
                            "type": .string("string"),
                            "description": .string(
                                "The new absolute, ~/… or relative path of the item."),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("destination")]),
                    "additionalProperties": .bool(false),
                ])),
            stringTool(
                "open-item",
                "Opens a file or directory with an optional app specification (an .app bundle,"
                    + " or an app name searched in the usual folders)." + workspaceNote,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(path),
                        "app": .object([
                            "type": .string("string"),
                            "description": .string(
                                "The app to open with; the workspace's default app otherwise."),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])),
        ]
    }

    /// One call of any Files tool, parsed and typed before anything touches the disk.
    struct Invocation: Equatable, Sendable {
        let name: String
        let path: String?
        let destination: String?
        let content: String?
        let oldText: String?
        let newText: String?
        let pattern: String?
        let replaceAll: Bool
        let caseInsensitive: Bool
        let app: String?

        init(name: String) {
            self.name = name
            path = nil
            destination = nil
            content = nil
            oldText = nil
            newText = nil
            pattern = nil
            replaceAll = false
            caseInsensitive = false
            app = nil
        }

        init(
            name: String, path: String? = nil, destination: String? = nil, content: String? = nil,
            oldText: String? = nil, newText: String? = nil, pattern: String? = nil,
            replaceAll: Bool = false, caseInsensitive: Bool = false, app: String? = nil
        ) {
            self.name = name
            self.path = path
            self.destination = destination
            self.content = content
            self.oldText = oldText
            self.newText = newText
            self.pattern = pattern
            self.replaceAll = replaceAll
            self.caseInsensitive = caseInsensitive
            self.app = app
        }
    }

    /// What each tool accepts; a key outside its row is refused, not ignored.
    private static let allowedParameters: [String: Set<String>] = [
        "read": ["path"],
        "write": ["path", "content"],
        "edit": ["path", "old_text", "new_text", "replace_all"],
        "glob": ["pattern", "path"],
        "grep": ["pattern", "path", "case_insensitive"],
        "create-directory": ["path"],
        "delete-file": ["path"],
        "get-file-info": ["path"],
        "get-selected-items": [],
        "move-file": ["path", "destination"],
        "open-item": ["path", "app"],
    ]
    private static let requiredParameters: [String: Set<String>] = [
        "read": ["path"],
        "write": ["path", "content"],
        "edit": ["path", "old_text", "new_text"],
        "glob": ["pattern"],
        "grep": ["pattern"],
        "create-directory": ["path"],
        "delete-file": ["path"],
        "get-file-info": ["path"],
        "get-selected-items": [],
        "move-file": ["path", "destination"],
        "open-item": ["path"],
    ]

    static func parse(_ name: String, _ arguments: String) -> Result<Invocation, FileToolParseFailure> {
        func refused(_ message: String) -> FileToolParseFailure { FileToolParseFailure(message: message) }
        guard names.contains(name) else {
            return .failure(refused("\u{201C}\(name)\u{201D} is not a tool this executor runs."))
        }
        let arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let value = try? JSONSerialization.jsonObject(
                with: Data(arguments.utf8), options: []),
            let object = value as? [String: Any]
        else {
            // No arguments at all is how get-selected-items is called; every other tool refuses.
            return arguments.isEmpty
                ? .success(Invocation(name: name))
                : .failure(refused("Arguments were not a JSON object."))
        }
        let allowed = allowedParameters[name] ?? []
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
            return .failure(refused("\u{201C}\(unknown)\u{201D} is not an argument this tool knows."))
        }
        for required in (requiredParameters[name] ?? []).sorted() {
            guard object[required] != nil else {
                return .failure(refused("No \(required) was given."))
            }
        }
        for key in ["path", "destination", "content", "old_text", "new_text", "pattern", "app"]
        where object[key] != nil {
            guard object[key] is String else {
                return .failure(refused("\(key) was not a string."))
            }
        }
        func string(_ key: String, trimming: Bool = true) -> String? {
            guard let given = object[key] as? String else { return nil }
            return trimming ? given.trimmingCharacters(in: .whitespaces) : given
        }
        for key in ["path", "destination", "pattern"] {
            if let given = string(key), given.isEmpty {
                return .failure(refused("\(key) was empty."))
            }
        }
        if let given = string("content", trimming: false), given.isEmpty {
            return .failure(refused("content was empty; pass a real string."))
        }
        if name == "edit", let given = string("old_text", trimming: false), given.isEmpty {
            return .failure(refused("old_text was empty; matching nothing would rewrite."))
        }
        var replaceAll = false
        if let given = object["replace_all"] {
            guard let flag = given as? Bool else {
                return .failure(refused("replace_all was not a boolean."))
            }
            replaceAll = flag
        }
        var caseInsensitive = false
        if let given = object["case_insensitive"] {
            guard let flag = given as? Bool else {
                return .failure(refused("case_insensitive was not a boolean."))
            }
            caseInsensitive = flag
        }
        return .success(
            Invocation(
                name: name, path: string("path"), destination: string("destination"),
                content: string("content", trimming: false), oldText: string("old_text", trimming: false),
                newText: string("new_text", trimming: false), pattern: string("pattern"),
                replaceAll: replaceAll, caseInsensitive: caseInsensitive, app: string("app")))
    }

    /// The row's code block shows what the call touches: the path, or what is searched.
    static func detail(of invocation: Invocation) -> String? {
        switch invocation.name {
        case "get-selected-items": return nil
        case "grep", "glob": return invocation.pattern
        default: return invocation.path ?? invocation.destination
        }
    }

    /// Same, read straight from the raw arguments so a malformed call still gets a row.
    static func detail(in arguments: String) -> String? {
        guard
            let value = try? JSONSerialization.jsonObject(
                with: Data(arguments.utf8), options: []),
            let object = value as? [String: Any]
        else { return nil }
        for key in ["path", "pattern"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// The consent dialog's line: what would happen, with the paths struck against the root.
    static func summary(of invocation: Invocation) -> String {
        invocation.name + (invocation.path.map { " \($0)" } ?? "")
    }
}
