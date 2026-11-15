import UIKit

/// Full-screen message with a way forward, shown when claude.ai can't be loaded or keeps stopping.
final class ErrorView: UIView {

    var onReload: (() -> Void)?
    var onOptions: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .appBackground

        titleLabel.font = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let reloadButton = UIButton(type: .system)
        reloadButton.setTitle("Reload", for: .normal)
        reloadButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReload?() }, for: .touchUpInside)

        let optionsButton = UIButton(type: .system)
        optionsButton.setTitle("Settings & Debug Log", for: .normal)
        optionsButton.setTitleColor(.secondaryLabel, for: .normal)
        optionsButton.addAction(UIAction { [weak self] _ in self?.onOptions?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, reloadButton, optionsButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(24, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: readableContentGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: readableContentGuide.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(title: String, message: String) {
        titleLabel.text = title
        messageLabel.text = message
        isHidden = false
    }
}
