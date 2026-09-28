Builtin bash tool — proposal, not yet built
Status: draft. Until this ships, nothing here describes behaviour this app has.

A chat tool the app executes itself. One armable `AITool` named `bash`, plus its two
companions `get_task_output` and `kill_task`, whose invoker runs `/bin/sh -c` in-process on
this Mac — no MCP server, no resident process, nothing in Settings' server list. Raycast's
bash is the precedent its schema is borrowed verbatim from, carried through `AITool.parameters`
untouched; the field we visibly do not adopt is `__raycast_tool_call_description`, whose text
the *model* writes, and which can never be the only thing the user sees of a call.

## Scope: API routes only

`AIModelCapabilities.tools` is true for the API route, for Codex and for the Claude command —
but Codex and Claude are their own MCP clients and discover tools only through servers Tinycast
hands them. An in-process tool is invisible there, and that is the honest answer, not a gap to
paper over: wrapping the built-in in an internal stdio server (`tinycast-builtin`, via
`MCPProtocol`) would buy CLI parity at the price of a child process whose only job is to
re-expose the same `Process` behind a protocol — and it would hand the shell command to a
turn whose instructions still say never to run commands without Tinycast in the middle saying
what was approved. So: built-in tools arm API routes only,
exactly the way the MCP invariants already distinguish "the loop Tinycast runs" from "the loop
someone else runs". If CLI parity is ever wanted, it is a separate decision with its own doc —
likely through `AIToolServer`'s `command` transport pointed at a tiny bundled stdio server, not
through this one.

## Invariants

- **Off out of the box, and off means fully off.** `AISettingsStore.bashToolEnabled` is the
  flag and one projection guards it: no tool named to any model, no background registry, no
  consent grant alive. It is also dead whenever `aiEnabled` is off, because chat is the only
  consumer. Like `snippetsEnabled` and `mcpEnabled`, it is excluded from settings backups —
  adding it is a `SettingsBackupCoverage.deliberatelyExcluded` entry ("a shell tool is a
  capability; an import must not enable it") — and `SettingsBackup` documents its absence
  beside `snippetsEnabled`.
- **Every call asks, and only Settings may withhold or stand down.** Reuse `MCPTrustPolicy`
  and `MCPTrustChoice` verbatim with a `bashTrust: MCPTrust` on `AISettingsStore` — default
  `.ask` — rendered as its own AI-settings row, not as a server in the MCP list. The dialog is
  Tinycast's own three-way through `core.choose`: **Always Allow** persists `.always`,
  **Allow This Chat** grants for that `ChatSession.id` alone, **Don't Allow** — Escape's
  behaviour — refuses the one call. Escape never persists; a chat grant is stored on the
  coordinator keyed by the session id exactly as `MCPCoordinator.chatGrants` is, and dies with
  the chat. The dialog shows the **raw command string** — what actually runs — with the model's
  own call description shown beside it if carried, never instead of it. A refused call is
  content, an `AIToolResult.failure` the model can read, never a thrown error.
- **The tools menu switches it off like a server.** The built-in takes the pseudo-slug
  `bash` as its `ChatToolScope` key, so the existing composer menu's global switch and the
  exclusion list reach it with no second shape. A chat remembered with it excluded stays
  excluded.
- **One executor, off-main, nonisolated.** `nonisolated static func run(...)` takes every
  environment fact as a parameter — command, raw cwd, timeout, home directory, clock — so the
  harness drives it without touching a real shell layout. The `AIToolLoopProvider` invoker
  simply awaits it; no new actor, no queue, no `DispatchQueue`.
- **`/bin/sh -c`, never `/bin/bash`.** A non-interactive bash sources `BASH_ENV`, which an
  argument would set; POSIX `sh -c` sources nothing for `ENV` non-interactively. argv is the
  command text and nothing else — no user text or server-derived string rides anywhere an
  environment or profile could read it as one.
- **The child's environment is scrubbed, not inherited whole.** Build it from `ProcessInfo`'s
  environment minus anything that names a Tinycast secret or path, and never include a
  Keychain-derived value at all — there are none to leak, and the rule is that none can arrive.
  `PATH` stays, since a `git` that fails to resolve is a worse result than a `sh` that runs.
- **Timeout is SIGKILL to the process group.** Default 30 000 ms, capped at 600 000 —
  Raycast's semantics verbatim. The child is spawned with its own process group so its
  descendants die with it: a timed-out `npm run dev` leaves no orphaned watcher. A timed-out
  call fails as content noting the timeout.
- **No stdin.** The child's standard input is closed. An interactive command cannot prompt an
  entity that will never answer; the timeout bounds the ones that hang otherwise, and the
  result says so.
- **Output is one bounded string.** stdout and stderr interleave in exit order under one cap,
  cut to `AIToolLoopProvider.maxResultBytes` by the executor itself, then the loop's own cap
  applies on top — the same budget an MCP tool's result would have had. The exit status rides
  the result (`x\u{2009}exits\u{2009}n`, signalled names and all) rather than a thrown error.
- **A background task is a task id and nothing else.** `run_in_background` starts the same
  process with no timeout, registers it by id, and returns immediately; the id's output is
  bounded like any result, `get_task_output` is read-only on it, and `kill_task` is the
  process-group kill. The registry lives on the executor, keyed only to tasks this app spawned
  from this tool — a companion tool names no other process on the Mac. The registry is emptied
  and its tasks signalled when the flag turns off or at `prepareForTermination()`. One
  `get_task_output` that reports the task had finished consumes the retained output; output
  still flowing is capped by the same result bound, not accumulated unbounded.
- **The transcript row shows the command.** `ChatToolUse` renders `origin: "Bash"`, the row's
  title `Run command`, and the command text truncated the way a row may be — a stored call is
  never the raw arguments JSON where a command line would be hidden inside it.
- **Extensions cannot reach it.** Nothing is exported to `RaycastRuntime.generated.js` and
  nothing enters `Features/Extensions/`. This is a chat capability the user grants the app; the
  extensions sandbox renders what it is told and touches nothing that spawns processes.
- **The schema is adopted verbatim, refusals included.** `parameters` is the Raycast JSON
  above, keys `command`, `cwd`, `run_in_background`, `timeout` — carried through
  `AITool.parameters` untouched so each provider's framing is generated from it, never
  re-typed. A parse that fails — missing `command`, a `timeout` outside the cap, a key the
  schema never declared — is refused as content, never ignored and never defaulted.
- **Only chat arms it.** `quickActionProvider()` and the naming pass have no invoker; `send`
  and `regenerate` are the only call sites, the same two `toolAware` already serves.

## Shapes

`Tinycast/Features/AI/Service/BashToolExecutor.swift` — the invoker and the background
registry. `Tinycast/Features/AI/Model/BashToolSchema.swift` — the three `AITool` definitions
and the pure argument framing (`BashToolSchema.parse(arguments:) -> BashInvocation`). The
parse is pure — strings, integers, one enum — which is exactly what the harness can pin
without spawning a process.

```swift
struct BashInvocation: Sendable { command: String; cwd: URL?; timeout: Duration?; background: Bool }

enum BashToolSchema {
  static let tools: [AITool]           // bash, get_task_output, kill_task
  static let slug = "bash"
  static func parse(_ arguments: String) -> Result<BashInvocation, String>
}

struct BashToolExecutor: Sendable {
  /// Starts the process and awaits it; every fact the harness wants to vary is a parameter.
  nonisolated static func run(
    _ invocation: BashInvocation, homeDirectory: URL, clock: some Clock
  ) -> AIToolResult
  nonisolated static func isPermitted(trust: MCPTrust, grantedForChat: Bool, isChatGrant: Bool) -> Bool
  func taskOutput(id: String) -> ...
  func killTask(id: String) async throws -> ...
}
```

`AIChatCoordinator` changes are one merge in `tools(for:)` — the built-in's tools when
`aiSettings.bashToolEnabled` and the scope allows the `bash` slug — and one route in
`toolAware`'s invoker closure: the built-in's three names route to the executor, everything
else keeps going to `mcp`. Nothing in `MCP/` learns
it exists, so `Features/MCP/` changed nothing and keeps its invariant of knowing nothing about
chat.

## Settings

One row under AI → Chat, beside Tool call rounds: an Enable switch and a Trust picker
(`MCPTrust` verbatim) — and that is the whole surface. The switch is the flag itself; the
per-chat consent dialog the trust policy raises on first use is unchanged by it, and a
persisted `.always` can only be stood down from this row.

## Harnesses

`bash-tool-test` compiles the shipped model and executor sources — the Model folder imports
nothing but Foundation, so the `grep -rln 'import AppKit'` check stays clean — and pins:

- schema framing: tool names, `parameters` carried verbatim, the three tools armed together;
- argument parsing: well-formed calls, the refusals (missing `command`, bad `timeout`, an
  unknown key refused as content rather than ignored);
- execution against a stub "shell" (a path the harness sets): exit statuses, signal reporting,
  output truncation at `maxResultBytes`, stdout/stderr interleaving;
- timeout: a process that never exits is killed at the cap, group kill included;
- background tasks: a task id returned without waiting, `get_task_output`'s bounds,
  `kill_task`, the registry declining an id it did not spawn;
- trust: `MCPTrustPolicy` decisions against chat grants, Escape never persisting;
- `ai-chat-test` additions: the loop disarms the built-in when the flag is off or the scope
  blocks the slug, and API-route arming with a companion refused on a CLI route's session.

## Definition of done

As always: `./Scripts/run-tests.sh` clean, no new Debug warnings, `./Scripts/lint.sh` clean,
`grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/AI/Model/` returns
nothing, and [ai.md](../features/ai.md) gains the built-in's section in the same commit — the
providers table's "MCP tools" column becomes "tools", naming the built-in on API routes,
absent on the CLI ones.

## Open questions

- **Sandboxing the child itself.** Seatbelt (`sandbox-exec`) profiles are undocumented and
  machine-specific, and a call the user has just approved with the raw command in front of them
  has already spent the trust budget this surface grants. For now: no profile, the trust dialog
  is the boundary. Revisit if the tool ever grows a tighter default, e.g. "workspace-only
  writes" as a per-call option the schema names.
- **A workspace default for `cwd`.** Raycast defaults to its workspace root; Tinycast's private
  workspaces belong to specific processes, not to the user's intent. Default `cwd`: `nil` means
  the process inherits the app's — deciding between that and a Chat startup folder is a surface
  question, deferred until the executor is pinned by the harness above.
- **Reusing a previous command from the tool row.** Nothing planned; listed so it is not
  mistaken for a gap.
