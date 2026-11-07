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

/// Converts a practical HTML subset to Markdown syntax understood by the
/// existing block and inline renderers. Unsupported tags remain untouched.
enum HTMLMarkdownConverter {

    struct Output {
        let lines: [String]
        let sourceLines: [Int]
        let htmlTables: [String: [[HTMLTableCell]]]
    }

    private struct Tag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: [String: String]
        let end: Int
    }

    private struct TableCell {
        var text: String
        let alignment: String?
        let isHeader: Bool
        var images: [HTMLTableImage]
    }

    private struct TableState {
        let sourceLine: Int
        var rows: [[TableCell]] = []
        var row: [TableCell] = []
        var cell = ""
        var cellAlignment: String?
        var cellIsHeader = false
        var cellImages: [HTMLTableImage] = []
        var inCell = false
    }

    private struct Builder {
        var lines: [String] = []
        var sourceLines: [Int] = []
        var current = ""
        var currentSource: Int?

        mutating func append(_ text: String, sourceLine: Int) {
            for character in text {
                if character == "\n" {
                    flush(sourceLine: sourceLine)
                } else {
                    if currentSource == nil { currentSource = sourceLine }
                    current.append(character)
                }
            }
        }

        mutating func flush(sourceLine: Int) {
            lines.append(current)
            sourceLines.append(currentSource ?? sourceLine)
            current = ""
            currentSource = nil
        }

        mutating func finish(sourceLine: Int) {
            if !current.isEmpty || lines.isEmpty { flush(sourceLine: sourceLine) }
        }
    }

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "nav", "center",
    ]
    private static let voidTags: Set<String> = ["br", "hr", "img"]

    static func convert(lines: [String], sourceLines: [Int]) -> Output {
        var builder = Builder()
        var table: TableState?
        var links: [String?] = []
        var listCounters: [Int?] = []
        var mathContainers: [String] = []
        var htmlTables: [String: [[HTMLTableCell]]] = [:]
        var htmlTableIndex = 0
        var fence: (character: Character, length: Int)?
        var inDisplayMath = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let sourceLine = index < sourceLines.count ? sourceLines[index] : index
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let opening = fence {
                builder.append(line, sourceLine: sourceLine)
                builder.append("\n", sourceLine: sourceLine)
                if closesFence(trimmed, opening: opening) { fence = nil }
                index += 1
                continue
            }
            if let opening = fenceOpening(trimmed) {
                fence = opening
                builder.append(line, sourceLine: sourceLine)
                builder.append("\n", sourceLine: sourceLine)
                index += 1
                continue
            }
            if inDisplayMath {
                builder.append(line, sourceLine: sourceLine)
                builder.append("\n", sourceLine: sourceLine)
                if trimmed.contains("$$") { inDisplayMath = false }
                index += 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                inDisplayMath = !trimmed.dropFirst(2).contains("$$")
                builder.append(line, sourceLine: sourceLine)
                builder.append("\n", sourceLine: sourceLine)
                index += 1
                continue
            }

            // Existing scanner owns standalone image lines. Wrapper-only lines
            // remain no-ops except for table structure, which this converter
            // must retain until its rows are assembled.
            if table == nil,
               case .tags(let images, _)? = HTMLImageSyntax.scan(line[...]) {
                let isTableStructure = ["<table", "</table", "<tr", "</tr", "<td", "</td", "<th", "</th"]
                    .contains { trimmed.lowercased().contains($0) }
                if !images.isEmpty || !isTableStructure {
                    builder.append(line, sourceLine: sourceLine)
                    builder.append("\n", sourceLine: sourceLine)
                    index += 1
                    continue
                }
            }

            if trimmed.lowercased().hasPrefix("<svg") {
                var svgLines = [line]
                let svgSource = sourceLine
                let svgStartIndex = index
                while !svgLines.joined(separator: "\n").lowercased().contains("</svg>") && index + 1 < lines.count {
                    index += 1
                    svgLines.append(lines[index])
                }
                guard svgLines.joined(separator: "\n").lowercased().contains("</svg>") else {
                    for svgLine in svgLines {
                        builder.append(svgLine, sourceLine: svgSource)
                        builder.append("\n", sourceLine: svgSource)
                    }
                    index += 1
                    continue
                }
                builder.append("\n\n```svg\n", sourceLine: svgSource)
                for (offset, svgLine) in svgLines.enumerated() {
                    let mappedIndex = svgStartIndex + offset
                    let mappedLine = mappedIndex < sourceLines.count ? sourceLines[mappedIndex] : svgSource
                    builder.append(svgLine, sourceLine: mappedLine)
                    builder.append("\n", sourceLine: svgSource)
                }
                builder.append("```\n\n", sourceLine: svgSource)
                index += 1
                continue
            }

            let characters = Array(line)
            var output = ""
            var position = 0
            while position < characters.count {
                guard characters[position] == "<", let tag = parseTag(characters, at: position) else {
                    let character = String(characters[position])
                    if var activeTable = table, activeTable.inCell {
                        activeTable.cell += character
                        table = activeTable
                    } else {
                        output += character
                    }
                    position += 1
                    continue
                }
                position = tag.end

                if tag.name == "table" {
                    if tag.isClosing, let activeTable = table {
                        append(output, sourceLine: sourceLine, to: &builder)
                        var completedTable = activeTable
                        if completedTable.inCell {
                            completedTable.row.append(TableCell(
                                text: completedTable.cell.trimmingCharacters(in: .whitespacesAndNewlines),
                                alignment: completedTable.cellAlignment,
                                isHeader: completedTable.cellIsHeader,
                                images: completedTable.cellImages))
                        }
                        if !completedTable.row.isEmpty { completedTable.rows.append(completedTable.row) }
                        if completedTable.rows.flatMap({ $0 }).contains(where: { !$0.images.isEmpty }) {
                            let marker = "\u{001E}quickmd-html-table-\(htmlTableIndex)"
                            htmlTableIndex += 1
                            htmlTables[marker] = completedTable.rows.map { row in
                                row.map { cell in
                                    HTMLTableCell(text: HTMLImageSyntax.decodeEntities(cell.text),
                                                  alignment: tableAlignment(cell.alignment),
                                                  isHeader: cell.isHeader, images: cell.images)
                                }
                            }
                            builder.append("\n\n\(marker)\n\n", sourceLine: completedTable.sourceLine)
                        } else {
                            appendTable(completedTable, to: &builder)
                        }
                        table = nil
                    } else if !tag.isClosing, table == nil {
                        table = TableState(sourceLine: sourceLine)
                    }
                    continue
                }

                if var activeTable = table {
                    switch tag.name {
                    case "tr":
                        if !tag.isClosing, !activeTable.row.isEmpty {
                            activeTable.rows.append(activeTable.row)
                            activeTable.row = []
                        } else if tag.isClosing, !activeTable.row.isEmpty {
                            if activeTable.inCell {
                                activeTable.row.append(TableCell(
                                    text: activeTable.cell.trimmingCharacters(in: .whitespacesAndNewlines),
                                    alignment: activeTable.cellAlignment,
                                    isHeader: activeTable.cellIsHeader,
                                    images: activeTable.cellImages))
                                activeTable.cell = ""
                                activeTable.cellAlignment = nil
                                activeTable.cellIsHeader = false
                                activeTable.cellImages = []
                                activeTable.inCell = false
                            }
                            activeTable.rows.append(activeTable.row)
                            activeTable.row = []
                        }
                    case "th", "td":
                        if tag.isClosing, activeTable.inCell {
                            activeTable.row.append(TableCell(
                                text: activeTable.cell.trimmingCharacters(in: .whitespacesAndNewlines),
                                alignment: activeTable.cellAlignment,
                                isHeader: activeTable.cellIsHeader,
                                images: activeTable.cellImages))
                            activeTable.cell = ""
                            activeTable.cellAlignment = nil
                            activeTable.cellIsHeader = false
                            activeTable.cellImages = []
                            activeTable.inCell = false
                        } else if !tag.isClosing {
                            if activeTable.inCell {
                                activeTable.row.append(TableCell(
                                    text: activeTable.cell.trimmingCharacters(in: .whitespacesAndNewlines),
                                    alignment: activeTable.cellAlignment,
                                    isHeader: activeTable.cellIsHeader,
                                    images: activeTable.cellImages))
                            }
                            activeTable.cell = ""
                            activeTable.cellAlignment = tag.attributes["align"]?.lowercased()
                            activeTable.cellIsHeader = tag.name == "th"
                            activeTable.cellImages = []
                            activeTable.inCell = true
                        }
                    case "br":
                        if activeTable.inCell { activeTable.cell += "  " }
                    case "img":
                        if activeTable.inCell, let image = htmlTableImage(tag.attributes) {
                            activeTable.cellImages.append(image)
                        }
                    default:
                        if activeTable.inCell {
                            activeTable.cell += inlineMarker(for: tag, links: &links)
                        }
                    }
                    table = activeTable
                    continue
                }

                switch tag.name {
                case "b", "strong": output += tag.isClosing ? "**" : "**"
                case "i", "em": output += "*"
                case "s", "strike", "del": output += "~~"
                case "code": output += "`"
                case "span":
                    if tag.isClosing {
                        if mathContainers.last == "span" {
                            mathContainers.removeLast()
                            output += "$"
                        }
                    } else {
                        let classes = (tag.attributes["class"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                        if classes.contains("math") || classes.contains("math-inline") {
                            output += "$"
                            mathContainers.append("span")
                        }
                    }
                case "div":
                    if tag.isClosing, mathContainers.last == "div" {
                        mathContainers.removeLast()
                        output += "$$\n\n"
                    } else {
                        let classes = (tag.attributes["class"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                        if !tag.isClosing && (classes.contains("math") || classes.contains("math-display")) {
                            mathContainers.append("div")
                            output += "\n\n$$"
                        } else {
                            output += "\n\n"
                        }
                    }
                case "a":
                    if tag.isClosing {
                        if let destination = links.popLast() ?? nil {
                            output += "](<\(markdownDestination(destination))>)"
                        }
                    } else {
                        let destination = tag.attributes["href"].map(HTMLImageSyntax.decodeEntities)
                        links.append(destination)
                        if destination != nil { output += "[" }
                    }
                case "img":
                    if let source = tag.attributes["src"] {
                        let alt = tag.attributes["alt"] ?? ""
                        output += "![\(alt)](<\(markdownDestination(source))>)"
                    }
                case "br": output += "  \n"
                case "hr": output += "\n\n---\n\n"
                case "ul":
                    if tag.isClosing {
                        if !listCounters.isEmpty { listCounters.removeLast() }
                        output += "\n\n"
                    }
                    else { listCounters.append(nil); output += "\n" }
                case "ol":
                    if tag.isClosing {
                        if !listCounters.isEmpty { listCounters.removeLast() }
                        output += "\n\n"
                    }
                    else { listCounters.append(1); output += "\n" }
                case "li":
                    if !tag.isClosing {
                        let indent = String(repeating: "  ", count: max(listCounters.count - 1, 0))
                        if let last = listCounters.indices.last, let number = listCounters[last] {
                            output += "\n\(indent)\(number). "
                            listCounters[last] = number + 1
                        } else {
                            output += "\n\(indent)- "
                        }
                    }
                case "blockquote": output += tag.isClosing ? "\n\n" : "\n\n> "
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if tag.isClosing { output += "\n\n" }
                    else { output += "\n\n\(String(repeating: "#", count: Int(tag.name.dropFirst()) ?? 1)) " }
                default:
                    if blockTags.contains(tag.name) { output += "\n\n" }
                }
                if tag.isSelfClosing && !voidTags.contains(tag.name) {
                    output += inlineMarker(for: tag, links: &links)
                }
            }
            append(output, sourceLine: sourceLine, to: &builder)
            builder.append("\n", sourceLine: sourceLine)
            index += 1
        }

        let fallbackSource = sourceLines.last ?? 0
        builder.finish(sourceLine: fallbackSource)
        return Output(lines: builder.lines, sourceLines: builder.sourceLines, htmlTables: htmlTables)
    }

    private static func append(_ text: String, sourceLine: Int, to builder: inout Builder) {
        builder.append(text, sourceLine: sourceLine)
    }

    private static func appendTable(_ table: TableState, to builder: inout Builder) {
        guard let headers = table.rows.first, !headers.isEmpty else { return }
        builder.append("\n\n", sourceLine: table.sourceLine)
        builder.flush(sourceLine: table.sourceLine)
        let headerCells = headers.map { escapePipe(HTMLImageSyntax.decodeEntities($0.text)) }
        let separator = headers.map { cell in
            switch cell.alignment {
            case "center": return ":---:"
            case "right": return "---:"
            default: return "---"
            }
        }
        builder.append("| " + headerCells.joined(separator: " | ") + " |\n", sourceLine: table.sourceLine)
        builder.append("| " + separator.joined(separator: " | ") + " |\n", sourceLine: table.sourceLine)
        for row in table.rows.dropFirst() {
            let cells = row.map { escapePipe(HTMLImageSyntax.decodeEntities($0.text)) }
            builder.append("| " + cells.joined(separator: " | ") + " |\n", sourceLine: table.sourceLine)
        }
        builder.append("\n", sourceLine: table.sourceLine)
    }

    private static func escapePipe(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func htmlTableImage(_ attributes: [String: String]) -> HTMLTableImage? {
        guard let source = attributes["src"], !source.isEmpty else { return nil }
        return HTMLTableImage(url: HTMLImageSyntax.decodeEntities(source),
                              alt: HTMLImageSyntax.decodeEntities(attributes["alt"] ?? ""),
                              width: attributes["width"].flatMap(HTMLImageSyntax.width(from:)))
    }

    private static func tableAlignment(_ value: String?) -> HTMLTableAlignment {
        switch value {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private static func inlineMarker(for tag: Tag, links: inout [String?]) -> String {
        switch tag.name {
        case "b", "strong": return "**"
        case "i", "em": return "*"
        case "s", "strike", "del": return "~~"
        case "code": return "`"
        case "a":
            if tag.isClosing {
                guard let destination = links.popLast() ?? nil else { return "" }
                return "](<\(markdownDestination(destination))>)"
            }
            let destination = tag.attributes["href"].map(HTMLImageSyntax.decodeEntities)
            links.append(destination)
            return destination == nil ? "" : "["
        default: return ""
        }
    }

    private static func markdownDestination(_ raw: String) -> String {
        HTMLImageSyntax.decodeEntities(raw)
            .replacingOccurrences(of: ">", with: "%3E")
    }

    private static func parseTag(_ characters: [Character], at start: Int) -> Tag? {
        var index = start + 1
        guard index < characters.count else { return nil }
        let isClosing = characters[index] == "/"
        if isClosing { index += 1 }
        let nameStart = index
        while index < characters.count,
              characters[index].isASCII,
              (characters[index].isLetter || characters[index].isNumber || characters[index] == "-") {
            index += 1
        }
        guard index > nameStart else { return nil }
        let name = String(characters[nameStart..<index]).lowercased()
        var attributes: [String: String] = [:]
        var isSelfClosing = false

        while index < characters.count {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return nil }
            if characters[index] == ">" {
                return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing,
                           attributes: attributes, end: index + 1)
            }
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == ">" {
                isSelfClosing = true
                return Tag(name: name, isClosing: isClosing, isSelfClosing: true,
                           attributes: attributes, end: index + 2)
            }
            let keyStart = index
            while index < characters.count,
                  characters[index].isASCII,
                  (characters[index].isLetter || characters[index].isNumber
                    || "_:-.".contains(characters[index])) {
                index += 1
            }
            guard index > keyStart else { return nil }
            let key = String(characters[keyStart..<index]).lowercased()
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            var value = ""
            if index < characters.count, characters[index] == "=" {
                index += 1
                while index < characters.count && characters[index].isWhitespace { index += 1 }
                guard index < characters.count else { return nil }
                let quote = characters[index] == "'" || characters[index] == "\"" ? characters[index] : nil
                if let quote {
                    index += 1
                    let valueStart = index
                    while index < characters.count && characters[index] != quote { index += 1 }
                    guard index < characters.count else { return nil }
                    value = String(characters[valueStart..<index])
                    index += 1
                } else {
                    let valueStart = index
                    while index < characters.count && !characters[index].isWhitespace && characters[index] != ">" { index += 1 }
                    value = String(characters[valueStart..<index])
                }
            }
            if attributes[key] == nil { attributes[key] = value }
        }
        return nil
    }

    private static func fenceOpening(_ line: String) -> (character: Character, length: Int)? {
        let text = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let character = text.first, character == "`" || character == "~" else { return nil }
        let length = text.prefix(while: { $0 == character }).count
        return length >= 3 ? (character, length) : nil
    }

    private static func closesFence(_ line: String, opening: (character: Character, length: Int)) -> Bool {
        let text = line.drop(while: { $0 == " " || $0 == "\t" })
        return text.prefix(while: { $0 == opening.character }).count >= opening.length
    }
}
