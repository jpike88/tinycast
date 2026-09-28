import Foundation

/// The built-in `calculator` tool: the same `CalcEngine` the palette's inline card answers with,
/// so the model gets arithmetic, units, currency, crypto, time zones and time spans instead of
/// doing arithmetic itself. Pure: the schema and the argument read are here; the engine and its
/// `CalcResult` live in the calculator feature, which the executor formats back.
enum CalcToolSchema {
    static let name = "calculator"
    /// What the transcript row says the call came from, distinct from any MCP server's title.
    static let origin = "Calculator"
    static let title = "Calculate"

    private static let description =
        "Evaluate arithmetic, unit conversions, currency and crypto conversions, time-zone "
        + "conversions and time spans with Tinycast's own calculator engine. If the result is "
        + "nil, the query was not something a calculator can answer — restate it as arithmetic, "
        + "units or an explicit conversion and try once more."

    static func isBuiltIn(_ toolName: String) -> Bool { toolName == name }

    static func tool() -> AITool {
        AITool(
            name: name, description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The expression as it would be typed into the launcher's calculator: "
                                + "12 * 7.5, 2 GB to MB, 100 usd to eur, 5pm SF to Tokyo."),
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]), origin: origin, title: title)
    }

    /// The call's arguments are raw JSON text only the executor parses, so only she rejects it.
    static func query(from argumentText: String) -> String? {
        guard var query = JSONValue(data: Data(argumentText.utf8))?
            .objectValue?["query"]?.stringValue
        else { return nil }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }
}
