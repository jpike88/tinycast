import Foundation

@main
@MainActor
struct AIWebSearchTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        toolCatalogIsOffered()
        argumentsYieldOneQuery()
        endpointNamesOneQueryPerPage()
        resultsBecomeReadableText()
        endpointErrorsSayWhatHappened()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func toolCatalogIsOffered() {
        let tool = AIWebSearch.tool()
        expect(tool.name == "web_search", "the built-in tool is named web_search")
        expect(tool.origin == "Tinycast", "the transcript row says the call came from Tinycast")
        expect(tool.title == "Web search", "the tool carries a human title")
        expect(!tool.description.isEmpty, "the model is told when to call it")
        let schema = tool.parameters.objectValue
        expect(schema?["type"]?.stringValue == "object", "the schema is an object")
        expect(
            schema?["required"]?.arrayValue?.first?.stringValue == "query",
            "the query is the one required field")
        // Re-encoding must survive the trip through JSONSerialization, whatever a provider does.
        expect(
            JSONSerialization.isValidJSONObject(tool.parameters.jsonObject),
            "the schema re-encodes as a valid JSON body")
        expect(AIWebSearch.isBuiltIn("web_search"), "a call by that name is built-in")
        expect(!AIWebSearch.isBuiltIn("mcp__a__b"), "an MCP tool never routes to the built-in one")
    }

    static func argumentsYieldOneQuery() {
        expect(
            AIWebSearch.query(from: #"{"query": "swift 6 diseases"}"#) == "swift 6 diseases",
            "the query is read from arguments")
        expect(
            AIWebSearch.query(from: #"{"query":"  padded  "}"#) == "padded",
            "a padded query is trimmed")
        expect(AIWebSearch.query(from: #"{"q": "swift"}"#) == nil, "no query, no search")
        expect(AIWebSearch.query(from: #"{"query": ""}"#) == nil, "an empty query never searches")
        expect(AIWebSearch.query(from: #"{"query": 12}"#) == nil, "a query is a string")
        expect(AIWebSearch.query(from: "not json at all") == nil, "arguments are JSON text")
        expect(AIWebSearch.query(from: #"{"query":"   "}"#) == nil, "blank is no query")
    }

    static func endpointNamesOneQueryPerPage() {
        expect(
            AIWebSearch.endpoint("hello world")?.absoluteString
                == "https://api.search.brave.com/res/v1/web/search?q=hello%20world&count=8",
            "the endpoint carries the query and a page of results")
        expect(
            AIWebSearch.endpoint("")?.absoluteString.contains("q=&") == true,
            "the executor has already refused the empty query; empty travels as empty")
    }

    static func resultsBecomeReadableText() {
        let response = """
            {"type": "search", "query": {"original": "swift"}, "web": {"results": [
                {"title": "First result", "url": "https://a.example",
                 "description": "A <strong>bold</strong> snippet survives its markup"},
                {"title": "Second result", "url": "https://b.example"},
                {"url": "https://titleless.example"},
                {"title": "No link"},
                {"not a result": 1}],
              "other keys are ignored": true}}
            """
        let text = AIWebSearch.summarize(Data(response.utf8))
        expect(text != nil, "a response with results reads as text")
        expect(
            text?.contains("1. First result") == true && text?.contains("https://a.example") == true,
            "each result is numbered with its title and link")
        expect(
            text?.contains("A bold snippet survives its markup") == true,
            "emphasis markup is stripped from snippets")
        expect(
            text?.contains("2. Second result") == true,
            "a snippet-less result is still a title and a link")
        expect(AIWebSearch.summarize(Data(#"{"web": {"results": []}}"#.utf8)) == nil,
            "no results, no text")
        expect(AIWebSearch.summarize(Data("nope".utf8)) == nil, "undecodable bytes are no results")
        expect(AIWebSearch.summarize(Data(#"{}"#.utf8)) == nil, "an empty body is no results")
    }

    static func endpointErrorsSayWhatHappened() {
        let explained = #"{"error": {"detail": "Web search failed: invalid key."}}"#
        expect(
            AIWebSearch.errorMessage(from: Data(explained.utf8), status: 403)
                == "Web search failed: invalid key.",
            "the endpoint's own detail travels with the failure")
        let fielded = #"{"error": {"detail": [{"msg": "q is required."}]}}"#
        expect(
            AIWebSearch.errorMessage(from: Data(fielded.utf8), status: 422) == "q is required.",
            "the one culprit field's message travels with the failure")
        let unexplained = #"{"other": 1}"#
        expect(
            AIWebSearch.errorMessage(from: Data(unexplained.utf8), status: 429)
                == "The search endpoint is rate limited — try again in a second.",
            "a bodyless failure still says something the model can relay")
    }
}
