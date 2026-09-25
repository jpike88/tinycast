import Foundation

@main
struct BashToolTest {
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
            .appending(path: "tinycast-bash-tool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? Data("x".utf8).write(to: scratch.appending(path: "plain.txt"))

        // MARK: Schema framing

        let tools = BashToolSchema.tools
        check(
            "three tools arm together",
            tools.map(\.name) == ["bash", "get_task_output", "kill_task"])
        check("every row names one origin", Set(tools.map(\.origin)) == [BashToolSchema.origin])

        // MARK: Parsing

        func parsed(_ arguments: String) -> BashToolSchema.Invocation? {
            switch BashToolSchema.parse(arguments) {
            case .success(let invocation): return invocation
            case .failure: return nil
            }
        }

        func parseFailure(_ arguments: String) -> String? {
            switch BashToolSchema.parse(arguments) {
            case .success: return nil
            case .failure(let message): return message.message
            }
        }

        let minimal = parsed(#"{"command":"ls -l"}"#)
        check("a bare command parses", minimal?.command == "ls -l")
        check("no cwd defers to the caller", minimal?.cwdPath == nil)
        check("no timeout defers to the default", minimal?.timeout == nil)
        check("foreground unless named", minimal?.isBackground == false)
        check("arguments that are not JSON are refused", parseFailure("ls -l") != nil)
        check("a call of no arguments is refused", parseFailure("{}") != nil)
        check(
            "an unknown argument is refused, not ignored",
            parseFailure(#"{"command":"ls","shell":"/bin/zsh"}"#) != nil)
        check("an empty command is refused", parseFailure(#"{"command":""}"#) != nil)
        check(
            "a relative cwd is refused", parseFailure(#"{"command":"ls","cwd":"tmp"}"#) != nil)
        check(
            "a zero timeout is out of range",
            parseFailure(#"{"command":"ls","timeout":0}"#) != nil)
        check(
            "a timeout past the cap is out of range",
            parseFailure("{\"command\":\"ls\",\"timeout\":\(BashToolSchema.timeoutCap + 1)}") != nil)
        check(
            "a non-integer timeout is refused",
            parseFailure(#"{"command":"ls","timeout":"soon"}"#) != nil)
        check(
            "a boolean run_in_background parses",
            parsed(#"{"command":"serve","run_in_background":true}"#)?.isBackground == true)
        check(
            "a non-boolean flag is refused",
            parseFailure(#"{"command":"serve","run_in_background":"true"}"#) != nil)

        switch BashToolSchema.parseTaskID(#"{"id":"task-7"}"#) {
        case .success(let id): check("a companion names its task", id == "task-7")
        case .failure: check("a companion names its task", false)
        }
        switch BashToolSchema.parseTaskID(#"{}"#) {
        case .success: check("a companion with no id is refused", false)
        case .failure: check("a companion with no id is refused", true)
        }

        // MARK: cwd resolution

        let home = FileManager.default.homeDirectoryForCurrentUser
        let bare = BashToolSchema.Invocation(
            command: "ls", cwdPath: nil, timeout: nil, isBackground: false)
        let bareParsed = BashToolSchema.resolveCWD(bare, homeDirectory: home)
        switch bareParsed {
        case .success(let url): check("no cwd is the caller's default", url == home)
        case .failure: check("no cwd is the caller's default", false)
        }
        let tilde = BashToolSchema.Invocation(
            command: "ls", cwdPath: "~", timeout: nil, isBackground: false)
        let tildeParsed = BashToolSchema.resolveCWD(tilde, homeDirectory: home)
        switch tildeParsed {
        case .success(let url): check("~ is the home directory", url == home)
        case .failure: check("~ is the home directory", false)
        }
        let tildeChild = BashToolSchema.Invocation(
            command: "ls", cwdPath: "~/no-such-dir-please", timeout: nil, isBackground: false)
        var expandedMessage = ""
        switch BashToolSchema.resolveCWD(tildeChild, homeDirectory: home) {
        case .success: break
        case .failure(let message): expandedMessage = message.message
        }
        check("~ expands before it is checked", expandedMessage.contains(home.path))
        let missing = BashToolSchema.Invocation(
            command: "ls", cwdPath: "/no/such/dir", timeout: nil, isBackground: false)
        var missingMessage = ""
        switch BashToolSchema.resolveCWD(missing, homeDirectory: home) {
        case .success: break
        case .failure(let message): missingMessage = message.message
        }
        check(
            "a missing directory fails as content", missingMessage.contains("does not exist."))
        let notADirectory = BashToolSchema.Invocation(
            command: "ls", cwdPath: scratch.appending(path: "plain.txt").path,
            timeout: nil, isBackground: false)
        var notADirectoryMessage = ""
        switch BashToolSchema.resolveCWD(notADirectory, homeDirectory: home) {
        case .success: break
        case .failure(let message): notADirectoryMessage = message.message
        }
        check(
            "a plain file is not a directory",
            notADirectoryMessage.contains("is not a directory."))

        // MARK: Rendering

        check(
            "an empty output answers with the state alone",
            BashToolSchema.render(output: "", exitDescription: "exit 1") == "exit 1")
        check(
            "output with trailing newlines delivers text then state",
            BashToolSchema.render(output: "hi\n\n", exitDescription: "exit 0") == "hi\n[exit 0]")

        // MARK: Running

        let echo = await BashToolExecutor.run(
            invocation: BashToolSchema.Invocation(
                command: "echo hello", cwdPath: nil, timeout: nil, isBackground: false),
            workingDirectory: scratch)
        check(
            "simple output counts as exit zero",
            echo.content.contains("hello") && echo.content.contains("[exit 0]"))
        let failing = await BashToolExecutor.run(
            invocation: BashToolSchema.Invocation(
                command: "exit 3", cwdPath: nil, timeout: nil, isBackground: false),
            workingDirectory: scratch)
        check("an exit status is content, never a thrown error", failing.content.contains("exit 3"))
        let noisy = await BashToolExecutor.run(
            invocation: BashToolSchema.Invocation(
                command: "echo out; echo err 1>&2", cwdPath: nil, timeout: nil,
                isBackground: false),
            workingDirectory: scratch)
        check(
            "stdout and stderr share the one stream",
            noisy.content.contains("out") && noisy.content.contains("err"))
        let childRuns = await BashToolExecutor.run(
            invocation: BashToolSchema.Invocation(
                command: "basename \"$PWD\"", cwdPath: nil, timeout: nil, isBackground: false),
            workingDirectory: scratch)
        check("the child lands in the cwd", childRuns.content.contains(scratch.lastPathComponent))

        let timedOut = await BashToolExecutor.run(
            invocation: BashToolSchema.Invocation(
                command: "sleep 30", cwdPath: nil, timeout: 300, isBackground: false),
            workingDirectory: scratch)
        check("a hung command stops, as content", timedOut.content.contains("stopped at the timeout"))

        let scrubbed = BashToolExecutor.scrubbed(["TC_SECRET": "x", "HOME": "/u"])
        check("the app's own environment never rides along", scrubbed["TC_SECRET"] == nil)
        check("the user's environment does", scrubbed["HOME"] == "/u")

        // MARK: The registry

        let executor = await MainActor.run { BashToolExecutor() }
        let background = await MainActor.run {
            executor.startBackground(command: "sleep 0.3; echo ticked", cwd: scratch)
        }
        var last: String?
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            let report: String? = await MainActor.run {
                executor.output(id: background)
            }
            if let report, report.contains("is done") {
                last = report
                break
            }
        }
        check(
            "a task's output reads once it has finished",
            last?.contains("ticked") == true && last?.contains("is done") == true)
        let unknown: String? = await MainActor.run { executor.output(id: "task-nope") }
        check("an unknown id answers nothing", unknown == nil)
        let killedID = await MainActor.run {
            let id = executor.startBackground(command: "sleep 60; echo late", cwd: scratch)
            _ = executor.kill(id: id) ?? "missing"
            return id
        }
        var killedReport = ""
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            let report: String? = await MainActor.run {
                executor.output(id: killedID)
            }
            if let report, report.contains("is done") {
                killedReport = report
                break
            }
        }
        check("a killed task reads back as done", killedReport.contains("is done"))
        await MainActor.run { executor.stopAll() }
        check("off means the registry empties", !executor.hasBackgroundTasks)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

private extension Result where Success == URL, Failure == BashParseFailure {
    var failureCase: Bool {
        switch self {
        case .success: false
        case .failure: true
        }
    }
}
