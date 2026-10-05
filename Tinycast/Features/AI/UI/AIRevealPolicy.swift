import Foundation

/// How fast a streaming reply's reveal moves, so the transcript pours at the cadence the route
/// arrives at instead of surging on whatever bursts it happens to send. Pure over its inputs:
/// the harness drives it with the paces `AIChatState` measures.
struct AIRevealPolicy: Sendable {
    /// The pace before anything is measured and the floor after: fast natural reading, so the
    /// first shape never blasts in and a trickle never crawls.
    var reading: Double = 40
    /// The share of the unseen gap closing each second, used only by the unmeasured opener, so
    /// a backlog built before the first span closes never keys the reply to a crawl.
    var chase: Double = 1
    /// Once the reply is done, its unseen tail drains quickly instead of typing on after it.
    var sprint: Double = 16
    /// The pace of the reply's last few letters, slower than the floor: whatever pause follows
    /// them reads as tapering typing rather than a halt.
    var drip: Double = 15
    /// How many characters from the reveal edge stay on the drip while the reply still streams.
    var trail: Int = 20
    /// A reply never pours faster than this mid-stream, however fast the last chunk arrived.
    var ceiling: Double = 400
    /// The tail's own cap, so even a wall a route delivered at once is gone within a beat.
    var drainCeiling: Double = 800

    /// Characters to hand the display, from `revealed` toward `target`, over `elapsed`, exact
    /// to the fraction. `pace` is what the reply's arrival spans measured; nil until one has.
    func gain(
        from revealed: Int, toward target: Int, over elapsed: Duration, pace: Double?,
        draining: Bool
    ) -> Double {
        guard elapsed > .zero, target > revealed else { return 0 }
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let remaining = Double(target - revealed)
        var speed: Double
        if draining {
            speed = min(max(remaining * sprint, reading), drainCeiling)
        } else if target - revealed <= trail {
            // Caught up is where stillness lives: the edge never reaches the arrived text while
            // the reply streams, so a slower rest arrives typing, never as a stop.
            speed = drip
        } else if let pace {
            // A measured pour is the whole trick: it already covers each pause, so anything on
            // top would drain to caught-up and hand the reader a still frame until the next burst.
            speed = min(max(pace, reading), ceiling)
        } else {
            // Only the opener: reading speed, with the gap closed on top, so a huge first shape
            // cannot key the reply to a crawl before any span has measured a cadence.
            speed = min(reading + remaining * chase, ceiling)
        }
        return min(remaining, speed * seconds)
    }
}
