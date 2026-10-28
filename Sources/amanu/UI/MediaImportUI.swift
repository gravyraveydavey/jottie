import AppKit

enum MediaImportPresentation {
    struct Copy: Equatable {
        let label: String
        let fraction: Double?
    }

    static func progress(_ update: MediaImportCoordinator.Update) -> Copy {
        let place = localised(
            "\(update.index) of \(update.total)",
            "\(update.index) из \(update.total)")
        let stage: String
        switch update.stage {
        case .checking: stage = localised("checking", "проверка")
        case .normalizing: stage = localised("converting", "конвертация")
        }
        return Copy(
            label: localised("Importing ", "Импорт ") + place + " · "
                + update.source.lastPathComponent + " · " + stage,
            fraction: update.fraction)
    }

    static func finished(_ result: MediaImportCoordinator.Result) -> Copy {
        if result.cancelled {
            return Copy(label: localised("Import cancelled", "Импорт остановлен"), fraction: nil)
        }
        var parts = [localised(
            "Imported \(result.imported.count)",
            "Импортировано: \(result.imported.count)")]
        let activeDuplicates = result.duplicates.filter { !$0.inTrash }.count
        let trashedDuplicates = result.duplicates.filter(\.inTrash).count
        if activeDuplicates > 0 {
            parts.append(localised(
                "\(activeDuplicates) already here",
                "уже было: \(activeDuplicates)"))
        }
        if trashedDuplicates > 0 {
            parts.append(localised(
                "\(trashedDuplicates) in Trash — restore there, or empty Trash to import again",
                "в корзине: \(trashedDuplicates) — восстановите запись или очистите корзину для повторного импорта"))
        }
        if !result.failures.isEmpty {
            parts.append(localised(
                "\(result.failures.count) failed",
                "ошибок: \(result.failures.count)"))
            let first = result.failures[0]
            let detail = first.source.lastPathComponent + ": " + first.message
            parts.append(result.failures.count == 1
                ? detail
                : detail + localised(
                    " (+\(result.failures.count - 1) more)",
                    " (+ещё \(result.failures.count - 1))"))
        }
        return Copy(label: parts.joined(separator: " · "), fraction: 1)
    }
}

/// A compact queue indicator shared by both windows. Unknown stages spin;
/// AVFoundation conversion uses a real fraction and a real progress bar.
@MainActor
final class MediaImportStatusView: NSStackView {
    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancel = NSButton(
        title: localised("Cancel", "Остановить"), target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        identifier = NSUserInterfaceItemIdentifier("media-import-progress")
        isHidden = true

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: 86).isActive = true
        cancel.bezelStyle = .inline
        cancel.controlSize = .small
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        addArrangedSubview(label)
        addArrangedSubview(bar)
        addArrangedSubview(cancel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ update: MediaImportCoordinator.Update) {
        let copy = MediaImportPresentation.progress(update)
        isHidden = false
        label.stringValue = copy.label
        cancel.isHidden = false
        bar.isHidden = false
        if let fraction = copy.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            bar.stopAnimation(nil)
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func finish(_ result: MediaImportCoordinator.Result) {
        let copy = MediaImportPresentation.finished(result)
        isHidden = false
        label.stringValue = copy.label
        cancel.isHidden = true
        bar.stopAnimation(nil)
        if let fraction = copy.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isHidden = true
        }
    }

    @objc private func cancelClicked() { onCancel?() }
}

/// A normal content container that additionally accepts Finder file drops.
/// Format validation belongs to AVFoundation in MediaNormalizer, so future
/// audio/video containers work without maintaining a brittle extension list.
@MainActor
final class MediaDropView: NSView {
    var onFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = !fileURLs(from: sender.draggingPasteboard).isEmpty
        layer?.borderColor = accepted ? NSColor.controlAccentColor.cgColor : nil
        layer?.borderWidth = accepted ? 2 : 0
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
    }
}
