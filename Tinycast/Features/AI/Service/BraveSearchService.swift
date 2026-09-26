import Foundation

/// The one place chat reaches Brave Search: a cacheless GET off-main, per invocation.
/// Same session discipline as `HTTPAIProvider`, so Brave keeps no copy on disk but its response.
struct BraveSearchService: Sendable {
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// An invoked call becomes a result even when nothing went out: a failure is content the model
    /// can read and route around, never a thrown error that would end the turn.
    static func invoke(_ call: AIToolCall) async -> AIToolResult {
        guard let query = AIWebSearch.query(from: call.arguments) else {
            return .failure(call.id, "The tool call carried no query to search with.")
        }
        guard let url = AIWebSearch.endpoint(query) else {
            return .failure(call.id, "The search request could not be encoded.")
        }
        let key = (try? KeychainSecretStore.aiAPIKeys.secret(for: AIWebSearch.keyAccount)) ?? ""
        return await search(url, apiKey: key, callID: call.id)
    }

    private static func search(_ url: URL, apiKey: String, callID: String) async -> AIToolResult {
        guard !apiKey.isEmpty else {
            return .failure(callID, "No search API key is stored — add one in Settings → AI.")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: AIWebSearch.keyHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse
        else {
            return .failure(callID, "Brave Search could not be reached — check the network.")
        }
        guard 200..<300 ~= http.statusCode else {
            return .failure(callID, AIWebSearch.errorMessage(from: data, status: http.statusCode))
        }
        guard let text = AIWebSearch.summarize(data) else {
            return AIToolResult(callID: callID, content: "No results for that query.", isError: false)
        }
        return AIToolResult(callID: callID, content: text, isError: false)
    }
}
