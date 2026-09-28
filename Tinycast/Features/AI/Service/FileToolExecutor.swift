import AppKit
import Foundation

/// Runs the eleven `Files` built-ins on this Mac. Each call resolves its paths against the workspace
/// root the invoker hands over — the home directory unless the caller says otherwise — and answers
/// content the model can read; a failure is never a thrown error. Everything is plain `FileManager`
/// except opening items, and all of it happens detached from the main actor so a slow search never
/// stalls a palette run.
enum FileToolExecutor {
    static let maxReadBytes = 65_536
    static let maxReadLines = 2_000
    static let maxListings = 1_000
    static let maxMatches = 250
    static let maxWalkEntries = 100_000

    /// ~ expands to the caller's home: only exactly `~` or `~/…` counts, never `~name`.
    static func resolve(
        _ given: String, root: URL, homeDirectory: URL
    ) -> Result<URL, FileToolParseFailure> {
        func refused(_ message: String) -> Result<URL, FileToolParseFailure> {
            .failure(FileToolParseFailure(message: message))
        }
        guard !given.isEmpty else { return refused("No path was given.") }
        guard !given.contains("\0") else { return refused("The path has a NUL byte in it.") }
        let expanded: String
        if given == "~" {
            expanded = homeDirectory.path
        } else if given.hasPrefix("~/") {
            expanded = homeDirectory.appending(path: String(given.dropFirst(2))).path
        } else {
            expanded = given
        }
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appending(path: expanded)
        return .success(url)
    }

    /// One call, off the main actor; every answer is filed under `call.id`.
    static func run(
        _ call: AIToolCall, invocation: FileSystemToolSchema.Invocation,
        root: URL, homeDirectory: URL
    ) async -> AIToolResult {
        await Task.detached(priority: .userInitiated) {
            await Self.execute(call, invocation: invocation, root: root, homeDirectory: homeDirectory)
        }.value
    }

    /// Where a call's argument landed: a URL, or the refusal it is answered with instead.
    enum FoundPath {
        case found(URL)
        case refused(AIToolResult)
    }

    static func execute(
        _ call: AIToolCall, invocation: FileSystemToolSchema.Invocation,
        root rootURL: URL, homeDirectory: URL
    ) async -> AIToolResult {
        // The temp folder resolves through a symlink; enumerators answer the resolved form, so
        // relative paths only line up when a base is standardized first.
        let root = rootURL.standardizedFileURL
        func failure(_ message: String) -> AIToolResult { .failure(call.id, message) }
        func resolved(_ given: String?, naming: String = "path") -> FoundPath {
            guard let given else { return .refused(failure("No \(naming) was given.")) }
            switch resolve(given, root: root, homeDirectory: homeDirectory) {
            case .failure(let message): return .refused(failure(message.message))
            case .success(let url): return .found(url)
            }
        }

        switch invocation.name {
        case "read":
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url): return read(call, url)
            }
        case "write":
            guard let body = invocation.content else { return failure("No content was given.") }
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url): return write(call, url, content: body)
            }
        case "edit":
            guard let oldText = invocation.oldText, let newText = invocation.newText else {
                return failure("edit needs old_text and new_text.")
            }
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url):
                return edit(
                    call, url, oldText: oldText, newText: newText,
                    replaceAll: invocation.replaceAll)
            }
        case "glob":
            guard let pattern = invocation.pattern else { return failure("No pattern was given.") }
            return glob(
                call, searchRoot: invocation.path.map { resolved($0) } ?? .found(root),
                pattern: pattern)
        case "grep":
            guard let pattern = invocation.pattern else { return failure("No pattern was given.") }
            return grep(
                call,
                searchRoot: invocation.path.map { resolved($0) } ?? .found(root), pattern: pattern,
                caseInsensitive: invocation.caseInsensitive)
        case "create-directory":
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url): return createDirectory(call, url)
            }
        case "delete-file":
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url): return deleteFile(call, url)
            }
        case "get-file-info":
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url): return info(call, url)
            }
        case "get-selected-items":
            return FinderSelection.read(call)
        case "move-file":
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let source):
                switch resolved(invocation.destination, naming: "destination") {
                case .refused(let result): return result
                case .found(let destination): return move(call, source, destination)
                }
            }
        case "open-item":
            let app = invocation.app.flatMap { $0.isEmpty ? nil : $0 }
            switch resolved(invocation.path) {
            case .refused(let result): return result
            case .found(let url):
                return await openItem(call, url, app: app, homeDirectory: homeDirectory)
            }
        default:
            return failure("No executor runs \u{201C}\(invocation.name)\u{201D}.")
        }
    }

    // MARK: - read

    static func read(_ call: AIToolCall, _ url: URL) -> AIToolResult {
        func failure(_ message: String) -> AIToolResult { .failure(call.id, message) }
        func content(_ message: String) -> AIToolResult {
            AIToolResult(callID: call.id, content: message, isError: false)
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return failure("No such file or directory: \(url.path).")
        }
        guard !isDirectory.boolValue else {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else {
                return failure("This directory could not be listed.")
            }
            let sorted = entries.sorted()
            guard !sorted.isEmpty else { return content("(empty)") }
            let shown = sorted.prefix(maxListings).joined(separator: "\n")
            let truncated = sorted.count > maxListings ? "\n…truncated at \(maxListings)." : ""
            return content(shown + truncated)
        }
        guard let bytes = try? Data(contentsOf: url) else {
            return failure("This file could not be read.")
        }
        guard !bytes.contains(0) else { return failure("This is a binary file; read refuses it.") }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return failure("This file is not UTF-8 text; read refuses it.")
        }
        guard !text.isEmpty else { return content("(empty)") }
        let capped = String(text.prefix(maxReadBytes))
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        let truncated = lines.count > maxReadLines
        let numbered = lines
            .prefix(maxReadLines)
            .enumerated()
            .map { String($0.offset + 1) + "\t" + $0.element }
        return content(numbered.joined(separator: "\n") + (truncated ? "\n…truncated." : ""))
    }

    // MARK: - write

    static func write(_ call: AIToolCall, _ url: URL, content text: String) -> AIToolResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return .failure(
                call.id, "\u{201C}\(url.path)\u{201D} is a directory; write needs a file path.")
        }
        do {
            try fileManager.createDirectory(
                atPath: url.deletingLastPathComponent().path, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return AIToolResult(
                callID: call.id, content: "Wrote \(text.utf8.count) bytes to \(url.path).",
                isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    // MARK: - edit

    static func edit(
        _ call: AIToolCall, _ url: URL, oldText: String, newText: String, replaceAll: Bool
    ) -> AIToolResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return .failure(call.id, "No such file: \(url.path).") }
        guard let bytes = try? Data(contentsOf: url), !bytes.contains(0),
            let text = String(bytes: bytes, encoding: .utf8)
        else { return .failure(call.id, "This file is not UTF-8 text; edit refuses it.") }
        let remaining = text.split(separator: oldText, omittingEmptySubsequences: false)
        let hits = remaining.count - 1
        guard hits > 0 else { return .failure(call.id, "old_text did not match anything in it.") }
        guard replaceAll || hits == 1 else {
            return .failure(
                call.id,
                "old_text matches \(hits) times; name a unique string or set replace_all.")
        }
        let replaced = text.replacingOccurrences(of: oldText, with: newText)
        do {
            try replaced.write(to: url, atomically: true, encoding: .utf8)
            return AIToolResult(callID: call.id, content: "Edited \(url.path).", isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    // MARK: - glob

    static func glob(
        _ call: AIToolCall, searchRoot: FoundPath, pattern: String
    ) -> AIToolResult {
        let base: URL
        switch searchRoot {
        case .refused(let result): return result
        case .found(let found): base = found
        }
        let regex: NSRegularExpression
        switch globMatch(from: pattern) {
        case .failure(let message): return .failure(call.id, message.message)
        case .success(let built): regex = built
        }
        var entries: [(path: String, modified: Date)] = []
        let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [], errorHandler: nil)
        while let next = enumerator?.nextObject() as? URL, entries.count < maxWalkEntries {
            guard
                let values = try? next.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            let relative = relativePath(of: next, against: base)
            guard regex.firstMatch(in: relative, range: relative.entireRange) != nil else { continue }
            let modified =
                (try? next.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            entries.append((relative, modified))
            if entries.count >= maxMatches { break }
        }
        guard !entries.isEmpty else {
            return AIToolResult(callID: call.id, content: "(no matches)", isError: false)
        }
        let capped = entries
            .sorted { $0.modified > $1.modified }
            .prefix(maxMatches)
            .map { $0.path }
        let truncated = entries.count >= maxMatches ? "\n…the match list is capped." : ""
        return AIToolResult(
            callID: call.id, content: capped.joined(separator: "\n") + truncated, isError: false)
    }

    /// A CSV glob (* and **, ? for one character) as a plain regex over paths relative to the base.
    static func globMatch(from pattern: String) -> Result<NSRegularExpression, FileToolParseFailure> {
        var source = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        // Without a slash the pattern matches at any depth, like `**/` were its prefix.
        if !source.contains("/") { source = "**/" + source }
        var patternText = ""
        var search = source.startIndex
        while search < source.endIndex {
            let character = source[search]
            if source[search...].hasPrefix("**/") {
                patternText += "(?:[^/]*/)*"
                search = source.index(search, offsetBy: 3)
                continue
            }
            if source[search...].hasPrefix("**") {
                patternText += ".*"
                search = source.index(search, offsetBy: 2)
                continue
            }
            switch character {
            case "*": patternText += "[^/]*"
            case "?": patternText += "[^/]"
            case let other: patternText += NSRegularExpression.escapedPattern(for: String(other))
            }
            search = source.index(after: search)
        }
        // Matching is anchored to the full relative path; a pattern may also name a directory by prefix.
        do {
            let regex = try NSRegularExpression(pattern: "^" + patternText + "(?:$|/)")
            return .success(regex)
        } catch {
            return .failure(FileToolParseFailure(message: "The pattern was not a valid glob."))
        }
    }

    /// The temp folder names its prefix differently from what an enumerator hands back, so the
    /// path is anchored on the base's own tail rather than a component count.
    private static func relativePath(of url: URL, against base: URL) -> String {
        var parts = url.pathComponents
        guard let index = parts.lastIndex(of: base.lastPathComponent) else {
            return url.lastPathComponent
        }
        parts = Array(parts[(index + 1)...])
        return parts.isEmpty ? url.lastPathComponent : parts.joined(separator: "/")
    }

    // MARK: - grep

    static func grep(
        _ call: AIToolCall, searchRoot: FoundPath, pattern: String,
        caseInsensitive: Bool
    ) -> AIToolResult {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(
                pattern: pattern,
                options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            return .failure(call.id, "The pattern was not a valid regex.")
        }
        let base: URL
        switch searchRoot {
        case .refused(let result): return result
        case .found(let found): base = found
        }
        var lines: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: nil)
        while let next = enumerator?.nextObject() as? URL, lines.count < maxMatches {
            guard
                let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true,
                (values.fileSize ?? 0) < 1_048_576
            else { continue }
            guard let data = try? Data(contentsOf: next), !data.contains(0),
                let text = String(bytes: data, encoding: .utf8)
            else { continue }
            let relative = relativePath(of: next, against: base)
            for (offset, line) in
                text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where lines.count < maxMatches
            {
                let lineText = String(line)
                guard regex.firstMatch(in: lineText, range: lineText.entireRange) != nil else { continue }
                lines.append("\(relative):\(offset + 1): \(lineText)")
            }
        }
        guard !lines.isEmpty else {
            return AIToolResult(callID: call.id, content: "(no matches)", isError: false)
        }
        let capped = lines.count == maxMatches ? lines + ["…capped at \(maxMatches) matches."] : lines
        return AIToolResult(callID: call.id, content: capped.joined(separator: "\n"), isError: false)
    }

    // MARK: - create-directory, delete-file

    static func createDirectory(_ call: AIToolCall, _ url: URL) -> AIToolResult {
        do {
            try FileManager.default.createDirectory(atPath: url.path, withIntermediateDirectories: true)
            return AIToolResult(callID: call.id, content: "Created \(url.path).", isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    /// Files only — a directory goes with its contents, and the refusal says so plainly.
    static func deleteFile(_ call: AIToolCall, _ url: URL) -> AIToolResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(call.id, "No such file: \(url.path).")
        }
        guard !isDirectory.boolValue else {
            return .failure(
                call.id,
                "\u{201C}\(url.path)\u{201D} is a directory; deleting one takes its contents too.")
        }
        do {
            try fileManager.removeItem(atPath: url.path)
            return AIToolResult(callID: call.id, content: "Deleted \(url.path).", isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    // MARK: - info, move

    static func info(_ call: AIToolCall, _ url: URL) -> AIToolResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(call.id, "No such file or directory: \(url.path).")
        }
        let attributes =
            try? FileManager.default.attributesOfItem(atPath: url.path)
        var lines = [url.path, "kind: \(isDirectory.boolValue ? "directory" : "file")"]
        if let attributes {
            if let size = attributes[.size] as? Int64 {
                lines.append("size: \(size) bytes")
            }
            if let created = attributes[.creationDate] as? Date {
                let formatted = Self.medium.string(from: created)
                lines.append("created: " + formatted)
            }
            if let modified = attributes[.modificationDate] as? Date {
                lines.append("modified: " + Self.medium.string(from: modified))
            }
            if let permissions = attributes[.posixPermissions] as? Int {
                lines.append("posixPermissions: \(String(permissions, radix: 8))")
            }
            if let type = attributes[.type] as? FileAttributeType {
                lines.append("type: \(type)")
            }
        }
        return AIToolResult(callID: call.id, content: lines.joined(separator: "\n"), isError: false)
    }

    static func move(_ call: AIToolCall, _ source: URL, _ destination: URL) -> AIToolResult {
        let fileManager = FileManager.default
        var destinationIsDirectory: ObjCBool = false
        let destinationIsClaimed =
            fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory)
        guard source.path != destination.path else {
            return .failure(call.id, "The destination is the source itself.")
        }
        guard !destinationIsClaimed || destinationIsDirectory.boolValue else {
            return .failure(
                call.id,
                "\u{201C}\(destination.path)\u{201D} exists; move never overwrites a file.")
        }
        guard fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            return .failure(
                call.id,
                "The destination's parent \u{201C}\(destination.deletingLastPathComponent().path)\u{201D}"
                    + " does not exist; create it first.")
        }
        guard
            fileManager.fileExists(atPath: source.path) == true
        else { return .failure(call.id, "No such file or directory: \(source.path).") }
        do {
            try fileManager.moveItem(atPath: source.path, toPath: destination.path)
            return AIToolResult(
                callID: call.id,
                content: "Moved \(source.path) to \(destination.path).", isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    // MARK: - open-item

    /// The consent ladder decided this call already; `NSWorkspace` is just how it lands.
    static func openItem(
        _ call: AIToolCall, _ url: URL, app: String?, homeDirectory: URL
    ) async -> AIToolResult {
        do {
            if let app {
                guard let applicationURL = application(named: app, homeDirectory: homeDirectory) else {
                    return .failure(call.id, "No app named \u{201C}\(app)\u{201D} was found.")
                }
                _ = try await NSWorkspace.shared.open(
                    [url], withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration())
            } else {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return AIToolResult(callID: call.id, content: "Opened \(url.path).", isError: false)
        } catch {
            return .failure(call.id, describe(error: error))
        }
    }

    /// A name is searched in the usual folders; anything with a separator or `~` is a path.
    static func application(named name: String, homeDirectory: URL) -> URL? {
        guard !name.contains("/") else {
            let expanded = name.hasPrefix("~/")
                ? homeDirectory.appending(path: String(name.dropFirst(2))).path
                : name
            let url = URL(fileURLWithPath: expanded)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let file = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        for root in [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            homeDirectory.appending(path: "Applications").path,
        ] {
            let candidate = URL(fileURLWithPath: root).appending(path: file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static let medium: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func describe(error: Error) -> String {
        (error as NSError).localizedDescription
    }
}
extension String {
    /// The range a content match is searched over: the whole string, as UTF-16 offsets.
    var entireRange: NSRange { NSRange(location: 0, length: utf16.count) }
}

/// What `get-selected-items` answers with: the one call that needs Apple Events instead of
/// `FileManager`, run through `osascript` in a child — so the prompt and its consent come from
/// Finder the same way a scripted request would.
enum FinderSelection {
    static func read(_ call: AIToolCall) -> AIToolResult {
        let command = "tell application \"Finder\"\n"
            + "set raccolta to selection as alias list\n"
            + "set AppleScript's text item delimiters to linefeed\n"
            + "return raccolta as text\n"
            + "end tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(call.id, "osascript could not start: \(FileToolExecutor.describe(error: error))")
        }
        process.waitUntilExit()
        let text = String(
            bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let paths = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
        return AIToolResult(
            callID: call.id,
            content: paths.isEmpty ? "(nothing is selected in Finder)" : paths.joined(separator: "\n"),
            isError: false)
    }
}

extension String {
    /// Matches are found by counting the separators a split on the needle produces.
    func occurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return components(separatedBy: needle).count - 1
    }
}
