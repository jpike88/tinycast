import Foundation

/// The one place chat reaches a web page: a bounded, cacheless GET off-main, per invocation.
/// The session keeps nothing — no cache, no cookies, no credentials — so a page the model asks
/// for leaves no copy of itself, or of the asking, on disk.
struct ReadPageService: Sendable {
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = ReadPageTool.timeoutSeconds
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// An invoked call becomes a result even when nothing went out: a failure is content the
    /// model can read and route around, never a thrown error that would end the turn.
    static func invoke(_ call: AIToolCall) async -> AIToolResult {
        switch ReadPageTool.target(from: call.arguments) {
        case .failure(let refusal):
            return .failure(call.id, refusal.message)
        case .success(let url):
            return await fetch(url, callID: call.id)
        }
    }

    /// The whole life of one page fetch, pinned by the schema's bounds: the URL the model
    /// asked for is what the bytes are read as, whatever a redirect changed along the way.
    static func fetch(_ url: URL, callID: String) async -> AIToolResult {
        guard ReadPageTool.fetchable(url) else {
            return .failure(callID, "Only public http or https pages can be read.")
        }
        var request = URLRequest(url: url, timeoutInterval: ReadPageTool.timeoutSeconds)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (stream, response) = try? await session.bytes(for: request) else {
            return .failure(callID, await interruption() ?? "The page could not be reached.")
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode
            return .failure(callID, "The page answered HTTP \(status.map(String.init) ?? "call") with no readable body.")
        }
        guard ReadPageTool.fetchable(response.url ?? url) else {
            return .failure(
                callID, "The page answered by leaving the web, so there is nothing to read.")
        }
        var bytes = Data()
        var truncated = false
        do {
            var iterator = stream.makeAsyncIterator()
            // One byte past the cap tells a page that just fits from one that was cut.
            while bytes.count <= ReadPageTool.maxPageBytes, let next = try await iterator.next() {
                bytes.append(next)
            }
            truncated = bytes.count > ReadPageTool.maxPageBytes
            if truncated { bytes = Data(bytes.prefix(ReadPageTool.maxPageBytes)) }
        } catch {
            if bytes.isEmpty {
                return .failure(callID, await interruption() ?? "The page began but did not finish.")
            }
            truncated = true
        }
        guard
            let page = ReadPageTool.readable(
                bytes: bytes, mimeType: http.mimeType, textEncoding: http.textEncodingName,
                base: response.url ?? url, truncated: truncated)
        else {
            return .failure(
                callID,
                "The page is \(http.mimeType ?? "an unnamed format"), not a text format — "
                    + "there is nothing this tool can read.")
        }
        return AIToolResult(callID: callID, content: page, isError: false)
    }

    /// What a stop or a network break says, in the one phrasing a result may carry: a cancelled
    /// turn reads as its own line, and any other throw as the network's.
    private static func interruption() async -> String? {
        do {
            try Task.checkCancellation()
            return nil
        } catch {
            return "The page fetch was stopped."
        }
    }

    /// Who is asking, so a server can tell this tool apart from a browser — version named,
    /// no browser claimed by name.
    private static var agent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        return "Tinycast/\(version) (macOS; read_page)"
    }
}
