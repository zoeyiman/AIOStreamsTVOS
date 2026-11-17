import UIKit

/**
 * A web link the page opened (Donate, About's links and credits, Account's configuration page, any
 * other), as a QR code for a phone's camera and as text: a TV has no browser to open it in. Menu or
 * Done closes it.
 */
final class LinkScreen: UIViewController {
    /// The screen has closed, however it was.
    var closed: () -> Void = {}

    private let url: URL
    private let done = UIButton(type: .system)

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.85)

        let title = UILabel()
        title.text = "Open on your phone"
        title.font = .systemFont(ofSize: 48, weight: .bold)
        title.textColor = .white

        let qr = UIImageView(image: QRCode.image(for: url.absoluteString, size: Self.codeSize))
        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        qr.backgroundColor = .white
        qr.layer.cornerRadius = 12
        qr.clipsToBounds = true

        let address = UILabel()
        address.text = url.absoluteString
        address.font = .monospacedSystemFont(ofSize: 30, weight: .medium)
        address.textColor = .white
        address.textAlignment = .center
        address.numberOfLines = 2
        address.lineBreakMode = .byCharWrapping
        address.adjustsFontSizeToFitWidth = true
        address.minimumScaleFactor = 0.5

        let note = UILabel()
        note.text = "Scan the code with your phone's camera to open this link there, or type the address."
        note.font = .systemFont(ofSize: 26)
        note.textColor = UIColor(white: 0.75, alpha: 1)
        note.numberOfLines = 0
        note.textAlignment = .center

        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [title, qr, address, note, done])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 32
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            column.widthAnchor.constraint(equalToConstant: 1100),
            qr.widthAnchor.constraint(equalToConstant: Self.codeSize),
            qr.heightAnchor.constraint(equalToConstant: Self.codeSize),
            address.widthAnchor.constraint(equalTo: column.widthAnchor),
            note.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [done] }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        closed()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private static let codeSize: CGFloat = 420
}
