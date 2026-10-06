import AppKit
import ColimaDomain
import ColimaFeatures
import SwiftUI

/// Virtualized, single-column log list backed by `NSTableView`. Only visible rows are realized.
struct LogTableView: NSViewRepresentable {
    let model: LogsViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CopyableTableView()
        table.headerView = nil
        table.usesAutomaticRowHeights = false
        table.rowHeight = Coordinator.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.gridStyleMask = []
        table.backgroundColor = .textBackgroundColor
        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copyHandler = { [weak coordinator = context.coordinator] rows in
            coordinator?.copy(rows: rows)
        }
        table.setAccessibilityLabel("Log lines")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        context.coordinator.attach(table: table, scrollView: scroll)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Reading these registers observation, so SwiftUI calls this method when they change.
        let revision = model.revision
        let showsTimestamps = model.showsTimestamps
        let filter = model.filterText
        context.coordinator.update(revision: revision, showsTimestamps: showsTimestamps, filter: filter)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("line")
        static let cellID = NSUserInterfaceItemIdentifier("cell")
        static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let rowHeight: CGFloat = 16

        private let model: LogsViewModel
        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private var lastRevision = -1
        private var showsTimestamps = true
        private var filter = ""

        init(model: LogsViewModel) {
            self.model = model
        }

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userDidScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
        }

        func update(revision: Int, showsTimestamps: Bool, filter: String) {
            guard let table else { return }
            let needsReload = revision != lastRevision || showsTimestamps != self.showsTimestamps || filter != self.filter
            lastRevision = revision
            self.showsTimestamps = showsTimestamps
            self.filter = filter
            guard needsReload else { return }
            table.reloadData()
            if model.isFollowing, table.numberOfRows > 0 {
                table.scrollRowToVisible(table.numberOfRows - 1)
            }
        }

        /// Scrolling up by hand pauses following, as in most log viewers.
        @objc private func userDidScroll() {
            guard model.isFollowing else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userDidEndScroll),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        @objc private func userDidEndScroll() {
            NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            guard let table, let scrollView else { return }
            let visible = scrollView.contentView.bounds
            let atBottom = visible.maxY >= table.bounds.maxY - Self.rowHeight
            if !atBottom { model.isFollowing = false }
        }

        func copy(rows: IndexSet) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.text(forRows: rows), forType: .string)
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LogCellView) ?? LogCellView(identifier: Self.cellID)
            if let entry = model.entry(atRow: row) {
                cell.label.attributedStringValue = attributedText(for: entry)
                cell.isMarker = entry.isMarker
            } else {
                cell.label.stringValue = ""
                cell.isMarker = false
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            nil
        }

        // MARK: Rendering

        private func attributedText(for entry: LogEntry) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let base: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
            if showsTimestamps, let timestamp = entry.line.timestamp {
                result.append(NSAttributedString(
                    string: Format.logTimestamp(timestamp) + "  ",
                    attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
                ))
            }
            if entry.isMarker {
                result.append(NSAttributedString(
                    string: "──── \(entry.line.text) ────",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
                ))
                return result
            }
            var attributes = base
            if entry.line.stream == .stderr {
                attributes[.foregroundColor] = NSColor.systemRed
            }
            let textStart = result.length
            result.append(NSAttributedString(string: entry.line.text, attributes: attributes))
            highlightMatches(in: result, from: textStart)
            return result
        }

        private func highlightMatches(in text: NSMutableAttributedString, from start: Int) {
            guard !filter.isEmpty else { return }
            let string = text.string as NSString
            var range = NSRange(location: start, length: string.length - start)
            while range.length > 0 {
                let found = string.range(of: filter, options: [.caseInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                text.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.6), range: found)
                let next = found.location + max(found.length, 1)
                range = NSRange(location: next, length: string.length - next)
            }
        }
    }
}

/// Table cell with one truncating label.
private final class LogCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    var isMarker = false {
        didSet {
            guard isMarker != oldValue else { return }
            layer?.backgroundColor = isMarker ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.allowsDefaultTighteningForTruncation = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Table view that copies selected rows with ⌘C.
private final class CopyableTableView: NSTableView {
    var copyHandler: ((IndexSet) -> Void)?

    @objc func copy(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty else { return }
        copyHandler?(selectedRowIndexes)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}
