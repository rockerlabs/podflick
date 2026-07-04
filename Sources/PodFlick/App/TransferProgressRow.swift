import AppKit

/// The custom view for a background-transfer row in the status-bar menu: the
/// item title + stage on one line, with a slim determinate progress bar below
/// while the transfer is mid-flight (nil `progress` → no bar, e.g. a finished
/// row). A menu item with a `view` loses the default text and indent, so this
/// reproduces the menu font and left inset.
final class TransferProgressRow: NSView {
    init(title: String, label: String, progress: Double?) {
        // The width is advisory — the menu stretches every row to its own
        // width; only the height needs to be right for the row to size.
        super.init(frame: NSRect(x: 0, y: 0, width: 260,
                                 height: progress == nil ? 22 : 34))

        let text = NSTextField(labelWithString: "\(title) — \(label)")
        text.font = .menuFont(ofSize: 0)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])

        guard let progress else { return }
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = max(0, min(1, progress))
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
