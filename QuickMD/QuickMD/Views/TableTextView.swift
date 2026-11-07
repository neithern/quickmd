import SwiftUI
import AppKit

// MARK: - Table Block View (v1.13)

/// A markdown table as ONE read-only NSTextView over an `NSTextTable` (TS-D1),
/// replacing 1.12's SwiftUI grid of `Text` cells, so a table's text joins the
/// document selection like any other text row.
///
/// The string and its cell layout come from `TableTextBuilder` — normally the
/// very instance `BlockHeightMeasurer` laid out to size the row (`preconverted`,
/// v1.9 D12), which is why the row is `.exact`. The view adds only what a text
/// table cannot draw itself, all from `BlockLayout.Table`: the table background
/// and the rounded clip (`TableTextView.draw`), and the 1 pt outline — a SwiftUI
/// stroke overlay as in 1.12, centred on the edge so half of it lies outside the
/// view's frame, where an AppKit subview would be clipped.
struct TableTextBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let style: TableStyle
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    var searchText: String = ""
    var focusedOccurrence: Int? = nil
    /// The measurer's `TableText` for this block id. Used only when it was
    /// built from this block (ids are positional — see `TableText`); otherwise,
    /// or before the document was measured, the view builds its own.
    var preconverted: TableText? = nil
    let onLink: (URL) -> Void

    typealias Metrics = BlockLayout.Table

    var body: some View {
        // Nothing is built here: `body` runs on every search keystroke, focus
        // move and cell reuse. The representable builds (or adopts
        // `preconverted`) only when the text view's installed source differs.
        TableTextRepresentable(
            headers: headers,
            rows: rows,
            alignments: alignments,
            style: style,
            theme: theme,
            fontScale: fontScale,
            preconverted: preconverted,
            background: theme.backgroundColor,
            searchTerm: searchText,
            focusedOccurrence: focusedOccurrence,
            onLink: onLink
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
            .stroke(theme.borderColor, lineWidth: Metrics.borderWidth))
    }
}

struct HTMLTableBlockView: View {
    let rows: [[HTMLTableCell]]
    let theme: MarkdownTheme
    let documentURL: URL?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    let heightCache: BlockHeightCache
    let onEnlarge: (GraphicPreview) -> Void

    private let renderer: MarkdownRenderer
    private let cellPadding: CGFloat = 8

    typealias Metrics = BlockLayout.Table

    init(rows: [[HTMLTableCell]], theme: MarkdownTheme, documentURL: URL?, fontScale: CGFloat,
         contentWidth: CGFloat, heightCache: BlockHeightCache,
         onEnlarge: @escaping (GraphicPreview) -> Void) {
        self.rows = rows
        self.theme = theme
        self.documentURL = documentURL
        self.fontScale = fontScale
        self.contentWidth = contentWidth
        self.heightCache = heightCache
        self.onEnlarge = onEnlarge
        self.renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
    }

    var body: some View {
        let columnCount = max(rows.map(\.count).max() ?? 1, 1)
        let cellWidth = max((contentWidth - CGFloat(columnCount - 1)) / CGFloat(columnCount), 1)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        if column < row.count {
                            cellView(row[column], width: cellWidth)
                        } else {
                            emptyCell(width: cellWidth)
                        }
                    }
                }
                if rowIndex < rows.count - 1 {
                    Rectangle().fill(theme.borderColor).frame(height: 1)
                }
            }
        }
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
            .stroke(theme.borderColor, lineWidth: Metrics.borderWidth))
    }

    private func cellView(_ cell: HTMLTableCell, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !cell.text.isEmpty {
                Text(cellText(cell))
                    .multilineTextAlignment(textAlignment(cell.alignment))
                    .frame(maxWidth: .infinity, alignment: frameAlignment(cell.alignment))
            }
            ForEach(Array(cell.images.enumerated()), id: \.offset) { _, image in
                ImageBlockView(url: image.url, alt: image.alt, width: image.width,
                               theme: theme, documentURL: documentURL, fontScale: fontScale,
                               contentWidth: max(width - 2 * cellPadding, 1), heightCache: heightCache,
                               showsCaption: false, onEnlarge: onEnlarge)
            }
        }
        .padding(cellPadding)
        .frame(width: width, alignment: frameAlignment(cell.alignment))
        .background(cell.isHeader ? theme.headerBackgroundColor : theme.backgroundColor)
        .overlay(Rectangle().stroke(theme.borderColor.opacity(0.45), lineWidth: 0.5))
    }

    private func emptyCell(width: CGFloat) -> some View {
        Color.clear.frame(width: width).overlay(Rectangle().stroke(theme.borderColor.opacity(0.45), lineWidth: 0.5))
    }

    private func cellText(_ cell: HTMLTableCell) -> AttributedString {
        var text = renderer.renderInline(cell.text)
        if cell.isHeader { text.setDualFont(size: renderer.scaled(14), bold: true, fonts: theme.fonts) }
        return text
    }

    private func textAlignment(_ alignment: HTMLTableAlignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ alignment: HTMLTableAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - NSTextView Wrapper

private struct TableTextRepresentable: NSViewRepresentable {
    /// The cells' markdown — what the table is built from.
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let style: TableStyle
    let theme: MarkdownTheme
    let fontScale: CGFloat
    let preconverted: TableText?
    let background: Color
    let searchTerm: String
    let focusedOccurrence: Int?
    let onLink: (URL) -> Void

    func makeCoordinator() -> TextViewLinkDelegate { TextViewLinkDelegate(onLink: onLink) }

    func makeNSView(context: Context) -> TableTextView {
        let textView = TableTextView()
        textView.configureForSelfSizing()
        textView.installDocumentSelectionLayoutManager()
        textView.delegate = context.coordinator
        // Keep the renderer's link color/underline — only add the pointer cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TableTextView, context: Context) -> CGSize? {
        nsView.size(fitting: proposal)
    }

    func updateNSView(_ textView: TableTextView, context: Context) {
        context.coordinator.onLink = onLink

        // By value: `NSColor(Color)` is a fresh object per call.
        if textView.tableBackgroundSource != background {
            textView.tableBackgroundSource = background
            textView.tableBackground = NSColor(background)
            textView.needsDisplay = true
        }

        // At most one build per source per view: the measurer's instance when
        // it was built from exactly this source, otherwise our own.
        let source = TableText.Source(headers: headers, rows: rows, alignments: alignments, style: style,
                                      theme: theme, fontScale: fontScale)
        let textChanged = textView.tableSource != source
        if textChanged {
            let table = preconverted.flatMap { $0.source == source ? $0 : nil }
                ?? TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments, style: style,
                                          theme: theme, fontScale: fontScale)
            textView.textStorage?.setAttributedString(table.string)
            textView.cachedAttributed = table.string
            textView.tableLayout = table.layout
            textView.tableSource = table.source
            textView.invalidateMeasurement()
        }

        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            // The text rows' highlight on the whole table string: `DocumentSearch`
            // counted this block on the same characters with the same matcher
            // (TS-D9), so the focused occurrence is the n-th highlight in
            // reading order.
            // A focused match on a properties KEY (secondary colour) is drawn in
            // the text colour, as on a value.
            let keys = style == .properties ? textView.tableLayout?.firstColumnRanges : nil
            applyNSSearchHighlight(in: textView, term: searchTerm, focusedOccurrence: focusedOccurrence,
                                   focusedText: keys.map { (NSColor(theme.textColor), $0) })
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

        // As `BlockTextView`: the row's block id comes from the hosting cell's
        // environment, and the covered range is re-read after every string change.
        textView.attachSelection(context.environment.blockSelection)
    }

    static func dismantleNSView(_ textView: TableTextView, coordinator: TextViewLinkDelegate) {
        textView.detachSelection()
    }
}

// MARK: - Table Text View

/// `SelfSizingTextView` (sizing, refusing first responder, selection drawing,
/// AX — the whole text-row plumbing) with the three things that differ for a
/// table: the rounded clip + background, the height (`TableTextBuilder`'s,
/// not `usedRect`), and the cell-confined hit-test hook.
final class TableTextView: SelfSizingTextView {
    /// The cell layout of the installed string; set with it.
    var tableLayout: TableTextLayout?
    /// What the installed string was built from — the representable's rebuild key.
    var tableSource: TableText.Source?
    /// The table's own background (1.12 `.background(theme.backgroundColor)`),
    /// painted inside the rounded clip, and the theme colour it came from.
    var tableBackground: NSColor = .clear
    var tableBackgroundSource: Color?

    /// Everything — background, header band, rules, selection, search
    /// highlights, text — is clipped to the rounded rect (1.12 `.clipShape`).
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: BlockLayout.Table.cornerRadius,
                     yRadius: BlockLayout.Table.cornerRadius).addClip()
        tableBackground.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func layoutHeight(layoutManager: NSLayoutManager, container: NSTextContainer) -> CGFloat {
        TableTextBuilder.tableHeight(layoutManager: layoutManager, container: container)
    }

    override func selectionCharacterIndex(at point: NSPoint) -> Int {
        guard let tableLayout, tableLayout.length == selectionTextLength else {
            return super.selectionCharacterIndex(at: point)
        }
        return characterIndex(confinedToCellAt: point, layout: tableLayout)
    }
}
