import Foundation

/// The `calculator` built-in's executor: a query in, the engine's canonical answer back.
/// Pure — the clock, the calendar, the rate table and the region currency are injected, the
/// way `CalcMemo` supplies them at the palette's own boundary.
enum CalcToolExecutor {
    static func invoke(
        _ call: AIToolCall, rates: CurrencyRates?, region: String?,
        now: Date, calendar: Calendar
    ) -> AIToolResult {
        guard let query = CalcToolSchema.query(from: call.arguments) else {
            return .failure(call.id, "The tool call carried no query to calculate.")
        }
        switch CalcEngine.evaluate(
            query, now: now, calendar: calendar, rates: rates, region: region)?.payload
        {
        case let .value(_, copyText):
            return AIToolResult(callID: call.id, content: copyText, isError: false)
        case let .error(message):
            return .failure(call.id, message)
        case nil:
            return .failure(call.id, "Nothing to calculate: that was not calculator input.")
        }
    }
}
