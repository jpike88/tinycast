import Darwin
import Foundation

/// Runs a command under `/bin/sh -c` with the child as its own process-group leader, so a
/// timeout, a kill task or shutdown takes its descendants down too — `Process` has no group
/// API, and a `sh` pipeline's descendants would otherwise hold the pipe open long past their
/// parent. stdout and stderr share one pipe, so their text arrives in the order it was written.
enum BashProcess {
    enum SpawnError: Error, CustomStringConvertible {
        case failed(Int32)

        var description: String {
            switch self {
            case .failed(let code): return "posix_spawn family failed with \(code)."
            }
        }
    }

    struct Spawned: Sendable {
        let processID: pid_t
        /// The read end of the shared stdout/stderr pipe; the child never inherits it back.
        let outputDescriptor: Int32
    }

    static func spawn(
        command: String, workingDirectory: URL?, environment: [String: String]
    ) throws -> Spawned {
        try _spawn(
            executable: "/bin/sh", arguments: ["-c", command],
            workingDirectoryPath: workingDirectory?.path, environment: environment)
    }

    /// Exposed so the harness can drive a stub program instead of this machine's own `/bin/sh`.
    static func _spawn(
        executable: String, arguments: [String], workingDirectoryPath: String?,
        environment: [String: String]
    ) throws -> Spawned {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let workingDirectoryPath {
            let status = posix_spawn_file_actions_addchdir(&actions, workingDirectoryPath)
            guard status == 0 else { throw SpawnError.failed(status) }
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError.failed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])
        do {
            let openNull = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            guard openNull == 0,
                posix_spawn_file_actions_adddup2(&actions, writeFD, 1) == 0,
                posix_spawn_file_actions_adddup2(&actions, writeFD, 2) == 0,
                posix_spawn_file_actions_addclose(&actions, writeFD) == 0,
                posix_spawn_file_actions_addclose(&actions, readFD) == 0
            else { throw SpawnError.failed(errno) }

            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            defer { posix_spawnattr_destroy(&attr) }
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            posix_spawnattr_setsigmask(&attr, &noSignals)
            posix_spawnattr_setsigdefault(&attr, &noSignals)
            posix_spawnattr_setpgroup(&attr, 0) // 0 makes the child its own group leader.
            posix_spawnattr_setflags(
                &attr,
                Int16(
                    POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP
                        | POSIX_SPAWN_CLOEXEC_DEFAULT)) // the app's fds are not the child's

            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
            argv += arguments.map { $0.withCString(strdup) }
            argv.append(nil)
            var env: [UnsafeMutablePointer<CChar>?] = []
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                env.append(name.withCString { strdup("\($0)=\(value)") })
            }
            env.append(nil)
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }

            var pid: pid_t = 0
            let status = posix_spawn(&pid, executable, &actions, &attr, &argv, &env)
            guard status == 0 else { throw SpawnError.failed(status) }
            // The parent's copy of the write end must go: with it held open, the child's pipe
            // never reaches EOF and every reader waits forever — this exact hang.
            close(writeFD)
            return Spawned(processID: pid, outputDescriptor: readFD)
        } catch {
            // Failed before a child could inherit either end; both are the caller's to close.
            close(readFD)
            close(writeFD)
            throw error
        }
    }

    /// The child is its own group leader, so its pid is its group's negative.
    static func killGroup(of pid: pid_t) {
        kill(-pid, SIGKILL)
    }

    /// Reads the pipe until EOF — which arrives only once every writer, the children included,
    /// has gone — appending under the buffer's cap; the descriptor closes with the handle.
    static func readOutput(_ descriptor: Int32, into buffer: OutputBuffer) {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        while true {
            let data = handle.readData(ofLength: 65_536)
            if data.isEmpty { break }
            buffer.append(data)
        }
    }

    /// How a `waitpid` status is described to the model — never a thrown error. Darwin's
    /// WIF*/WEXIT* macros are not functions on this SDK, so decode the status bits directly:
    /// the low seven bits are a terminating signal, the next eight the exit code.
    static func exitDescription(_ status: Int32) -> String {
        let signal = status & 0x7F
        if signal != 0 { return "killed by signal \(signal)" }
        return "exit \((status >> 8) & 0xFF)"
    }

    static func wasGroupKilled(_ status: Int32) -> Bool {
        (status & 0x7F) == Int32(SIGKILL)
    }
}

/// A lock and a byte cap for pipe text a reader fills; content is cut again on its way back to
/// the model, but nothing here lets a fast pipe grow past a megabyte to begin with.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let capBytes: Int

    init(capBytes: Int) {
        self.capBytes = capBytes
    }

    func append(_ incoming: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < capBytes else { return }
        data.append(incoming.prefix(capBytes - data.count))
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(bytes: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// What a foreground `bash` call answers with.
struct BashExecution: Sendable {
    let output: String
    let exitLabel: String

    var content: String {
        BashToolSchema.render(output: output, exitDescription: exitLabel)
    }
}

/// One background task: a spawned group, its pipe text and how it ended. Its own detached
/// lifecycle (spawn, read, wait) writes; the registry on the main actor reads.
final class BashTaskRecord: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private let buffer = OutputBuffer(capBytes: 1_048_576)
    private var processID: pid_t?
    private var exitStatus: Int32?
    private var startFailure: String?
    private var killWhenSpawned = false

    init(id: String) {
        self.id = id
    }

    /// A kill that arrives before the spawn has landed is remembered and applied the moment
    /// the pid is known; a finished task is never signalled, its pid may be someone else's.
    func stop() {
        stopIfAlive()
    }

    /// Only an unfinished task is killed — a reaped pid may already belong to someone else.
    private func stopIfAlive() {
        lock.lock()
        defer { lock.unlock() }
        guard exitStatus == nil, startFailure == nil else { return }
        if let pid = processID {
            BashProcess.killGroup(of: pid)
        } else {
            killWhenSpawned = true
        }
    }

    private func spawned(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        processID = pid
        if killWhenSpawned { BashProcess.killGroup(of: pid) }
    }

    private func failedToStart(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        startFailure = message
    }

    private func finished(status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        exitStatus = status
    }

    /// The whole lifecycle of one background task, on a detached thread of its own; nothing
    /// cancels it, the timeout never applies, and only the pipe's EOF finishes reading.
    func run(command: String, cwd: URL, environment: [String: String]) {
        do {
            let spawned = try BashProcess.spawn(
                command: command, workingDirectory: cwd, environment: environment)
            self.spawned(spawned.processID)
            BashProcess.readOutput(spawned.outputDescriptor, into: buffer)
            var status: Int32 = 0
            while waitpid(spawned.processID, &status, 0) == -1 && errno == EINTR {}
            finished(status: status)
        } catch {
            failedToStart(error.localizedDescription)
        }
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil || startFailure != nil
    }

    /// What `get_task_output` and `kill_task` answer with: the text so far, then the state.
    var report: String {
        lock.lock()
        defer { lock.unlock() }
        let text = buffer.text.trimmingCharacters(in: .newlines)
        let state: String
        if let failure = startFailure {
            state = "Task \(id) failed to start. \(failure)"
        } else if let status = exitStatus {
            state = "Task \(id) is done; " + BashProcess.exitDescription(status) + "."
        } else {
            state = "Task \(id) has not exited yet."
        }
        return text.isEmpty ? state : text + "\n" + state
    }
}

/// Runs the bash built-in on this Mac. Foreground calls are one await on the invoker; background
/// tasks live in this registry until they exit, are killed, the flag turns off or the app leaves.
@MainActor
final class BashToolExecutor {
    private var records: [BashTaskRecord] = []
    private var counter = 0

    static let maxRecords = 32

    var hasBackgroundTasks: Bool { !records.isEmpty }

    /// Switched off, or the app leaves: every task stops and the registry forgets them.
    func stopAll() {
        for record in records { record.stop() }
        records = []
    }

    // MARK: - Foreground

    /// Spawns and awaits on a detached thread; trust and shaping stay with the caller.
    nonisolated static func run(
        invocation: BashToolSchema.Invocation,
        workingDirectory: URL,
        clock: ContinuousClock = ContinuousClock()
    ) async -> BashExecution {
        let milliseconds = invocation.timeout ?? BashToolSchema.defaultTimeout
        return await Task.detached(priority: .userInitiated) {
            do {
                let spawned = try BashProcess.spawn(
                    command: invocation.command, workingDirectory: workingDirectory,
                    environment: BashToolExecutor.scrubbed(
                        ProcessInfo.processInfo.environment))
                let buffer = OutputBuffer(capBytes: 1_048_576)
                let reader = Task.detached(priority: .utility) {
                    BashProcess.readOutput(spawned.outputDescriptor, into: buffer)
                }
                let watcher = Task.detached(priority: .utility) {
                    try? await clock.sleep(for: Duration.milliseconds(Int64(milliseconds)))
                    BashProcess.killGroup(of: spawned.processID)
                }
                var status: Int32 = 0
                while waitpid(spawned.processID, &status, 0) == -1 && errno == EINTR {}
                // A straggler from the command may still hold the pipe; a bounded grace then a
                // group kill guarantees the read ends without taking honest work down with it.
                try? await clock.sleep(for: .milliseconds(200))
                BashProcess.killGroup(of: spawned.processID)
                await reader.value
                watcher.cancel()
                let killed = BashProcess.wasGroupKilled(status)
                return BashExecution(
                    output: buffer.text,
                    exitLabel: killed ? "stopped at the timeout" : BashProcess.exitDescription(status))
            } catch {
                return BashExecution(
                    output: "", exitLabel: "failed to start: \(error.localizedDescription)")
            }
        }.value
    }

    /// The command's environment is everything this app inherited, minus anything of ours:
    /// `TC_`-prefixed values could hand a shell state it must never read.
    nonisolated static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("TC_") && !$0.key.hasPrefix("TINYCAST") }
    }

    // MARK: - Background

    /// Answers at once with a task id; the process and its output belong to the registry.
    func startBackground(command: String, cwd: URL) -> String {
        counter += 1
        let id = "task-\(counter)"
        let record = BashTaskRecord(id: id)
        // The oldest records go first; an unfinished one is killed rather than forgotten.
        while records.count >= Self.maxRecords {
            records.removeFirst().stop()
        }
        records.append(record)
        Task.detached(priority: .utility) {
            record.run(
                command: command, cwd: cwd,
                environment: Self.scrubbed(ProcessInfo.processInfo.environment))
        }
        return id
    }

    func output(id: String) -> String? {
        records.first { $0.id == id }?.report
    }

    /// Kills the group; the record stays until the pipe reaches its own EOF, so one last
    /// `get_task_output` reads what it managed to write.
    func kill(id: String) -> String? {
        let record = records.first { $0.id == id }
        guard let record else { return nil }
        record.stop()
        return record.report
    }
}
