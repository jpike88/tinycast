import Foundation

/// The built-in `web_search` tool: one query to Brave Search, whose results the model reads.
/// Pure: the endpoint, the request and the text the model sees are pinned by `ai-web-search-test`.
enum AIWebSearch {
    static let name = "web_search"
    /// What the transcript row says the call came from, distinct from any MCP server's title.
    static let origin = "Tinycast"
    static let title = "Web search"
    /// A fixed account in `KeychainSecretStore.aiAPIKeys`, because there is nothing for it to name.
    static let keyAccount = UUID(uuidString: "1E0440CB-B33F-4E9F-A1E6-1DDB7ADE70C7")!
    static let resultCount = 8
    private static let host = "api.search.brave.com"
    static let keyHeaderName = "X-Subscription-Token"

    private static let description =
        "Search the open web for facts, news, prices or links the conversation cannot know. "
        + "Returns result titles, page links and text snippets."

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
                            "The query as you would type it into a search engine."),
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

    static func endpoint(_ query: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/res/v1/web/search"
        parts.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(resultCount)),
        ]
        guard let url = parts.url, url.host == host, url.scheme == "https" else { return nil }
        return url
    }

    /// The model's results as numbered, readable text; `nil` says the reply carried nothing to read.
    static func summarize(_ data: Data) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let entries = results(in: response).enumerated().compactMap { index in
            let (index, entry) = index
            return described(index: index + 1, entry: entry)
        }
        return entries.isEmpty ? nil : entries.joined(separator: "\n\n")
    }

    /// Web results are the answer; news fills the page when the web section finds nothing.
    private static func results(in response: [String: Any]) -> [[String: Any]] {
        if let web = response["web"] as? [String: Any],
            let webResults = web["results"] as? [[String: Any]], !webResults.isEmpty
        {
            return webResults
        }
        let news = response["news"] as? [String: Any]
        return (news?["results"] as? [[String: Any]]) ?? []
    }

    private static func described(index: Int, entry: [String: Any]) -> String? {
        guard
            let url = entry["url"] as? String, !url.isEmpty,
            let title = entry["title"] as? String
        else { return nil }
        var lines: [String] = ["\(index). \(title)", "   \(url)"]
        if let description = string(in: entry["description"]), !description.isEmpty {
            lines.append("   \(description)")
        }
        return lines.joined(separator: "\n")
    }

    /// A failure is content the model can read, so the endpoint's own message travels with it.
    static func errorMessage(from data: Data, status: Int) -> String {
        guard
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let detail = (error["error"] as? [String: Any])?["detail"]
        else { return fallbackMessage(status) }
        let text: [String]
        switch detail {
        case let detail as String: text = [detail]
        case let details as [[String: Any]]:
            text = details.compactMap { string(in: $0["msg"] ?? $0["message"]) }
        default: text = []
        }
        return text.first { !$0.isEmpty } ?? fallbackMessage(status)
    }

    /// A failure that carries no message still says something the model can relay.
    private static func fallbackMessage(_ status: Int) -> String {
        switch status {
        case 401, 403:
            return "The search API key is rejected — check it in Settings."
        case 429:
            return "The search endpoint is rate limited — try again in a second."
        case 422:
            return "The search endpoint refused the query — try phrasing it differently."
        default:
            return "Brave Search answered HTTP \(status)."
        }
    }

    /// Snippets arrive with emphasis markup ("<strong>"); the tags are noise to the model.
    private static func string(in value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let stripped = text.replacingOccurrences(of: "<strong>", with: "")
            .replacingOccurrences(of: "</strong>", with: "")
        return stripped
    }
}
