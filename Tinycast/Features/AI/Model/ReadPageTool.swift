import Foundation

/// The built-in `read_page` tool: one http or https URL, fetched and reduced to the text a
/// model reads — the title, headings, paragraphs, lists, tables, fences and link destinations
/// survive; scripts, styles, widgetry and repeating navigation do not. Pure Model: the schema,
/// the URL read and the conversion are pinned by `read-page-test`; the fetch is the one
/// `ReadPageService` invocation.
enum ReadPageTool {
    static let name = "read_page"
    /// The pseudo-slug the per-chat tools menu switches it off with.
    static let slug = "read_page"
    static let origin = "Tinycast"
    static let title = "Read page"
    /// One fetch stops at this many bytes of a page; the text says when it did.
    static let maxPageBytes = 1_048_576
    static let timeoutSeconds: TimeInterval = 30

    private static let description =
        "Fetch one web page and read it as clean text: the page title, headings, paragraphs, "
        + "lists, tables, code blocks and where links point, with scripts, styles, forms and "
        + "repeating navigation stripped out. Prefer this over fetching through bash — the output "
        + "is already reduced to what is readable, and one call is one page. A PDF, an image or "
        + "any other non-text format is refused, and a page past the size cap is returned cut, "
        + "with a note saying so."

    static func isBuiltIn(_ toolName: String) -> Bool { toolName == name }

    static func tool() -> AITool {
        AITool(
            name: name, description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object([
                        "type": .string("string"),
                        "description": .string("The absolute page URL, scheme included."),
                    ])
                ]),
                "required": .array([.string("url")]),
                "additionalProperties": .bool(false),
            ]), origin: origin, title: title)
    }

    /// A refusal is content the model reads and routes around, never a thrown stack trace.
    struct Refusal: Error, CustomStringConvertible {
        let message: String

        var description: String { message }
    }
}

// MARK: - The URL the call names

extension ReadPageTool {
    /// The call's arguments are raw JSON text only the executor parses, so only she rejects it.
    static func target(from arguments: String) -> Result<URL, Refusal> {
        let given = JSONValue(data: Data(arguments.utf8))?
            .objectValue?["url"]?.stringValue?
            .trimmingCharacters(in: .whitespaces)
        guard let given, !given.isEmpty else {
            let named = JSONValue(data: Data(arguments.utf8))?.objectValue
            let keys = named.map { object in
                object.isEmpty
                    ? "an empty arguments object"
                    : "arguments with keys " + object.keys.sorted()
                        .map { "“\($0)”" }.joined(separator: ", ")
            } ?? "arguments that parsed as no object at all"
            return .failure(Refusal(message: "No URL to read was given — \(keys)."))
        }
        guard let url = URL(string: given) else {
            return .failure(Refusal(message: "“\(given)” is not a URL the fetch can name."))
        }
        guard fetchable(url) else {
            return .failure(
                Refusal(message: "Only public http or https pages can be read; “\(given)” names "
                    + "something else."))
        }
        return .success(url)
    }

    /// Whether this URL is one the built-in will fetch at all: http(s), a public host, no
    /// credentials in the address. Local and private addresses are refused, so a call the model
    /// makes cannot point at this Mac or at anything beside it on the network — the one shape
    /// this cannot see is a public name resolving into a private range, which is the same gap
    /// bash curl's consent dialog covers.
    static func fetchable(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty,
            url.user == nil, url.password == nil
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }
        if host.hasPrefix("[") || host.contains(":") {
            // An IPv6 literal, with or without the brackets Foundation's host keeps or drops.
            let literal = host.hasPrefix("[")
                ? String(host.dropFirst().dropLast()) : host
            return !isPrivateIPv6(literal)
        }
        return !isPrivateIPv4(host)
    }

    /// `::`, `::1`, the mapped-v4 loopback, link-local `fe80::/10` and unique-local `fc00::/7`.
    private static func isPrivateIPv6(_ literal: String) -> Bool {
        let host = literal.lowercased()
        if host == "::" || host == "::1" { return true }
        if host.hasPrefix("::ffff:") { return isPrivateIPv4(String(host.dropFirst("::ffff:".count))) }
        return ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains { host.hasPrefix($0) }
    }

    /// The loopback, private, link-local and unspecified v4 ranges, matched by octet.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: true)
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4, parts.count == 4 else { return false }
        let (first, second, _, _) = (bytes[0], bytes[1], bytes[2], bytes[3])
        if first == 0 || first == 10 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        return first == 192 && second == 168
    }

    /// The row's code block shows the URL the page would be read from; a malformed call still
    /// gets a row, so this reads the one key instead of running the parse.
    static func detail(in arguments: String) -> String? {
        guard
            let url = JSONValue(data: Data(arguments.utf8))?.objectValue?["url"]?.stringValue,
            !url.isEmpty
        else { return nil }
        return url
    }
}

// MARK: - The readable page

extension ReadPageTool {
    /// What the fetch handed over becomes the text the model reads. `nil` says the bytes are
    /// not a text format at all, so there is nothing this tool can read.
    static func readable(
        bytes: Data, mimeType: String?, textEncoding: String?, base: URL, truncated: Bool
    ) -> String? {
        let media = (mimeType ?? "").lowercased()
        guard !media.startsBinary else { return nil }
        let document = decoded(bytes, encoding: textEncoding)
        var page: String
        if media.contains("json") {
            page = document
        } else if media.contains("html") || media.contains("xml") || media.contains("svg") {
            let (title, content) = extract(from: document, base: base)
            page = content
            if let title, !content.hasHeading(exact: title) {
                page = "# " + title + "\n\n" + page
            }
        } else {
            page = document
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if truncated { page = page + "\n\n[" + truncationNote + "]" }
        return page.isBlank ? nil : page
    }

    /// The cut note the model reads; MiB-scaled, so no locale's units rename it underneath.
    static let truncationNote: String = {
        let mebibytes = Double(maxPageBytes) / 1_048_576
        let named = mebibytes == mebibytes.rounded() ? String(Int(mebibytes)) : "\(mebibytes)"
        return "The page was cut at \(named) MiB mid-document; the rest was not read."
    }()

    /// The charsets a server names most; anything else falls back to UTF-8 lossy, the whole
    /// web's lingua franca rather than a nil String.
    private static func decoded(_ bytes: Data, encoding: String?) -> String {
        let name = encoding?.trimmingCharacters(in: .whitespaces).lowercased()
        let encoding: String.Encoding? = switch name {
        case "utf-8", "utf8", "unicode", "": .utf8
        case "iso-8859-1", "latin1", "latin-1", "cp819", "iso8859-1": .isoLatin1
        case "windows-1252", "cp1252", "windows1252": .windowsCP1252
        case "utf-16", "utf16": .utf16
        case "shift-jis", "shift_jis", "shiftjis": .shiftJIS
        default: nil
        }
        guard let encoding else { return String(decoding: bytes, as: UTF8.self) }
        return String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// Wire formats whose bytes are never prose. Everything else — text, JSON, XML, anything
/// unnamed — is read as text, because a URL a model names is worth a try even unlabelled.
private extension String {
    var startsBinary: Bool {
        ["image/", "audio/", "video/", "font/", "application/pdf", "application/zip",
         "application/octet-stream", "application/gzip", "application/x-gzip",
         "application/x-tar", "application/tar", "application/rar",
         "application/x-7z-compressed", "application/binary", "application/x-msdownload",
         "application/wasm", "application/x-shockwave-flash",
         "application/vnd.apple.installer+xml"].contains { hasPrefix($0) }
    }
}

/// Tiny string judgements the conversion makes over and over, named once.
private extension String {
    /// Whitespace runs to one space and the ends come off — a text node's inline reading.
    var flattened: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private extension String {
    /// Whether the text's first heading block is this very title, so the page title and the
    /// body's own `# Title` never print twice.
    func hasHeading(exact title: String) -> Bool {
        let first = split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard var first else { return false }
        if first.hasPrefix("#") {
            first = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        }
        return first.flattened.lowercased() == title.flattened.lowercased()
    }
}

// MARK: - The conversion

extension ReadPageTool {
    /// The document, read: the title the head names, and the body as markdown-shaped text.
    /// The body is empty when the page held nothing readable.
    static func extract(from document: String, base: URL) -> (title: String?, body: String) {
        let title = rawTitle(in: document)
        let linkBase = baseHref(in: document) ?? base
        let cleaned = droppingInvisible(document)
        let scoped = scope(in: cleaned)
        var body = Body(base: linkBase).render(tokens(of: scoped ?? cleaned, hidingNavigation: true))
        if body.isBlank {
            // The hiding pass left nothing: the page keeps its chrome and the chrome is it.
            body = Body(base: linkBase).render(tokens(of: cleaned, hidingNavigation: false))
        }
        return (title, body)
    }
}

/// The hand-rolled scan. This project carries no HTML dependency, and the shape an AI reads
/// from a live page is decided here rather than by a parser upgrade.
private extension ReadPageTool {
    enum Token: Sendable {
        case text(String)
        case open(String, href: String?)
        case close(String)
    }

    /// Elements whose whole subtree is invisible to a reader, code and media alike.
    enum Invisible {
        static let names: Set<String> = [
            "script", "style", "head", "noscript", "template", "iframe", "svg", "canvas",
            "picture", "object", "embed", "audio", "video",
        ]
    }

    /// Elements the model's menu hides when it is on: chrome and controls, not raw bytes.
    enum Navigation {
        static let names: Set<String> = [
            "nav", "aside", "footer", "header", "form", "button", "select", "input",
            "textarea", "label", "dialog",
        ]
    }

    /// Elements that open without a close; their self-closing spell gets no extra close token.
    enum VoidElement {
        static let names: Set<String> = [
            "br", "hr", "img", "input", "meta", "link", "base", "col", "area", "source",
            "wbr", "param", "track",
        ]
    }
}

private extension ReadPageTool {
    /// The characters before the user's title element, plus everything inside it — read from
    /// the original document, because the clean pass removes the head that holds it.
    static func rawTitle(in document: String) -> String? {
        let chars = Array(document)
        guard let open = firstTag(chars, named: "title") else { return nil }
        var index = open.afterTag
        while index < chars.count, chars[index] != ">" { index += 1 }
        guard index < chars.count else { return nil }
        index += 1  // past ">", the title's own text begins here
        var probe = index
        while probe < chars.count {
            if tagNamed(chars, Array("</title"), at: probe) {
                return decodeEntities(String(chars[index..<probe])).flattened.takeIf({ !$0.isBlank })
            }
            probe += 1
        }
        return nil
    }

    /// `<base href>`: the page's own say on where relative links resolve, when it names one.
    static func baseHref(in document: String) -> URL? {
        let chars = Array(document)
        guard let open = firstTag(chars, named: "base") else { return nil }
        var index = open.afterTag
        while index < chars.count, chars[index] != ">" { index += 1 }
        guard index < chars.count else { return nil }
        guard let given = attribute("href", within: String(chars[open.start..<index])) else {
            return nil
        }
        let spelled = decodeEntities(given).trimmingCharacters(in: .whitespaces)
        return spelled.isEmpty ? nil : URL(string: spelled)
    }

    /// Everything a model would never read: comments, doctypes, and the subtrees of the
    /// elements whose content is code, media or metadata rather than prose.
    static func droppingInvisible(_ document: String) -> String {
        let chars = Array(document)
        var output = ""
        output.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            guard chars[index] == "<" else {
                let start = index
                while index < chars.count, chars[index] != "<" { index += 1 }
                output.append(contentsOf: chars[start..<index])
                continue
            }
            if matched(chars, Array("!--"), at: index) {
                index = find(chars, Array("-->"), after: index) ?? chars.count
                continue
            }
            if matched(chars, Array("![CDATA["), at: index) {
                index = find(chars, Array("]]>"), after: index) ?? chars.count
                continue
            }
            if chars.count > index + 1, chars[index + 1] == "!" || chars[index + 1] == "?" {
                index = find(chars, Array(">"), after: index) ?? chars.count
                continue
            }
            guard let end = tagEnd(chars, from: index) else {
                output.append(contentsOf: chars[index...])
                break
            }
            let isClosing = index + 1 < chars.count && chars[index + 1] == "/"
            let name = tagName(chars, from: index + (isClosing ? 2 : 1), until: end)
            let start = index
            index = end
            guard let name, !isClosing, Invisible.names.contains(name) else {
                output.append(contentsOf: chars[start..<end])
                continue
            }
            // A raw subtree leaves whole, with the close's trailing `>`; a close that never
            // comes swallows to the end, whose remainder was never prose anyway.
            index = matchingClose(name, in: chars, from: end) ?? chars.count
        }
        return String(output)
    }

    /// The region of the cleaned document that reads like the page: `<main>` when the page
    /// names one, a sole `<article>` spanning it when the page is one, else everything —
    /// several articles are a listing, and the furniture around them may be the point.
    static func scope(in cleaned: String) -> String? {
        if let main = balanced("main", in: cleaned) { return main }
        return balanced("article", in: cleaned)
    }

    /// The `<tag …>…</tag>` span whose opens and closes pair up, or nil when none does.
    /// HTML-level protection against unclosed trees: an unterminated span takes a whole pass
    /// only when the pair is there at all — otherwise `nil` means the document is as clean as
    /// the drop already left it, and no narrow scope finds a singleton either.
    static func balanced(_ tag: String, in document: String) -> String? {
        let chars = Array(document)
        let open = Array("<\(tag)")
        let close = Array("</\(tag)")
        var depth = 0
        var start: Int?
        var index = 0
        while index < chars.count {
            if tagNamed(chars, open, at: index) {
                if depth == 0 { start = index }
                depth += 1
                index += open.count
            } else if tagNamed(chars, close, at: index) {
                depth -= 1
                if depth == 0, let start {
                    var end = index + close.count
                    while end < chars.count, chars[end] != ">" { end += 1 }
                    return String(chars[start..<min(end + 1, chars.count)])
                }
                index += close.count
            } else {
                index += 1
            }
        }
        return nil
    }
}

private extension ReadPageTool {
    /// Whether the needle's characters match here, any casing, no tag rules attached — the
    /// matcher comments and CDATA closes use.
    static func matched(_ chars: [Character], _ needle: [Character], at index: Int) -> Bool {
        guard index + needle.count <= chars.count else { return false }
        for (offset, expected) in needle.enumerated()
        where String(chars[index + offset]).lowercased() != String(expected).lowercased() {
            return false
        }
        return true
    }

    /// The same match, and only when the name ends exactly here: the character past the
    /// needle is a tag-name boundary, so `<title` never matches inside `<titlecase …>`.
    static func tagNamed(_ chars: [Character], _ needle: [Character], at index: Int) -> Bool {
        guard matched(chars, needle, at: index) else { return false }
        let after = index + needle.count
        return after >= chars.count || chars[after] == ">" || chars[after] == "/"
            || chars[after].isWhitespace
    }

    /// The first `<name` tag open, with the character just past the name's end — `afterTag` —
    /// handed over, or nil when the document never opens one.
    static func firstTag(_ chars: [Character], named: String) -> (start: Int, afterTag: Int)? {
        let needle = Array("<\(named)")
        var index = 0
        while index < chars.count {
            if tagNamed(chars, needle, at: index) {
                let after = index + needle.count
                return (index, after)
            }
            index += 1
        }
        return nil
    }

    static func find(_ chars: [Character], _ needle: [Character], after start: Int) -> Int? {
        var index = start
        while index < chars.count {
            if matched(chars, needle, at: index) { return index + needle.count }
            index += 1
        }
        return nil
    }

    /// The character just past the tag's `>`, quote marks understood as what they fence.
    static func tagEnd(_ chars: [Character], from index: Int) -> Int? {
        var probe = index + 1
        var quote: Character?
        while probe < chars.count {
            let char = chars[probe]
            if let current = quote {
                if char == current { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ">" {
                return probe + 1
            }
            probe += 1
        }
        return nil
    }

    /// The tag name as spelled — `until` bounds it, so the call records the tag's own end.
    static func tagName(_ chars: [Character], from index: Int, until end: Int) -> String? {
        var probe = index
        while probe < end, chars[probe].isWhitespace { probe += 1 }
        let start = probe
        while probe < end, chars[probe] != ">", !chars[probe].isWhitespace, chars[probe] != "/" {
            probe += 1
        }
        let name = String(chars[start..<probe])
        return name.isEmpty ? nil : name
    }

    /// Whether the tag that ends at `end` wrote `/` before its `>`.
    static func isSelfClosing(_ chars: [Character], ending end: Int) -> Bool {
        var probe = end - 2
        while probe >= 0, chars[probe].isWhitespace { probe -= 1 }
        return probe >= 0 && chars[probe] == "/"
    }

    /// The character past a `</name … >` whose name matches, or nil when none does.
    static func matchingClose(_ name: String, in chars: [Character], from start: Int) -> Int? {
        let needle = Array("</\(name)")
        var index = start
        while index < chars.count {
            guard chars[index] == "<" else { index += 1; continue }
            guard tagNamed(chars, needle, at: index) else { index += 1; continue }
            var end = index + needle.count
            while end < chars.count, chars[end] != ">" { end += 1 }
            return end < chars.count ? end + 1 : nil
        }
        return nil
    }

    /// The one attribute this scan reads — `href` — in double quotes, singles, or bare, and
    /// another attribute's quoted value never swallows the tag's own end.
    static func attribute(_ name: String, within tag: String) -> String? {
        let chars = Array(tag)
        var index = 1
        while index < chars.count {
            let char = chars[index]
            if char == ">" { return nil }
            if char.isWhitespace || char == "/" { index += 1; continue }
            let start = index
            while index < chars.count, chars[index] != "=",
                !chars[index].isWhitespace, chars[index] != ">" { index += 1 }
            let key = String(chars[start..<index]).lowercased()
            var probe = index
            while probe < chars.count, chars[probe].isWhitespace { probe += 1 }
            guard probe < chars.count, chars[probe] == "=" else {
                index = index < chars.count ? index + 1 : index
                continue
            }
            probe += 1
            while probe < chars.count, chars[probe].isWhitespace { probe += 1 }
            guard probe < chars.count, chars[probe] != ">" else { return nil }
            if key == name.lowercased() {
                if chars[probe] == "\"" || chars[probe] == "'" {
                    let quote = chars[probe]
                    probe += 1
                    var value = ""
                    while probe < chars.count, chars[probe] != quote {
                        value.append(chars[probe])
                        probe += 1
                    }
                    return value
                }
                var value = ""
                while probe < chars.count, !chars[probe].isWhitespace, chars[probe] != ">" {
                    value.append(chars[probe])
                    probe += 1
                }
                return value
            }
            if chars[probe] == "\"" || chars[probe] == "'" {
                let quote = chars[probe]
                probe += 1
                while probe < chars.count, chars[probe] != quote { probe += 1 }
                probe += 1
            }
            index = probe
        }
        return nil
    }
}

private extension String {
    func takeIf(_ criterion: (String) -> Bool) -> String? {
        criterion(self) ? self : nil
    }
}

// MARK: - Entities

private extension ReadPageTool {
    /// The named entities the scan meets in real pages; the long tail is numeric entity
    /// territory '&' code form — and stays text when a page writes an unknown name.
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\u{0022}", "apos": "\u{0027}",
        "nbsp": " ", "shy": "", "zwnj": "", "zwj": "", "lrm": "", "rlm": "",
        "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "middot": "·",
        "bull": "•", "dagger": "†", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "sup2": "²", "sup3": "³", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "prime": "′", "Prime": "″",
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        let chars = Array(input)
        var output = ""
        output.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            guard chars[index] == "&" else {
                output.append(chars[index])
                index += 1
                continue
            }
            var probe = index + 1
            while probe < chars.count, chars[probe] != ";", probe - index <= 12 { probe += 1 }
            guard probe < chars.count, chars[probe] == ";", probe > index + 1 else {
                output.append(chars[index])
                index += 1
                continue
            }
            let name = String(chars[(index + 1)..<probe])
            if let replacement = namedEntities[name] ?? numericEntity(name) {
                output += replacement
            } else {
                output.append(contentsOf: chars[index...probe])
            }
            index = probe + 1
        }
        return output
    }

    /// `&#NY;` decimal and `&#xHH;` hex, surrogates and beyond-the-scalar numbers refused so
    /// they stay as the page wrote them.
    private static func numericEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let scalar: UInt32
        if digits.first == "x" || digits.first == "X" {
            guard let hex = UInt32(digits.dropFirst(), radix: 16) else { return nil }
            scalar = hex
        } else {
            guard let decimal = UInt32(digits) else { return nil }
            scalar = decimal
        }
        return Unicode.Scalar(scalar).map(String.init)
    }

    /// An href the page gives: entities decoded, resolved against the page's own base, and
    /// kept only when what it names is a web address a reader could follow.
    static func destination(_ given: String, from base: URL) -> String? {
        let decoded = decodeEntities(given).trimmingCharacters(in: .whitespaces)
        guard !decoded.isEmpty else { return nil }
        let url = URL(string: decoded, relativeTo: base) ?? URL(
            string: decoded.replacingOccurrences(of: " ", with: "%20"), relativeTo: base)
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        return scheme == "http" || scheme == "https" ? url.absoluteString : nil
    }
}

// MARK: - The token pass

private extension ReadPageTool {
    /// The prose-eligible document as tokens: text nodes, tag opens and tag closes. Tags the
    /// model is never meant to read vanish here, against the same name lists one pass above.
    static func tokens(of prose: String, hidingNavigation: Bool) -> [Token] {
        let chars = Array(prose)
        var result: [Token] = []
        result.reserveCapacity(16 + chars.count / 16)
        var index = 0
        while index < chars.count {
            guard chars[index] == "<" else {
                let start = index
                while index < chars.count, chars[index] != "<" { index += 1 }
                result.append(.text(String(chars[start..<index])))
                continue
            }
            if index + 3 < chars.count, chars[index + 1] == "!",
                chars[index + 2] == "-", chars[index + 3] == "-"
            {
                index = find(chars, Array("-->"), after: index) ?? chars.count
                continue
            }
            guard let end = tagEnd(chars, from: index) else {
                result.append(.text(String(chars[index...])))
                break
            }
            let isClosing = index + 1 < chars.count && chars[index + 1] == "/"
            let raw = tagName(chars, from: index + (isClosing ? 2 : 1), until: end)
            let start = index
            index = end
            guard let raw, !raw.isEmpty else { continue }
            let name = raw.lowercased()
            if !isClosing, Invisible.names.contains(name),
                let closed = matchingClose(name, in: chars, from: end)
            {
                index = closed
                continue
            }
            if !isClosing, hidingNavigation, Navigation.names.contains(name) {
                index = matchingClose(name, in: chars, from: end) ?? chars.count
                continue
            }
            if isClosing {
                result.append(.close(name))
                continue
            }
            let link = name == "a" ? attribute("href", within: String(chars[start..<end])) : nil
            result.append(.open(name, href: link))
            if isSelfClosing(chars, ending: end), !VoidElement.names.contains(name) {
                result.append(.close(name))
            }
        }
        return result
    }
}

// MARK: - The reader

/// Tokens in, markdown-shaped lines out — one pass, so its state is the handful of fields
/// below and no more, and what it emits for a page is exactly what `read-page-test` pins.
private final class Body {
    private var lines: [String] = []
    private var line = ""
    private var pendingSpace = false
    private var lists: [(ordered: Bool, index: Int)] = []
    private var pendingPrefix: String?
    private var inListItem = false
    private var headingLevel: Int?
    private var linkSpan: (start: Int, href: String?)?
    private var linkDepth = 0
    private var codeSpan: Int?
    private var preText: String?
    /// The open tables, each holding its rows, each row holding its cells — the topmost is
    /// the one whose text the next flush serves.
    private var tables: [[[String]]] = []
    private var cellText: String?
    private let linkBase: URL

    init(base: URL) { self.linkBase = base }

    func render(_ tokens: [ReadPageTool.Token]) -> String {
        for token in tokens {
            switch token {
            case .text(let text): absorb(text)
            case .open(let name, let href): opened(name, href)
            case .close(let name): closed(name)
            }
        }
        settle()
        return joined()
    }

    private func absorb(_ raw: String) {
        let text = ReadPageTool.decodeEntities(raw)
        if let open = preText {
            preText = open + text
            return
        }
        let pieces = text.flattened
        guard !pieces.isEmpty else {
            // Whitespace between inline text marks the boundary; it never ends the line.
            return
        }
        let boundary = pendingSpace || (text.first?.isWhitespace ?? false)
        if boundary, !line.isBlank, line.last != "\n", line.last != " " { line += " " }
        line += pieces
        pendingSpace = text.last?.isWhitespace ?? false
    }

    private func opened(_ name: String, _ href: String?) {
        switch name {
        case "br":
            line += "\n"
            pendingSpace = false
        case "hr":
            apart()
            lines.append("---")
            apart()
        case "h1", "h2", "h3", "h4", "h5", "h6":
            apart()
            headingLevel = Int(String(name.dropFirst()))
        case "p", "div", "section", "article", "main", "header", "footer", "aside", "nav",
            "figure", "figcaption", "blockquote", "details", "summary", "address", "fieldset",
            "dl", "dt", "dd", "caption":
            apart()
        case "ul", "ol":
            apart()
            lists.append((ordered: name == "ol", index: 0))
        case "li":
            _ = flush()
            if !lists.isEmpty {
                lists[lists.count - 1].index += 1
                let current = lists[lists.count - 1]
                pendingPrefix = current.ordered ? "\(current.index). " : "- "
            } else {
                pendingPrefix = "- "
            }
            inListItem = true
        case "pre":
            apart()
            preText = ""
        case "code":
            if codeSpan == nil {
                keepBoundary()
                codeSpan = line.count
                pendingSpace = false
            }
        case "a":
            if linkDepth == 0 {
                keepBoundary()
                linkSpan = (
                    start: line.count,
                    href: href.flatMap { ReadPageTool.destination($0, from: linkBase) })
                pendingSpace = false
            }
            linkDepth += 1
        case "table":
            _ = flush()
            tables.append([])
            if tables.count == 1 { apart() }
        case "tr":
            _ = flush()
            guard !tables.isEmpty else { break }
            if tables.count == 1 && tables[tables.count - 1].last != nil {
                closeRow()
            }
            if tables.count == 1 { tables[tables.count - 1].append([]) }
        case "td", "th":
            _ = flush()
            guard tables.count == 1, tables[tables.count - 1].last != nil else { break }
            if let pending = cellText {
                cellText = nil
                if pending.hasContent {
                    appendCell(pending.trimmingCharacters(in: .whitespaces))
                }
            }
            cellText = ""
        default:
            break
        }
    }

    private func closed(_ name: String) {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            _ = flush()
            headingLevel = nil
        case "p", "div", "section", "article", "main", "header", "footer", "aside", "nav",
            "figure", "figcaption", "blockquote", "details", "summary", "address", "fieldset",
            "dl", "dt", "dd", "caption":
            _ = flush()
        case "ul", "ol":
            _ = flush()
            if !lists.isEmpty { lists.removeLast() }
        case "li":
            _ = flush()
            pendingPrefix = nil
            inListItem = !lists.isEmpty
        case "pre":
            if let text = preText {
                preText = nil
                emitFences(text)
            }
        case "code":
            if let start = codeSpan {
                codeSpan = nil
                let slice = String(line[line.index(line.startIndex, offsetBy: start)...])
                let segment = slice.trimmingCharacters(in: .whitespaces)
                line = String(line[..<line.index(line.startIndex, offsetBy: start)])
                    + (segment.hasContent ? "`" + segment + "`" : "")
            }
        case "a":
            linkDepth = max(0, linkDepth - 1)
            if linkDepth == 0, let span = linkSpan {
                linkSpan = nil
                let segment = String(line[line.index(line.startIndex, offsetBy: span.start)...])
                    .trimmingCharacters(in: .whitespaces)
                line = String(line[..<line.index(line.startIndex, offsetBy: span.start)])
                    + (span.href != nil && !segment.isBlank
                        ? "[" + segment + "](" + span.href! + ")" : segment)
            }
        case "table":
            _ = flush()
            guard let deepest = tables.popLast() else { break }
            if tables.isEmpty {
                closeTopTable(deepest)
            } else {
                foldFlat(deepest)
            }
        case "tr":
            if tables.count == 1 { closeRow() }
        case "td", "th":
            _ = flush()
            if let pending = cellText {
                cellText = nil
                if pending.hasContent, tables.count == 1, tables.last?.last != nil {
                    appendCell(pending.trimmingCharacters(in: .whitespaces))
                }
            }
        default:
            break
        }
    }

    /// The rows of a table that ended, built into tight lines, any open cell closed first.
    private func closeTopTable(_ rows: [[String]]) {
        if let pending = cellText {
            cellText = nil
            if pending.hasContent, let last = rows.last {
                var whole = last
                whole.append(pending.trimmingCharacters(in: .whitespaces))
                lines.append(whole.filter { $0.hasContent }.joined(separator: " | "))
            }
        }
        for cells in rows where cells.contains(where: { $0.hasContent }) {
            lines.append(cells.filter { $0.hasContent }.joined(separator: " | "))
        }
        apart()
    }

    /// A table nested somewhere in a cell loses its shape and joins as text — the model reads
    /// it flat rather than as the second row of a row it is not in.
    private func foldFlat(_ rows: [[String]]) {
        let flat = rows
            .map { $0.filter { $0.hasContent }.joined(separator: " | ") }
            .filter { $0.hasContent }
            .joined(separator: " | ")
        guard flat.hasContent else { return }
        if var pending = cellText {
            if pending.hasContent { pending += " " }
            cellText = pending + flat
        } else {
            appendCell(flat)
        }
    }

    /// One more cell into the active row of the innermost table, when there is one.
    private func appendCell(_ text: String) {
        guard !tables.isEmpty, !tables[tables.count - 1].isEmpty else { return }
        tables[tables.count - 1][tables[tables.count - 1].count - 1].append(text)
    }

    /// One row ends: the open cell folds in, and the cells so far become the row's one line.
    private func closeRow() {
        _ = flush()
        if let pending = cellText {
            cellText = nil
            if pending.hasContent {
                appendCell(pending.trimmingCharacters(in: .whitespaces))
            }
        }
        guard !tables.isEmpty, tables.last?.last != nil else { return }
        let cells = tables[tables.count - 1].last?.filter { $0.hasContent } ?? []
        tables[tables.count - 1].removeLast()
        let row = cells.joined(separator: " | ")
        if row.hasContent { lines.append(row) }
    }

    private func emitFences(_ text: String) {
        lines.append("```")
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        if body.hasContent {
            lines.append(body)
        }
        lines.append("```")
        apart()
    }

    @discardableResult
    private func flush() -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        line = ""
        guard text.hasContent else { return false }
        if cellText != nil {
            var pending = cellText ?? ""
            if pending.hasContent { pending += " " }
            cellText = pending + text
            return true
        }
        if let prefix = pendingPrefix {
            pendingPrefix = nil
            lines.append(prefix + text)
            return true
        }
        if inListItem {
            lines.append("  " + text)
            return true
        }
        if let level = headingLevel {
            headingLevel = nil
            lines.append(String(repeating: "#", count: level) + " " + text)
            return true
        }
        lines.append(text)
        return true
    }

    /// A block boundary worth a blank line after what came before it.
    private func apart() {
        _ = flush()
        if let last = lines.last, !last.isBlank { lines.append("") }
    }

    /// Whatever whitespace is pending commits before an inline span opens, so the span's
    /// start index slices exactly its own text and the boundary space stays outside it.
    private func keepBoundary() {
        if pendingSpace, !line.isBlank, line.last != "\n", line.last != " " { line += " " }
        pendingSpace = false
    }

    private func settle() {
        linkSpan = nil
        linkDepth = 0
        codeSpan = nil
        if let text = preText {
            preText = nil
            emitFences(text)
        }
        _ = flush()
    }

    private func joined() -> String {
        var output = lines.joined(separator: "\n")
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var hasContent: Bool { !isBlank }
}
