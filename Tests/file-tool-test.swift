import Foundation

@main
struct FileToolTest {
    static func main() async {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // MARK: Scratch area

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "tinycast-file-tool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        defer { try? FileManager.default.removeItem(at: scratch) }

        func parsed(_ name: String, _ arguments: String) -> FileSystemToolSchema.Invocation? {
            switch FileSystemToolSchema.parse(name, arguments) {
            case .success(let invocation): return invocation
            case .failure: return nil
            }
        }
        func parseFailure(_ name: String, _ arguments: String) -> String? {
            switch FileSystemToolSchema.parse(name, arguments) {
            case .success: return nil
            case .failure(let message): return message.message
            }
        }
        func run(_ name: String, _ arguments: String) async -> AIToolResult {
            let call = AIToolCall(id: "c", name: name, arguments: arguments)
            let invocation: FileSystemToolSchema.Invocation
            switch FileSystemToolSchema.parse(name, arguments) {
            case .success(let parsed): invocation = parsed
            case .failure(let failure): return .failure(call.id, failure.message)
            }
            return await FileToolExecutor.run(
                call, invocation: invocation, root: scratch, homeDirectory: home)
        }
        func ok(_ name: String, _ arguments: String) async -> String {
            let result = await run(name, arguments)
            check("\(name) answers content, not a thrown error", result.isError == false)
            return result.content
        }
        func refused(_ name: String, _ arguments: String) async -> String {
            let result = await run(name, arguments)
            check("\(name) refuses as content", result.isError == true)
            return result.content
        }

        // MARK: Schema framing

        let tools = FileSystemToolSchema.tools
        let names = tools.map(\.name)
        check(
            "eleven tools arm together",
            Set(names)
                == [
                    "read", "write", "edit", "glob", "grep", "create-directory", "delete-file",
                    "get-file-info", "get-selected-items", "move-file", "open-item",
                ])
        check(
            "every row names one origin",
            Set(tools.map(\.origin)) == [FileSystemToolSchema.origin])
        for name in [
            "write", "edit", "create-directory", "delete-file", "move-file", "open-item",
        ] {
            check("\(name) needs consent", FileSystemToolSchema.isMutating(name))
        }
        for name in ["read", "glob", "grep", "get-file-info", "get-selected-items"] {
            check("\(name) never changes the disk", !FileSystemToolSchema.isMutating(name))
        }

        // MARK: Parsing

        check("a bare read parses", parsed("read", #"{"path":"notes.txt"}"#)?.path == "notes.txt")
        check("get-selected-items needs nothing", parsed("get-selected-items", "{}") != nil)
        check("get-selected-items rides on empty arguments too", parsed("get-selected-items", "") != nil)
        check("unknown arguments are refused", parseFailure("read", #"{"path":"a","size":2}"#) != nil)
        check("a missing path is refused", parseFailure("read", "{}") != nil)
        check("a non-string path is refused", parseFailure("read", #"{"path":2}"#) != nil)
        check("an empty path is refused", parseFailure("read", #"{"path":" "}"#) != nil)
        check("an unknown tool is refused", parseFailure("write_everything", "{}") != nil)
        check(
            "a non-boolean replace_all is refused",
            parseFailure(
                "edit", #"{"path":"a","old_text":"x","new_text":"y","replace_all":"yes"}"#) != nil)
        check(
            "edit without old_text is refused",
            parseFailure("edit", #"{"path":"a","new_text":"y"}"#) != nil)
        check(
            "content that is not a string is refused",
            parseFailure("write", #"{"path":"a","content":7}"#) != nil)
        check(
            "content keeps its interior spacing",
            parsed("write", #"{"path":"a","content":"  hi\n"}"#)?.content == "  hi\n")
        check(
            "the row's detail reads the path out of the arguments",
            FileSystemToolSchema.detail(in: #"{"path":"/tmp/a","content":"x"}"#) == "/tmp/a")
        check(
            "the row's detail reads the pattern when there is no path",
            FileSystemToolSchema.detail(in: #"{"pattern":"*.swift"}"#) == "*.swift")
        check("garbage arguments leave the detail empty", FileSystemToolSchema.detail(in: "hi") == nil)

        // MARK: Path resolution

        switch FileToolExecutor.resolve("/tmp/abs", root: scratch, homeDirectory: home) {
        case .success(let url): check("an absolute path is itself", url.path == "/tmp/abs")
        case .failure: check("an absolute path is itself", false)
        }
        switch FileToolExecutor.resolve("notes.txt", root: scratch, homeDirectory: home) {
        case .success(let url):
            check(
                "a relative path lands in the workspace",
                url.standardized.path == scratch.standardized.path + "/notes.txt")
        case .failure: check("a relative path lands in the workspace", false)
        }
        switch FileToolExecutor.resolve("~", root: scratch, homeDirectory: home) {
        case .success(let url): check("~ is the home directory", url.path == home.path)
        case .failure: check("~ is the home directory", false)
        }
        switch FileToolExecutor.resolve("~/notes", root: scratch, homeDirectory: home) {
        case .success(let url):
            check(
                "~ expands before it is joined",
                url.path.contains(home.path) && url.path.hasSuffix("/notes"))
        case .failure: check("~ expands before it is joined", false)
        }

        // MARK: write, read, edit

        _ = await ok("write", #"{"path":"first.txt","content":"alpha\nbeta\nalpha\n"}"#)
        let readBack = await ok("read", #"{"path":"first.txt"}"#)
        check("read numbers its lines", readBack.contains("1\talpha") && readBack.contains("2\tbeta"))
        check("read shows every line", readBack.contains("3\talpha"))
        let nested = await ok("write", #"{"path":"deep/er/dir/nested.txt","content":"inside"}"#)
        check("write makes the parents and answers", nested.contains("Wrote") && nested.contains("nested.txt"))
        _ = await ok("write", #"{"path":"first.txt","content":"second time"}"#)
        let overwritten = await ok("read", #"{"path":"first.txt"}"#)
        check("write overwrites in place", overwritten.contains("second time"))
        _ = await ok(
            "edit", #"{"path":"first.txt","old_text":"second time","new_text":"third time"}"#)
        let edited = await ok("read", #"{"path":"first.txt"}"#)
        check("edit replaced the one match", edited.contains("third time"))
        _ = await ok("write", #"{"path":"repeat.txt","content":"twintw"}"#)
        let ambiguous = await refused(
            "edit", #"{"path":"repeat.txt","old_text":"tw","new_text":"TW"}"#)
        check("a two-way match refuses to guess", ambiguous.contains("replace_all"))
        _ = await ok(
            "edit", #"{"path":"repeat.txt","old_text":"tw","new_text":"TW","replace_all":true}"#)
        let replaced = await ok("read", #"{"path":"repeat.txt"}"#)
        check("every match went", replaced.contains("TWinTW"))
        _ = await refused(
            "edit", #"{"path":"first.txt","old_text":"nothing here","new_text":"x"}"#)
        _ = await refused("read", #"{"path":"no-such-file.txt"}"#)
        let binary = Data([0x00, 0x01, 0x02])
        try? binary.write(to: scratch.appending(path: "binary.bin"))
        let binaryRefused = await refused("read", #"{"path":"binary.bin"}"#)
        check("a binary file refuses read", binaryRefused.contains("binary"))

        // MARK: glob, grep, listing

        try? "plain\nwith NEEDLE mix\nneedle two\n"
            .write(to: scratch.appending(path: "grep-a.txt"), atomically: true, encoding: .utf8)
        try? "nothing here\n"
            .write(to: scratch.appending(path: "grep-b.txt"), atomically: true, encoding: .utf8)
        let hits = await ok("grep", #"{"pattern":"needle"}"#)
        check("grep returns path:line: text", hits.contains("grep-a.txt:3: needle two"))
        let folded = await ok("grep", #"{"pattern":"needle","case_insensitive":true}"#)
        check("grep can fold case", folded.contains("NEEDLE") && folded.contains("needle"))
        let foldedOff = await ok("grep", #"{"pattern":"needle"}"#)
        check("grep is case-sensitive without the flag", !foldedOff.contains("NEEDLE"))
        let noHits = await ok("grep", #"{"pattern":"zzzz-never"}"#)
        check("a search with no hits answers with its emptiness", noHits.contains("no matches"))
        let badRegex = await refused("grep", #"{"pattern":"[unclosed"}"#)
        check("a bad regex is content, not a crash", badRegex.contains("regex"))

        try? FileManager.default.createDirectory(
            at: scratch.appending(path: "sub"), withIntermediateDirectories: true)
        try? "under\n"
            .write(to: scratch.appending(path: "sub/deep.txt"), atomically: true, encoding: .utf8)
        let anyDepth = await ok("glob", #"{"pattern":"deep.txt"}"#)
        check("a slash-less pattern matches at any depth", anyDepth.contains("sub/deep.txt"))
        let all = await ok("glob", #"{"pattern":"**/*.txt"}"#)
        check("** crosses and names its matches", all.contains("deep.txt") && all.contains("first.txt"))
        let top = await ok("glob", #"{"pattern":"*/*.txt"}"#)
        check(
            "a pattern with a slash stays at its depth",
            top.contains("sub/deep.txt") && !top.contains("\ndeep.txt"))
        let directory = await ok("read", #"{"path":"sub"}"#)
        check("a directory read lists its contents", directory.contains("deep.txt"))

        // MARK: create-directory, delete-file, get-file-info, move-file

        let created = await ok("create-directory", #"{"path":"made/here"}"#)
        check("create-directory answers with where it landed", created.contains("Created"))
        var isDirectory: ObjCBool = false
        check(
            "the intermediate parents arrived too",
            FileManager.default.fileExists(
                atPath: scratch.appending(path: "made/here").path, isDirectory: &isDirectory)
                && isDirectory.boolValue)
        let folderRefusal = await refused("delete-file", #"{"path":"sub"}"#)
        check("a directory refuses delete-file", folderRefusal.contains("directory"))
        let deleted = await ok("delete-file", #"{"path":"grep-b.txt"}"#)
        check("a file delete answers", deleted.contains("Deleted"))
        check(
            "the file is really gone",
            !FileManager.default.fileExists(atPath: scratch.appending(path: "grep-b.txt").path))

        let info = await ok("get-file-info", #"{"path":"first.txt"}"#)
        check("file info names kind and size", info.contains("kind: file") && info.contains("size:"))
        let directoryInfo = await ok("get-file-info", #"{"path":"sub"}"#)
        check("directory info names the kind", directoryInfo.contains("kind: directory"))
        let missingInfo = await refused("get-file-info", #"{"path":"does-not-exist"}"#)
        check("missing info is content, not a crash", missingInfo.contains("No such"))

        try? "portable\n"
            .write(to: scratch.appending(path: "mover.txt"), atomically: true, encoding: .utf8)
        _ = await ok("move-file", #"{"path":"mover.txt","destination":"moved.txt"}"#)
        check(
            "the rename landed",
            FileManager.default.fileExists(atPath: scratch.appending(path: "moved.txt").path)
                && !FileManager.default.fileExists(atPath: scratch.appending(path: "mover.txt").path))
        let surviving = await refused(
            "move-file", #"{"path":"first.txt","destination":"moved.txt"}"#)
        check("move never overwrites", surviving.contains("never overwrites") || surviving.contains("exists"))
        let ghostParent = await refused(
            "move-file", #"{"path":"moved.txt","destination":"ghostward/moved.txt"}"#)
        check("a ghost parent is refused", ghostParent.contains("does not exist"))

        // MARK: App lookup (never launched)

        let terminal = FileToolExecutor.application(named: "Terminal", homeDirectory: home)
        check("a known system app is found", terminal?.lastPathComponent == "Terminal.app")
        check(
            "an unknown app is refused",
            FileToolExecutor.application(named: "no-such-app-please", homeDirectory: home) == nil)

        // MARK: The harness passes

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
