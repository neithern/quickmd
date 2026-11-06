import Foundation

// MARK: - HTML <img> Lines (v1.11 T-C)
//
// READMEs centre their logos with raw HTML:
//
//     <p align="center">
//       <img src="logo.png" width="200" alt="Logo">
//     </p>
//
// QuickMD never renders HTML (no WebKit for document content), so before this
// every such line was literal text. This scanner recognises exactly one narrow
// shape: a line that, after trimming, is NOTHING BUT `<img>` tags and a fixed
// set of layout wrapper tags, separated by whitespace or no-break spaces.
// Each `<img>` becomes an ordinary `.image` block (same `ImageSource`/
// `ImageLoader` path as a Markdown image); a line of wrappers alone produces
// no block at all. Any other HTML — another tag name,
// text next to a tag, an `<img>` inside a paragraph — is not recognised and
// stays literal text, exactly as before.
//
// The tag grammar follows CommonMark's raw-HTML definitions (tag names
// `[A-Za-z][A-Za-z0-9-]*`, attribute names `[A-Za-z_:][A-Za-z0-9_.:-]*`,
// double/single-quoted or unquoted values), case-insensitive.
//
// Why bytes: an `<img src="data:…">` line can be megabytes. Every delimiter
// here is ASCII, so the scan runs once over the UTF-8 buffer (no regex, no
// backtracking), and a line that does not START with `<` is rejected before
// its buffer is touched at all.

enum HTMLImageSyntax {

    /// One `<img>` tag of a recognised line.
    struct Tag: Sendable, Equatable {
        /// `src`, entities decoded, surrounding whitespace trimmed. Never empty.
        let url: String
        /// `alt`, entities decoded, whitespace runs collapsed ("" when absent).
        let alt: String
        /// `width` when it is one of the understood forms (see `width(from:)`).
        let width: ImageWidth?
        /// Line breaks between the start of the scanned text and this tag's
        /// `<` — the parser maps it to the line the tag STARTS on, which is
        /// the block's `sourceLine` (a multi-line tag is scanned joined).
        let lineOffset: Int
    }

    enum LineScan: Equatable {
        /// Nothing but recognised tags and whitespace. `images` is EMPTY for a
        /// wrapper-only line (`<p align="center">`, `</p>`, …);
        /// `lineBreakOnly` is true when that line is nothing but `<br>` tags —
        /// the parser turns it into a hard break of the paragraph above.
        case tags(images: [Tag], lineBreakOnly: Bool)
        /// Recognised tags so far, then the text ends INSIDE an `<img` tag
        /// (no closing `>` yet): the parser may join following lines and scan
        /// again. Any other unterminated tag is simply not recognised.
        case unterminatedImage
    }

    /// Wrapper tags that may surround or sit next to `<img>` and are dropped.
    /// Opening forms may carry attributes (`<p align="center">`, `<a href=…>`,
    /// `<source srcset=…>`). `<a href>` is ignored for now: clicking the image
    /// keeps opening the preview.
    ///
    /// Table structure is included because READMEs put screenshot grids in
    /// `<td>` cells (`<tr><td><img src="…"></td><td><img …></td></tr>`): the
    /// wrapper-only lines disappear and each cell's `<img>` becomes an image
    /// block — vertically, not as a grid (that would need a table renderer).
    private static let openingWrappers: Set<String> = [
        "p", "div", "center", "a", "picture", "source", "br",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th",
    ]
    private static let closingWrappers: Set<String> = [
        "p", "div", "center", "a", "picture",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th",
    ]

    /// Classifies a line (or several joined with `\n`), see `LineScan`. Nil
    /// when the text is anything else — including an empty or blank line.
    static func scan(_ line: Substring) -> LineScan? {
        // Unicode-whitespace trim like `InlineSyntaxScanner.standaloneImages`;
        // only the two ends are walked.
        let scalars = line.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
        let trimmed = Substring(scalars[first...last])
        // Cheap reject for every non-HTML line, BEFORE any buffer access
        // (which may have to copy a bridged multi-MB string).
        guard trimmed.utf8.first == UInt8(ascii: "<") else { return nil }
        return withBytes(trimmed) { scanTags($0) }
    }

    /// `width` attribute → `ImageWidth`: `120` / `120px` → 120 pt at 100 %
    /// zoom; `50%` → half the column cap. Decimals are accepted; zero,
    /// negative, empty or any other unit/garbage → nil (the attribute is
    /// ignored and the image's own width applies, like a Markdown image).
    static func width(from raw: String) -> ImageWidth? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        var isPercent = false
        if text.hasSuffix("%") {
            isPercent = true
            text = text.dropLast()
        } else if text.lowercased().hasSuffix("px") {
            text = text.dropLast(2)
        }
        // Digits with at most one decimal point — `Double("1e3")`, "inf",
        // "0x10" and friends must not slip through.
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1,
              let value = Double(text), value > 0 else { return nil }
        return isPercent ? .fraction(CGFloat(value / 100)) : .points(CGFloat(value))
    }

    /// Decodes the character references an attribute value realistically
    /// carries: `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` and numeric `&#NN;` /
    /// `&#xNN;`. Anything else (unknown names, invalid code points, a bare
    /// `&`) is kept literally. One linear pass; no `&` → the input unchanged.
    static func decodeEntities(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        var out = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if scalars[i] == "&", let (decoded, next) = entity(in: scalars, at: i) {
                out.append(decoded)
                i = next
            } else {
                out.append(scalars[i])
                i = scalars.index(after: i)
            }
        }
        return String(out)
    }

    // MARK: Entities

    /// The reference starting at `start` (an `&`): its scalar and the index
    /// past the `;`. Names are at most a few characters, so the look-ahead is
    /// bounded — never a scan over a payload.
    private static func entity(in scalars: String.UnicodeScalarView,
                               at start: String.Index) -> (Unicode.Scalar, String.Index)? {
        var body = ""
        var i = scalars.index(after: start)
        while i < scalars.endIndex, body.unicodeScalars.count <= 10 {
            let scalar = scalars[i]
            if scalar == ";" {
                guard let decoded = decodeEntityBody(body) else { return nil }
                return (decoded, scalars.index(after: i))
            }
            body.unicodeScalars.append(scalar)
            i = scalars.index(after: i)
        }
        return nil
    }

    private static func decodeEntityBody(_ body: String) -> Unicode.Scalar? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        // A real U+00A0: `alt` collapses it to a space with other whitespace;
        // between tags `skipSeparators` treats it as whitespace.
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            let hex = digits.dropFirst()
            value = hex.isEmpty || !hex.allSatisfy(\.isHexDigit) ? nil : UInt32(hex, radix: 16)
        } else {
            value = digits.isEmpty || !digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : UInt32(digits)
        }
        // U+0000 is not a character a URL or caption may contain.
        guard let value, value != 0 else { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: Byte access

    private typealias Bytes = UnsafeBufferPointer<UInt8>

    /// Same contract as `InlineSyntaxScanner.withBytes`: native strings hand
    /// out their storage, a bridged NSString is copied once.
    private static func withBytes<R>(_ text: Substring, _ body: (Bytes) -> R) -> R {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        var copy = String(text)
        copy.makeContiguousUTF8()
        return copy.utf8.withContiguousStorageIfAvailable(body)!
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func string(_ bytes: Bytes, _ range: Range<Int>) -> String {
        String(decoding: Bytes(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: Scanner

    /// Raw attribute values of one `<img>` (first occurrence wins, as in HTML).
    private struct ImageAttributes {
        var src: Range<Int>?
        var alt: Range<Int>?
        var width: Range<Int>?
    }

    private enum TagResult {
        case wrapper(end: Int, isLineBreak: Bool)
        case image(ImageAttributes, end: Int)
        /// The text ended inside an `<img` tag.
        case unterminatedImage
        case invalid
    }

    private static func scanTags(_ bytes: Bytes) -> LineScan? {
        var images: [Tag] = []
        var i = 0
        // Line breaks are counted incrementally up to each tag start, so the
        // whole scan stays linear.
        var newlines = 0
        var counted = 0
        var onlyLineBreaks = true
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<") else { return nil }
            while counted < i {
                if bytes[counted] == 0x0A { newlines += 1 }
                counted += 1
            }
            switch scanTag(bytes, at: i) {
            case .invalid:
                return nil
            case .unterminatedImage:
                return .unterminatedImage
            case .wrapper(let end, let isLineBreak):
                onlyLineBreaks = onlyLineBreaks && isLineBreak
                i = end
            case .image(let attributes, let end):
                guard let tag = makeTag(bytes, attributes, lineOffset: newlines) else { return nil }
                images.append(tag)
                i = end
            }
            i = skipSeparators(bytes, from: i)
        }
        return .tags(images: images, lineBreakOnly: images.isEmpty && onlyLineBreaks)
    }

    /// What may sit BETWEEN (or after) tags: ASCII whitespace, a literal
    /// U+00A0 (UTF-8 `C2 A0`), and the no-break-space references `&nbsp;`,
    /// `&#160;`, `&#xA0;` — the README logo row `<img …>&nbsp;<img …>`.
    private static func skipSeparators(_ bytes: Bytes, from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            if isWhitespace(bytes[i]) { i += 1; continue }
            if bytes[i] == 0xC2, i + 1 < bytes.count, bytes[i + 1] == 0xA0 { i += 2; continue }
            if bytes[i] == UInt8(ascii: "&"), let length = nbspReferenceLength(bytes, at: i) { i += length; continue }
            break
        }
        return i
    }

    private static let nbspReferences: [[UInt8]] = ["&nbsp;", "&#160;", "&#xA0;", "&#xa0;", "&#Xa0;", "&#XA0;"]
        .map { Array($0.utf8) }

    private static func nbspReferenceLength(_ bytes: Bytes, at start: Int) -> Int? {
        for reference in nbspReferences where start + reference.count <= bytes.count {
            if bytes[start..<(start + reference.count)].elementsEqual(reference) { return reference.count }
        }
        return nil
    }

    /// An `<img>` without a usable `src` is not an image: the whole line then
    /// stays text (the conservative reading — it is HTML we cannot show).
    private static func makeTag(_ bytes: Bytes, _ attributes: ImageAttributes, lineOffset: Int) -> Tag? {
        guard let srcRange = attributes.src else { return nil }
        let url = decodeEntities(string(bytes, srcRange)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let alt = attributes.alt.map {
            decodeEntities(string(bytes, $0))
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        } ?? ""
        let width = attributes.width.flatMap { self.width(from: decodeEntities(string(bytes, $0))) }
        return Tag(url: url, alt: alt, width: width, lineOffset: lineOffset)
    }

    /// One tag starting at `start` (a `<`).
    private static func scanTag(_ bytes: Bytes, at start: Int) -> TagResult {
        var i = start + 1
        let isClosing = i < bytes.count && bytes[i] == UInt8(ascii: "/")
        if isClosing { i += 1 }

        let nameStart = i
        guard i < bytes.count, isLetter(bytes[i]) else { return .invalid }
        while i < bytes.count, isLetter(bytes[i]) || isDigit(bytes[i]) || bytes[i] == UInt8(ascii: "-") { i += 1 }
        let name = string(bytes, nameStart..<i).lowercased()

        if isClosing {
            guard closingWrappers.contains(name) else { return .invalid }
            while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: ">") else { return .invalid }
            return .wrapper(end: i + 1, isLineBreak: false)
        }

        let isImage = name == "img"
        guard isImage || openingWrappers.contains(name) else { return .invalid }
        // Running off the end is only interesting for `<img`: the parser
        // joins the following lines and tries again.
        let unterminated: TagResult = isImage ? .unterminatedImage : .invalid
        var attributes = ImageAttributes()

        while true {
            let gapStart = i
            while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
            guard i < bytes.count else { return unterminated }

            if bytes[i] == UInt8(ascii: ">") {
                i += 1
                break
            }
            if bytes[i] == UInt8(ascii: "/") {
                guard i + 1 < bytes.count else { return unterminated }
                guard bytes[i + 1] == UInt8(ascii: ">") else { return .invalid }
                i += 2
                break
            }
            // Attributes are separated from the name and from each other by
            // whitespace (`<img"x">` / `<imgsrc=…>` are not tags).
            guard i > gapStart else { return .invalid }

            // Attribute name: [A-Za-z_:][A-Za-z0-9_.:-]*
            let attrStart = i
            guard isLetter(bytes[i]) || bytes[i] == UInt8(ascii: "_") || bytes[i] == UInt8(ascii: ":") else {
                return .invalid
            }
            while i < bytes.count, isLetter(bytes[i]) || isDigit(bytes[i])
                    || bytes[i] == UInt8(ascii: "_") || bytes[i] == UInt8(ascii: ".")
                    || bytes[i] == UInt8(ascii: ":") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let attrEnd = i

            // Optional `= value` (whitespace allowed around `=`).
            var probe = i
            while probe < bytes.count, isWhitespace(bytes[probe]) { probe += 1 }
            var value: Range<Int>?
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "=") {
                i = probe + 1
                while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
                guard i < bytes.count else { return unterminated }
                let quote = bytes[i]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    var close = i + 1
                    while close < bytes.count, bytes[close] != quote { close += 1 }
                    guard close < bytes.count else { return unterminated }
                    value = (i + 1)..<close
                    i = close + 1
                } else {
                    // Unquoted: no whitespace, `"`, `'`, `=`, `<`, `>` or backtick.
                    let valueStart = i
                    while i < bytes.count, !isWhitespace(bytes[i]), !isForbiddenUnquoted(bytes[i]) { i += 1 }
                    guard i > valueStart else { return .invalid }
                    value = valueStart..<i
                }
            }

            // Compared in place (no String per attribute): a tag can carry
            // thousands of attributes. height, class, style, … are ignored
            // (the aspect ratio is kept).
            if isImage {
                let name = attrStart..<attrEnd
                let present = value ?? (attrEnd..<attrEnd)
                if attributes.src == nil, equalsLowercased(bytes, name, "src") {
                    attributes.src = present
                } else if attributes.alt == nil, equalsLowercased(bytes, name, "alt") {
                    attributes.alt = present
                } else if attributes.width == nil, equalsLowercased(bytes, name, "width") {
                    attributes.width = present
                }
            }
        }

        return isImage ? .image(attributes, end: i) : .wrapper(end: i, isLineBreak: name == "br")
    }

    /// ASCII case-insensitive `bytes[range] == name` (`name` is lowercase).
    private static func equalsLowercased(_ bytes: Bytes, _ range: Range<Int>, _ name: StaticString) -> Bool {
        guard range.count == name.utf8CodeUnitCount else { return false }
        let expected = UnsafeBufferPointer(start: name.utf8Start, count: name.utf8CodeUnitCount)
        for (offset, byte) in expected.enumerated() where (bytes[range.lowerBound + offset] | 0x20) != byte {
            return false
        }
        return true
    }

    private static func isForbiddenUnquoted(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "="),
             UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "`"):
            return true
        default:
            return false
        }
    }
}

// MARK: - Common HTML tag tokenizer

/// A minimal HTML tag tokenizer shared by the inline renderer and the HTML
/// table scanner. It only understands the shape those two need — `<name
/// attr=value …>`, `</name>`, `<name/>`, quoted/unquoted values — and never
/// interprets what a tag means. Anything malformed returns nil, so callers keep
/// the text literally (HTML stays a conservative subset).
///
/// Foundation-only and allocation-light: tag/attribute names are ASCII, values
/// are materialised only for attributes (`href`, `align`, `style`).
enum HTMLTagSyntax {

    struct Tag {
        /// Lowercased tag name.
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        /// Attribute names lowercased; values entity-decoded, quotes removed.
        /// The first occurrence of an attribute wins, as in HTML.
        let attributes: [String: String]
        /// Index just past the closing `>`.
        let end: String.Index
    }

    /// Parses a tag at the start of `text` (which must start with `<`). Nil for
    /// anything that is not a complete, syntactically valid tag — comments
    /// included; use `commentEnd(atStartOf:)` for those.
    static func tag(atStartOf text: Substring) -> Tag? {
        guard text.first == "<" else { return nil }
        let end = text.endIndex
        var i = text.index(after: text.startIndex)
        guard i < end else { return nil }

        var isClosing = false
        if text[i] == "/" {
            isClosing = true
            i = text.index(after: i)
        }
        guard i < end, isASCIILetter(text[i]) else { return nil }
        let nameStart = i
        while i < end, isTagNameCharacter(text[i]) { i = text.index(after: i) }
        let name = String(text[nameStart..<i]).lowercased()

        if isClosing {
            while i < end, text[i].isWhitespace { i = text.index(after: i) }
            guard i < end, text[i] == ">" else { return nil }
            return Tag(name: name, isClosing: true, isSelfClosing: false,
                       attributes: [:], end: text.index(after: i))
        }

        var attributes: [String: String] = [:]
        var selfClosing = false
        while true {
            while i < end, text[i].isWhitespace { i = text.index(after: i) }
            guard i < end else { return nil }
            if text[i] == ">" {
                i = text.index(after: i)
                break
            }
            if text[i] == "/" {
                let afterSlash = text.index(after: i)
                guard afterSlash < end, text[afterSlash] == ">" else { return nil }
                selfClosing = true
                i = text.index(after: afterSlash)
                break
            }
            guard isAttributeNameStart(text[i]) else { return nil }
            let attrStart = i
            while i < end, isAttributeNameCharacter(text[i]) { i = text.index(after: i) }
            let attrName = String(text[attrStart..<i]).lowercased()

            var probe = i
            while probe < end, text[probe].isWhitespace { probe = text.index(after: probe) }
            var value = ""
            if probe < end, text[probe] == "=" {
                i = text.index(after: probe)
                while i < end, text[i].isWhitespace { i = text.index(after: i) }
                guard i < end else { return nil }
                if text[i] == "\"" || text[i] == "'" {
                    let quote = text[i]
                    i = text.index(after: i)
                    let valueStart = i
                    while i < end, text[i] != quote { i = text.index(after: i) }
                    guard i < end else { return nil }
                    value = String(text[valueStart..<i])
                    i = text.index(after: i)
                } else {
                    let valueStart = i
                    while i < end, !text[i].isWhitespace, text[i] != ">" {
                        i = text.index(after: i)
                    }
                    guard i > valueStart else { return nil }
                    value = String(text[valueStart..<i])
                }
            }
            if attributes[attrName] == nil {
                attributes[attrName] = HTMLEntities.decode(value)
            }
        }
        return Tag(name: name, isClosing: false, isSelfClosing: selfClosing,
                   attributes: attributes, end: i)
    }

    /// The index just past a comment at `text`'s start (`<!-- … -->`), or nil.
    static func commentEnd(atStartOf text: Substring) -> String.Index? {
        guard text.hasPrefix("<!--") else { return nil }
        guard let range = text.range(of: "-->") else { return nil }
        return range.upperBound
    }

    /// The contents of the first close tag named `name`, with nested tags of
    /// the same name counted (so `<a><a>x</a></a>` closes the outer one at the
    /// second `</a>`). `start` is just past the opening tag.
    static func matchingClose(named name: String, in text: Substring, from start: String.Index)
        -> (inner: Range<String.Index>, end: String.Index)? {
        var i = start
        var depth = 0
        while i < text.endIndex {
            guard let lt = text[i...].firstIndex(of: "<") else { return nil }
            if let commentEnd = commentEnd(atStartOf: text[lt...]) {
                i = commentEnd
                continue
            }
            guard let tag = tag(atStartOf: text[lt...]) else {
                i = text.index(after: lt)
                continue
            }
            if tag.name == name {
                if tag.isClosing {
                    if depth == 0 { return (start..<lt, tag.end) }
                    depth -= 1
                } else if !tag.isSelfClosing {
                    depth += 1
                }
            }
            i = tag.end
        }
        return nil
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        isASCIIScalar(character) && character.isLetter
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        isASCIIScalar(character) && (character.isLetter || character.isNumber || character == "-")
    }

    private static func isAttributeNameStart(_ character: Character) -> Bool {
        isASCIIScalar(character) && (character.isLetter || character == "_" || character == ":")
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        isASCIIScalar(character) && (character.isLetter || character.isNumber
            || character == "_" || character == "." || character == ":" || character == "-")
    }

    private static func isASCIIScalar(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.isASCII }
    }
}

// MARK: - Block text tags

/// Unwraps one line of a block-level, text-bearing HTML tag into the text it
/// shows (plus the heading level for `<h1>`–`<h6>`). The parser uses it for
/// `<p>`, `<div>`, `<caption>`, `<summary>`, `<h1>…</h1>` and similar tags whose
/// content is plain text: block wrappers are dropped, inline tags the renderer
/// understands (`<a>`, `<strong>`, `<em>`, `<code>`, …) stay verbatim, and
/// unknown tags make the whole line fall back to literal text.
///
/// `caption` is also captured by `HTMLTableSyntax` when it is inside a table;
/// this type covers a standalone `<caption>` and every other text block.
enum HTMLBlockText {

    struct Line: Equatable {
        /// The visible text, still containing the kept inline tags.
        let text: String
        /// 1…6 when the line contains an opening `<h1>`…`<h6>`.
        let headingLevel: Int?
    }

    /// Block containers whose content is read as text. Their tags are dropped;
    /// the text around them is kept.
    private static let blockTags: Set<String> = [
        "p", "div", "center", "caption", "summary", "figcaption",
        "section", "article", "header", "footer", "main", "aside",
        "figure", "details", "li", "dt", "dd", "blockquote",
        "ul", "ol", "dl", "address", "legend", "nav",
        "html", "body", "head", "title", "td", "th", "tr",
    ]

    /// Inline tags the renderer styles itself; kept as written for `renderInline`.
    private static let keptInlineTags: Set<String> = [
        "a", "strong", "b", "em", "i", "code", "del", "s", "strike", "br",
    ]

    /// Inline wrappers with no style of their own: drop the tags, keep the text.
    private static let droppedInlineTags: Set<String> = [
        "span", "small", "mark", "u", "sub", "sup", "font",
    ]

    /// Tags whose wrappers are transparent in inline content too (table cells,
    /// link text, headings): the block containers above, the heading tags and
    /// the style-less inline wrappers. Kept tags (`<a>`, `<em>`, …) are not here.
    static let transparentInlineTags: Set<String> =
        blockTags
            .union(Set(["h1", "h2", "h3", "h4", "h5", "h6"]))
            .union(droppedInlineTags)

    /// Unwraps `line`; nil when the line carries no block tag (so the normal
    /// inline path handles it) or contains an unsupported tag.
    static func unwrap(_ line: String) -> Line? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " ", indent < 4 {
            indent += 1
            index = line.index(after: index)
        }
        guard indent <= 3, index < line.endIndex, line[index] == "<" else { return nil }

        var text = ""
        var heading: Int?
        var sawBlock = false
        var i = index
        let end = line.endIndex

        func appendText(_ chunk: Substring) {
            text.append(contentsOf: chunk)
        }
        func appendSeparator() {
            guard !text.isEmpty, text.last?.isWhitespace != true else { return }
            text.append(" ")
        }

        while i < end {
            if line[i] != "<" {
                let next = line[i...].firstIndex(of: "<") ?? end
                appendText(line[i..<next])
                i = next
                continue
            }
            if let commentEnd = HTMLTagSyntax.commentEnd(atStartOf: line[i...]) {
                i = commentEnd
                continue
            }
            let tagStart = i
            guard let tag = HTMLTagSyntax.tag(atStartOf: line[i...]) else {
                appendText("<"[...])
                i = line.index(after: i)
                continue
            }
            let name = tag.name
            i = tag.end

            if let level = headingLevel(of: name) {
                sawBlock = true
                if !tag.isClosing { heading = level }
                continue
            }
            if blockTags.contains(name) {
                sawBlock = true
                // Between block elements, e.g. `<p>a</p><p>b</p>`.
                appendSeparator()
                continue
            }
            if droppedInlineTags.contains(name) {
                continue
            }
            if keptInlineTags.contains(name) {
                appendText(line[tagStart..<tag.end])
                continue
            }
            return nil   // unsupported tag: leave the line literal
        }

        guard sawBlock else { return nil }
        return Line(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    headingLevel: heading)
    }

    /// The range of a `</hN>` tag in `line`, for the parser's multi-line
    /// heading form:
    ///
    ///     <h1 align="center">
    ///     Title
    ///     </h1>
    static func closingHeadingRange(in line: String, level: Int) -> Range<String.Index>? {
        let name = "h\(level)"
        var i = line.startIndex
        while i < line.endIndex {
            guard let lt = line[i...].firstIndex(of: "<") else { return nil }
            guard let tag = HTMLTagSyntax.tag(atStartOf: line[lt...]) else {
                i = line.index(after: lt)
                continue
            }
            if tag.name == name && tag.isClosing { return lt..<tag.end }
            i = tag.end
        }
        return nil
    }

    private static func headingLevel(of name: String) -> Int? {
        guard name.count == 2, name.first == "h",
              let level = name.last?.wholeNumberValue, (1...6).contains(level) else { return nil }
        return level
    }
}

// MARK: - HTML tables

/// Scans a narrow, GitHub-README-shaped subset of HTML tables into the same
/// grid a pipe table produces. Foundation-only and off-main safe: the parser
/// turns the result into a normal `.table` block, so measurement, selection,
/// search and PDF need no new code.
///
/// Supported: `table`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`,
/// `caption` (emitted as the text block just above the table),
/// `col`/`colgroup` (ignored), `align` and `style="text-align:…"`.
/// Cell content keeps inline Markdown and the inline HTML tags the renderer
/// understands; block wrappers (`p`, `div`, `center`, `span`) are transparent
/// and `br` is a space (a table cell is one paragraph).
///
/// Deliberately unsupported — the whole table then stays the existing
/// line-based text/image handling: nested tables, `<img>` in a cell, `script`,
/// `style`, and `colspan`/`rowspan` (parsed as ordinary cells, no merging).
/// HTML outside this subset is never executed or loaded.
enum HTMLTableSyntax {

    enum Alignment: Equatable {
        case leading, center, trailing
    }

    struct Table: Equatable {
        let headers: [String]
        let rows: [[String]]
        let alignments: [Alignment]
        /// `<caption>` text, when the table has one (nil otherwise).
        let caption: String?
        /// Index of the first line after `</table>`.
        let endIndex: Int
    }

    private struct Cell {
        var text = ""
        var alignment: Alignment?
    }

    private struct Row {
        var cells: [Cell] = []
        var isHeader = false
    }

    /// Scans a table starting on `lines[start]`. Nil when this is not a table,
    /// the table is incomplete, or it uses an unsupported construct.
    static func scan(_ lines: [String], from start: Int) -> Table? {
        guard start < lines.count, isTableStart(lines[start]) else { return nil }

        var depth = 0
        var rows: [Row] = []
        var row: Row?
        var cell: Cell?
        var inThead = false
        var inCaption = false
        var inComment = false
        var caption = ""
        var endIndex: Int?

        func closeCell() {
            guard let current = cell else { return }
            if row == nil { row = Row(isHeader: inThead) }
            row?.cells.append(current)
            cell = nil
        }
        func closeRow() {
            closeCell()
            guard let current = row else { return }
            if !current.cells.isEmpty { rows.append(current) }
            row = nil
        }
        func appendText(_ text: Substring) {
            if inCaption {
                caption.append(contentsOf: text)
            } else if cell != nil {
                cell?.text.append(contentsOf: text)
            }
        }
        func appendSpace() {
            if inCaption {
                if !caption.isEmpty, caption.last?.isWhitespace != true { caption.append(" ") }
                return
            }
            guard var current = cell else { return }
            if !current.text.isEmpty, current.text.last?.isWhitespace != true {
                current.text.append(" ")
            }
            cell = current
        }

        lineLoop: for lineIndex in start..<lines.count {
            let line = lines[lineIndex]
            var cursor = line.startIndex
            while cursor < line.endIndex {
                if inComment {
                    if let range = line.range(of: "-->", range: cursor..<line.endIndex) {
                        inComment = false
                        cursor = range.upperBound
                    } else {
                        cursor = line.endIndex
                    }
                    continue
                }

                guard let lt = line[cursor...].firstIndex(of: "<") else {
                    appendText(line[cursor...])
                    cursor = line.endIndex
                    break
                }
                appendText(line[cursor..<lt])
                cursor = lt

                if line[cursor...].hasPrefix("<!--") {
                    if let end = HTMLTagSyntax.commentEnd(atStartOf: line[cursor...]) {
                        cursor = end
                    } else {
                        inComment = true
                        cursor = line.endIndex
                    }
                    continue
                }

                guard let tag = HTMLTagSyntax.tag(atStartOf: line[cursor...]) else {
                    appendText("<"[...])
                    cursor = line.index(after: cursor)
                    continue
                }
                let tagEnd = tag.end
                cursor = tagEnd

                switch tag.name {
                case "table":
                    if tag.isClosing {
                        depth -= 1
                        if depth == 0 {
                            endIndex = lineIndex + 1
                            break lineLoop
                        }
                    } else {
                        if depth > 0 { return nil }   // nested table
                        depth = 1
                    }
                case "thead":
                    inThead = !tag.isClosing
                case "tbody", "tfoot":
                    // An explicit body implicitly ends the header section, as in HTML.
                    if !tag.isClosing { inThead = false }
                case "tr":
                    if tag.isClosing {
                        closeRow()
                    } else {
                        closeRow()
                        row = Row(isHeader: inThead)
                    }
                case "td", "th":
                    if tag.isClosing {
                        closeCell()
                    } else {
                        closeCell()
                        if row == nil { row = Row(isHeader: inThead) }
                        if tag.name == "th" { row?.isHeader = true }
                        cell = Cell(alignment: alignment(from: tag.attributes))
                    }
                case "caption":
                    inCaption = !tag.isClosing
                case "img", "script", "style":
                    return nil
                case "col", "colgroup", "hr":
                    break
                case "br", "p", "div", "center":
                    appendSpace()
                case "span":
                    // Inline wrapper: transparent, no boundary space.
                    break
                default:
                    // Keep inline markup for `renderInline` (`<a>`, `<em>`, …).
                    appendText(line[lt..<tagEnd])
                }
            }
            appendSpace()   // a source line break is whitespace inside a cell
        }

        guard let tableEnd = endIndex else { return nil }
        closeRow()
        guard !rows.isEmpty else { return nil }

        var body = rows
        let headerRow = body.firstIndex(where: { $0.isHeader }).map { body[$0] }
        if let headerIndex = body.firstIndex(where: { $0.isHeader }) {
            body.remove(at: headerIndex)
        }
        let columnCount = max(headerRow?.cells.count ?? 0, body.map { $0.cells.count }.max() ?? 0)
        guard columnCount > 0 else { return nil }

        let headers = padded(headerRow?.cells.map(clean) ?? [], to: columnCount)
        let data = body.map { padded($0.cells.map(clean), to: columnCount) }

        let alignmentRows = ([headerRow].compactMap { $0 } + body)
        let alignments = (0..<columnCount).map { column -> Alignment in
            for candidate in alignmentRows where column < candidate.cells.count {
                if let alignment = candidate.cells[column].alignment { return alignment }
            }
            return .leading
        }

        let captionText = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return Table(headers: headers, rows: data, alignments: alignments,
                     caption: captionText.isEmpty ? nil : captionText, endIndex: tableEnd)
    }

    /// A table has to start at the beginning of its line (up to three leading
    /// spaces, like the other block constructs) with an opening `<table>` tag.
    /// The name is checked before the full tag parse: the parser calls this for
    /// EVERY line, and a multi-megabyte line starting with another tag must not
    /// be scanned twice.
    private static func isTableStart(_ line: String) -> Bool {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " ", indent < 4 {
            indent += 1
            index = line.index(after: index)
        }
        guard indent <= 3, index < line.endIndex else { return false }
        let rest = line[index...]
        guard rest.prefix(6).lowercased() == "<table" else { return false }
        let afterName = rest.index(rest.startIndex, offsetBy: 6, limitedBy: rest.endIndex) ?? rest.endIndex
        if afterName < rest.endIndex {
            let next = rest[afterName]
            guard next == " " || next == "\t" || next == ">" || next == "/" else { return false }
        }
        guard let tag = HTMLTagSyntax.tag(atStartOf: rest) else { return false }
        return !tag.isClosing && !tag.isSelfClosing
    }

    private static func clean(_ cell: Cell) -> String {
        cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }

    private static func alignment(from attributes: [String: String]) -> Alignment? {
        if let align = attributes["align"]?.trimmingCharacters(in: .whitespaces).lowercased() {
            switch align {
            case "center": return .center
            case "right", "end": return .trailing
            case "left", "start": return .leading
            default: break
            }
        }
        guard let style = attributes["style"]?.lowercased(),
              let keyword = style.range(of: "text-align") else { return nil }
        var value = style[keyword.upperBound...]
        value = value.drop(while: { $0 == " " || $0 == "\t" })
        guard value.first == ":" else { return nil }
        value = value.dropFirst()
        value = value.drop(while: { $0 == " " || $0 == "\t" })
        let name = value.prefix(while: { $0.isLetter })
        switch name.lowercased() {
        case "center": return .center
        case "right", "end": return .trailing
        case "left", "start": return .leading
        default: return nil
        }
    }
}
