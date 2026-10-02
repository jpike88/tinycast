import Foundation

/// A Quick AI escape leaves an empty input: leaving chat drops the draft at `pop`, dismissal drops
/// it at drop, and a re-presented chat never reinstates what a stray focus left behind.
@main
@MainActor
struct PaletteAIDraftTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    /// Chat summoned over a launcher search: fresh composer, the launcher still behind it.
    static func chatOverSearch() -> PaletteState {
        let vm = PaletteState()
        vm.prepare(mode: .launcher)
        vm.query = "clipboard"
        vm.selection = 3
        vm.push(mode: .ai)
        vm.query = "half-written answer"
        return vm
    }

    static func main() {
        let leaving = chatOverSearch()
        // Escape out of chat with the composer emptied: the ring's step back must not hand it the
        // draft, one more Escape than its dismissal deserves.
        expect(leaving.pop(), "chat has the launcher still behind it")
        expect(leaving.mode == .launcher, "the back step lands on the launcher")
        expect(leaving.query.isEmpty, "going back to it restores the launcher search: left empty")
        expect(leaving.selection == 3, "everything but the draft is restored exactly as it was")

        let inside = chatOverSearch()
        inside.push(mode: .aiHistory)
        inside.query = "logistics"
        expect(
            inside.pop() && inside.mode == .ai && inside.query == "half-written answer",
            "history's step back is still chat, so the draft it opened over is untouched")
        expect(
            inside.pop() && inside.mode == .launcher && inside.query.isEmpty,
            "and one more step leaves chat, the draft dropped on the way out")

        let returned = chatOverSearch()
        returned.push(mode: .clipboard)
        expect(
            returned.pop() && returned.mode == .ai && returned.query == "half-written answer",
            "Tabbing away and back is chat's own step, so the draft it opened over is untouched")

        let emptyInput = chatOverSearch()
        emptyInput.query = ""
        expect(
            emptyInput.pop() && emptyInput.mode == .launcher && emptyInput.query.isEmpty,
            "chat leaves nothing behind even on an empty composer")

        let unrelated = searchingLauncher()
        unrelated.pop()
        expect(
            unrelated.mode == .launcher && unrelated.query == "clipboard",
            "non-chat back steps still restore their query, chat or no chat")

        let dismissing = PaletteState()
        dismissing.prepare(mode: .ai)
        dismissing.query = "half-written answer"
        dismissing.dropAIDraft()
        expect(dismissing.query.isEmpty, "dismissing a chat screen empties the composer")

        let history = PaletteState()
        history.prepare(mode: .aiHistory)
        history.query = "past chats"
        history.dropAIDraft()
        expect(history.query.isEmpty, "Chat History's filter drops the same way, being a draft")

        let kept = PaletteState()
        kept.prepare(mode: .launcher)
        kept.query = "finder"
        kept.dropAIDraft()
        expect(
            kept.query == "finder",
            "the launcher's search is not a draft, so dismissal never touches it")

        let dropped = PaletteState()
        dropped.prepare(mode: .clipboard)
        dropped.query = "paste query"
        dropped.push(mode: .ai)
        dropped.query = "half-written answer"
        dropped.dropAIDraft()
        expect(
            dropped.pop() && dropped.mode == .clipboard && dropped.query == "paste query",
            "the dropped draft does not land on the clipboard, whose own search comes back")
    }

    private static func searchingLauncher() -> PaletteState {
        let vm = PaletteState()
        vm.prepare(mode: .launcher)
        vm.query = "clipboard"
        vm.selection = 2
        vm.push(mode: .clipboard)
        return vm
    }
}
