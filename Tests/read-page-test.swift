import Foundation

@main
@MainActor
struct ReadPageTests {
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
        urlReadingRefusesWhatIsNotAPublicPage()
        urlsTheCallCannotNameAreRefusedAsContent()
        aPageBecomesTextAThinkingModelReads()
        boilerplateVanishes()
        oneMainRegionCarriesThePage()
        tablesListsAndFencesSurvive()
        plainTextAndJsonRideAsTheyCame()
        binaryMediaIsRefused()
        aCutPageSaysSo()
        resultsAreBounded()
        aRowShowsItsURL()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func toolCatalogIsOffered() {
        let tool = ReadPageTool.tool()
        expect(tool.name == "read_page", "the built-in tool is named read_page")
        expect(tool.origin == "Tinycast", "the transcript row says the call came from Tinycast")
        expect(tool.title == "Read page", "the tool carries a human title")
        expect(!tool.description.isEmpty, "the model is told when to call it")
        let schema = tool.parameters.objectValue
        expect(schema?["type"]?.stringValue == "object", "the schema is an object")
        expect(
            schema?["required"]?.arrayValue?.first?.stringValue == "url",
            "the URL is the one required field")
        // Re-encoding must survive the trip through JSONSerialization, whatever a provider does.
        expect(
            JSONSerialization.isValidJSONObject(tool.parameters.jsonObject),
            "the schema re-encodes as a valid JSON body")
        expect(ReadPageTool.isBuiltIn("read_page"), "a call by that name is built-in")
        expect(!ReadPageTool.isBuiltIn("mcp__a__b"), "an MCP tool never routes to the built-in")
        expect(!ReadPageTool.isBuiltIn("web_lookup"), "another built-in keeps its own name")
    }

    static func urlReadingRefusesWhatIsNotAPublicPage() {
        func fetched(_ text: String) -> Bool {
            guard let url = URL(string: text) else { return false }
            return ReadPageTool.fetchable(url)
        }
        expect(fetched("https://example.com/page"), "https pages fetch")
        expect(fetched("http://example.com/"), "http pages fetch, the one plain scheme allowed")
        expect(fetched("https://Example.COM"), "host case never decides what is public")
        expect(fetched("https://example.com:8443/a"), "an odd port is still the public web")
        expect(!fetched("/etc/passwd"), "a path is not a URL this tool fetches")
        expect(!fetched("file:///etc/passwd"), "local files never fetch")
        expect(!fetched("ftp://example.com/pub"), "ftp is not one of the schemes that fetch")
        expect(!fetched("https://user:pass@example.com/"), "addresses carrying credentials never fetch")
        for local in [
            "http://localhost/a", "http://localhost:8080/", "http://127.0.0.1/",
            "http://127.1.2.3/", "http://10.0.0.9/", "http://192.168.1.4/",
            "http://172.16.0.9/", "http://172.31.4.4/", "http://169.254.169.254/latest/meta-data",
            "http://0.0.0.0/", "http://mymac.local/", "http://metadata.internal.local/",
        ] {
            expect(!fetched(local), "the local and private addresses are refused: \(local)")
        }
        expect(fetched("http://172.32.0.1/"), "the private range's neighbour is public")
        expect(fetched("http://8.8.8.8/"), "a public v4 host fetches")
        expect(!fetched("http://[::1]/"), "the v6 loopback is refused")
        expect(!fetched("http://[fe80::1]/"), "the v6 link-local range is refused")
        expect(!fetched("http://[fc00::1]/"), "the v6 unique-local range is refused")
        expect(fetched("http://[2606:4700::1111]/"), "a public v6 host fetches")
    }

    static func urlsTheCallCannotNameAreRefusedAsContent() {
        func refused(_ arguments: String) -> String? {
            switch ReadPageTool.target(from: arguments) {
            case .failure(let refusal): return refusal.message
            case .success: return nil
            }
        }
        expect(
            refused(#"{"url": "https://example.com/page"}"#) == nil,
            "an absolute https URL reads")
        switch ReadPageTool.target(from: #"{"url": " https://example.com/page "}"#) {
        case .failure: expect(false, "a URL with padding still reads")
        case .success(let url): expect(url.absoluteString.contains("/page"), "padding is trimmed")
        }
        expect(
            refused(#"{"query": "who is prime"}"#)?.contains("No URL to read") == true,
            "arguments without a URL are refused as content, not swallowed")
        expect(
            refused(#"{"url": ""}"#)?.contains("No URL to read") == true,
            "an empty URL is refused as content")
        expect(
            refused(#"{"url": "https://secret-hub.local/admin"}"#)?.contains("Only public") == true,
            "a private host is refused as content")
        expect(refused("not json at all") != nil, "arguments that are no JSON are refused as content")
        expect(
            refused(#"{"url": "not a url at all"}"#) != nil,
            "text that parses as no URL is refused as content")
    }

    static func aPageBecomesTextAThinkingModelReads() {
        let page = ReadPageTool.readable(
            bytes: Data("""
                <html><head><title>How a page reads</title></head>
                <body>
                  <h1>Greeting</h1>
                  <p>Hello <strong>world</strong>. This is &ldquo;nice&rdquo; &mdash; really.</p>
                  <p>Learn more at <a href="/guide">the guide</a> or&nbsp;<a
                    href="https://other.example/deep">elsewhere</a>.</p>
                </body></html>
                """.utf8),
            mimeType: "text/html; charset=utf-8", textEncoding: "utf-8",
            base: URL(string: "https://example.com/docs")!, truncated: false)
        expect(page != nil, "an html page reads as text")
        expect(page?.contains("# How a page reads") == true, "the title leads")
        expect(
            page?.contains("# Greeting") == true, "a heading stays a heading at its own level")
        expect(
            page?.contains("Hello world. This is “nice” — really.") == true,
            "entities decode and emphasis flattens")
        expect(
            page?.contains("[the guide](https://example.com/guide)") == true,
            "a relative link resolves against the page")
        expect(
            page?.contains("[elsewhere](https://other.example/deep)") == true,
            "an absolute link rides as it is")
        expect(
            page?.contains("at [the guide](https://example.com/guide)") == true,
            "the first link keeps its text and resolves its destination")
        expect(
            page?.contains("or [elsewhere](https://other.example/deep)") == true,
            "the words between two links never merge into the spans")
    }

    static func boilerplateVanishes() {
        let page = ReadPageTool.readable(
            bytes: Data("""
                <html><head><title>Signed</title>
                <style>body { margin: 0 } .ad { color: red }</style>
                <script>var tracking = "all of it";</script></head>
                <body>
                <nav><a href="/nowhere">Home</a><a href="/nowhere2">Pricing</a></nav>
                <main><p>The only paragraph worth reading.</p></main>
                <footer><p>© Example — all rights, no reading.</p></footer>
                </body></html>
                """.utf8),
            mimeType: "text/html", textEncoding: nil,
            base: URL(string: "https://example.com")!, truncated: false)
        expect(page?.contains("The only paragraph worth reading.") == true, "the prose reads")
        expect(page?.contains("tracking") == false, "scripts leave nothing behind")
        expect(page?.contains("margin") == false, "styles leave nothing behind")
        expect(page?.contains("Pricing") == false, "navigation links are not prose")
        expect(page?.contains("all rights") == false, "a footer is not prose either")
    }

    static func oneMainRegionCarriesThePage() {
        let page = ReadPageTool.readable(
            bytes: Data("""
                <html><head><title>Scoped</title></head><body>
                <header>Chase the wind-up.</header>
                <main><article><p>Inside the main frame.</p></article></main>
                <article><p>A stray article outside must not duplicate the region.</p></article>
                </body></html>
                """.utf8),
            mimeType: "text/html", textEncoding: nil,
            base: URL(string: "https://example.com")!, truncated: false)
        expect(page?.contains("Inside the main frame.") == true, "the main region reads")
        expect(
            page?.contains("A stray article outside") == false,
            "outside the main region is not part of the page")
        expect(page?.contains("Chase the wind-up.") == false, "the header is chrome")
    }

    static func tablesListsAndFencesSurvive() {
        let page = ReadPageTool.readable(
            bytes: Data("""
                <html><head><title>Shapes</title></head><body>
                <ol><li>First</li><li>Second</li></ol>
                <ul><li>Bulleted</li><li>Again with <a href="/x">a link</a></li></ul>
                <table><tr><th>Name</th><th>Role</th></tr>
                <tr><td>Ada</td><td>Engineer</td></tr></table>
                <pre><code>$ run --fast true</code></pre>
                <p>Inline <code>--fast</code> flag mention.</p>
                </body></html>
                """.utf8),
            mimeType: "text/html", textEncoding: nil,
            base: URL(string: "https://example.com")!, truncated: false)
        expect(page?.contains("1. First") == true && page?.contains("2. Second") == true,
            "an ordered list numbers itself")
        expect(page?.contains("- Bulleted") == true, "a list bullet stays a bullet")
        expect(page?.contains("- Again with [a link](https://example.com/x)") == true,
            "a link inside a list item keeps its destination")
        expect(page?.contains("Name | Role") == true, "a header row reads as columns")
        expect(page?.contains("Ada | Engineer") == true, "a data row reads as columns")
        expect(page?.contains("```") == true && page?.contains("$ run --fast true") == true,
            "a fenced block keeps its command whole")
        expect(page?.contains("`--fast`") == true, "inline code is fenced short")
    }

    static func plainTextAndJsonRideAsTheyCame() {
        let notes = ReadPageTool.readable(
            bytes: Data("Release 9 notes.\n\nA calm\nplain  paragraph.".utf8),
            mimeType: "text/plain", textEncoding: nil,
            base: URL(string: "https://example.com/notes.txt")!, truncated: false)
        expect(
            notes?.contains("Release 9 notes.") == true && notes?.contains("A calm") == true,
            "plain text rides as it came")
        let feed = ReadPageTool.readable(
            bytes: Data(#"{"answer": 42, "question": "unknown"}"#.utf8),
            mimeType: "application/json", textEncoding: nil,
            base: URL(string: "https://api.example.com/a")!, truncated: false)
        expect(
            feed?.contains(#""answer": 42"#) == true,
            "json rides with its keys and values intact")
        let feedHtmlShaped = ReadPageTool.readable(
            bytes: Data("<html><body>{\"answer\": 42}</body></html>".utf8),
            mimeType: "application/json", textEncoding: nil,
            base: URL(string: "https://api.example.com/b")!, truncated: false)
        expect(
            feedHtmlShaped?.contains(#""answer": 42"#) == true,
            "a json body served with markup inside still reads whole")
    }

    static func binaryMediaIsRefused() {
        expect(
            ReadPageTool.readable(
                bytes: Data([0x25, 0x50, 0x44, 0x46]), mimeType: "application/pdf",
                textEncoding: nil, base: URL(string: "https://example.com/x.pdf")!,
                truncated: false) == nil,
            "a pdf is not text this tool reads")
        expect(
            ReadPageTool.readable(
                bytes: Data([0xFF, 0xD8]), mimeType: "image/jpeg", textEncoding: nil,
                base: URL(string: "https://example.com/x.jpg")!, truncated: false) == nil,
            "an image is not text this tool reads")
        expect(
            ReadPageTool.readable(
                bytes: Data(), mimeType: "video/mp4", textEncoding: nil,
                base: URL(string: "https://example.com/x.mp4")!, truncated: false) == nil,
            "a video is not text this tool reads")
    }

    static func aCutPageSaysSo() {
        let page = ReadPageTool.readable(
            bytes: Data("<html><body><p>Short.</p></body></html>".utf8),
            mimeType: "text/html", textEncoding: nil,
            base: URL(string: "https://example.com")!, truncated: true)
        expect(page?.contains("Short.") == true, "a cut page still carries what it held")
        expect(
            page?.contains("was cut at") == true && page?.contains("the rest was not read") == true,
            "the cut is a note the model reads, never silence")
        expect(
            ReadPageTool.readable(
                bytes: Data("<p>   </p>".utf8), mimeType: "text/html", textEncoding: nil,
                base: URL(string: "https://example.com")!, truncated: false) == nil,
            "a page holding only whitespace reads as nothing")
    }

    static func resultsAreBounded() {
        let repeated = String(repeating: "<p>" + String(repeating: "word ", count: 12) + "</p>", count: 400)
        let page = ReadPageTool.readable(
            bytes: Data(("<html><body>" + repeated + "</body></html>").utf8),
            mimeType: "text/html", textEncoding: nil,
            base: URL(string: "https://example.com")!, truncated: false)
        expect(page != nil, "a long page still renders")
        expect((page?.count ?? 0) > 10_000, "the long page's text carries its own weight")
    }

    static func aRowShowsItsURL() {
        expect(
            ReadPageTool.detail(in: #"{"url": "https://example.com/a"}"#)
                == "https://example.com/a",
            "the row's detail reads the URL out of the arguments")
        expect(
            ReadPageTool.detail(in: #"{"query": "x"}"#) == nil,
            "arguments without a URL leave the detail empty")
        expect(ReadPageTool.detail(in: "hi") == nil, "garbage arguments leave the detail empty")
    }
}
