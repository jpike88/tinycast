// Standalone test for the `calculator` AI tool, compiling the real engine sources.
import Foundation

@main
@MainActor
struct CalcToolTests {
    static var failures = 0
    static var passed = 0

    static func main() {
        toolCatalogIsOffered()
        argumentsYieldOneQuery()
        evaluateArithmetic()
        evaluateUnitConversions()
        evaluateCurrencyWithRates()
        aConversionFailureIsReadable()
        notCalculatorInputIsReadable()

        print("\(passed) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passed += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private static var calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_788_775_200)

    static func toolCatalogIsOffered() {
        let tool = CalcToolSchema.tool()
        expect(tool.name == "calculator", "the built-in tool is named calculator")
        expect(tool.origin == "Calculator", "the transcript row says the call came from Calculator")
        expect(tool.title == "Calculate", "the tool carries a human title")
        expect(!tool.description.isEmpty, "the model is told when to call it")
        let schema = tool.parameters.objectValue
        expect(schema?["type"]?.stringValue == "object", "the schema is an object")
        expect(
            schema?["required"]?.arrayValue?.first?.stringValue == "query",
            "the query is the one required field")
        expect(CalcToolSchema.isBuiltIn("calculator"), "a call by that name is built-in")
        expect(!CalcToolSchema.isBuiltIn("mcp__a__b"), "an MCP tool never routes to the built-in")
    }

    static func argumentsYieldOneQuery() {
        expect(CalcToolSchema.query(from: #"{"query": "2 + 2"}"#) == "2 + 2", "the query is read")
        expect(
            CalcToolSchema.query(from: #"{"query":"  padded  "}"#) == "padded",
            "a padded query is trimmed")
        expect(CalcToolSchema.query(from: #"{"q": "2 + 2"}"#) == nil, "no query, no calculation")
        expect(CalcToolSchema.query(from: #"{"query": ""}"#) == nil, "an empty query is refused")
        expect(CalcToolSchema.query(from: "not json at all") == nil, "arguments are JSON text")
    }

    static func evaluate(_ argumentText: String) -> AIToolResult {
        CalcToolExecutor.invoke(
            AIToolCall(id: "c1", name: "calculator", arguments: argumentText),
            rates: nil, region: nil, now: now, calendar: calendar)
    }

    static func evaluateArithmetic() {
        expect(evaluate(#"{"query":"12 * 7.5"}"#).content == "90", "arithmetic arrives canonical")
        expect(!evaluate(#"{"query":"12 * 7.5"}"#).isError, "an answer is not an error")
        expect(
            evaluate(#"{"query":"log(256, 2)"}"#).content == "8", "functions answer too")
    }

    static func evaluateUnitConversions() {
        expect(evaluate(#"{"query":"1 GB to MB"}"#).content == "1000 MB", "units convert")
        expect(evaluate(#"{"query":"90min to hr"}"#).content == "1.5 hr", "timespans convert")
    }

    static func evaluateCurrencyWithRates() {
        let rates = CurrencyRates(
            base: "USD", rates: ["EUR": 0.85, "JPY": 150], fetchedAt: now)
        let exchange = CalcToolExecutor.invoke(
            AIToolCall(id: "c1", name: "calculator", arguments: #"{"query":"100 usd to eur"}"#),
            rates: rates, region: nil, now: now, calendar: calendar)
        expect(exchange.content == "85.00 EUR", "a rate table prices a conversion")
        expect(
            CalcToolExecutor.invoke(
                AIToolCall(id: "c1", name: "calculator", arguments: #"{"query":"100 usd to eur"}"#),
                rates: nil, region: nil, now: now, calendar: calendar)
            .isError,
            "no rate table, no price — an explanation, never a wrong number")
    }

    static func aConversionFailureIsReadable() {
        let answer = evaluate(#"{"query":"1 GB to hr"}"#)
        expect(answer.isError, "an impossible conversion is an error")
        expect(
            answer.content.contains("Cannot convert"),
            "the engine's own explanation travels with the failure")
    }

    static func notCalculatorInputIsReadable() {
        let answer = evaluate(#"{"query":"safari"}"#)
        expect(answer.isError, "not-input is refused, never answered")
        expect(
            answer.content.contains("not calculator input"),
            "the refusal tells the model why")
    }
}
