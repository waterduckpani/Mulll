import UIKit
import UniformTypeIdentifiers

/// Triage in the share sheet, so nothing has to be sorted out later.
///
/// The old version was a dumb pipe: it queued the raw share, said "Saved to
/// Mull" and left the actual decisions for whenever the app was next opened —
/// by which point nobody remembers which of twenty screenshots was the one they
/// actually wanted. Now the reading happens here, on-device, and the only
/// things asked of the user are the two it cannot guess: is this a need or a
/// want, and is the price right.
///
/// Speed is still the whole point. Nothing blocks on the network, the OCR runs
/// on a downscaled copy, and a share the user abandons leaves nothing behind.
final class ShareViewController: UIViewController {
  /// One shared thing, as far as it has been worked out.
  private struct Draft {
    var name: String
    var price: Int?
    var isNeed: Bool
    var url: String?
    var image: UIImage?
    /// JPEG kept only so an untriaged draft can still be queued for the app.
    var imageData: Data?
  }

  private var drafts: [Draft] = []
  private let table = UITableView(frame: .zero, style: .plain)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let saveButton = UIButton(type: .system)

  /// Whatever the last share chose, so a browsing session is mostly one tap.
  /// Kept in the App Group rather than the extension's own defaults, which iOS
  /// is free to throw away whenever it unloads us.
  private static let lastKindKey = "mull.share.lastKindIsNeed"
  private static let defaults = UserDefaults(suiteName: MullInbox.appGroup) ?? .standard

  // ----------------------------------------------------------------- lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    buildInterface()
    ingest()
  }

  // --------------------------------------------------------------------- input

  private func ingest() {
    let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }

    guard !attachments.isEmpty else {
      finish(saved: false)
      return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    // Index-keyed so the order the user selected in Photos survives the
    // concurrent loads below.
    var found: [Int: Draft] = [:]
    var pageURL: String?

    for (index, provider) in attachments.enumerated() {
      group.enter()
      load(provider) { draft, url in
        lock.lock()
        if let draft { found[index] = draft }
        if let url { pageURL = url }
        lock.unlock()
        group.leave()
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      var drafts = found.sorted { $0.key < $1.key }.map(\.value)

      // Safari hands over the page URL and a preview image for the same page.
      // The image is the richer read, so it wins — but the link is still worth
      // keeping on it, since that is what "Open zara.com" will use later.
      if let pageURL, drafts.contains(where: { $0.image != nil }) {
        drafts = drafts.filter { $0.image != nil }
        if drafts.count == 1 { drafts[0].url = pageURL }
      }

      self.drafts = drafts
      self.didFinishReading()
    }
  }

  private func load(_ provider: NSItemProvider, completion: @escaping (Draft?, String?) -> Void) {
    let defaultIsNeed = Self.defaults.bool(forKey: Self.lastKindKey)

    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        guard let data, let image = UIImage(data: data) else {
          completion(nil, nil)
          return
        }
        // Full-resolution screenshots would put twenty of these in memory at
        // once; Vision does not need the pixels and the extension cannot
        // afford them.
        let small = image.mullDownscaled(maxDimension: 1600)
        guard let cgImage = small.cgImage else {
          completion(nil, nil)
          return
        }
        let guess = MullProductGuess.read(MullScreenshot.lines(cgImage, orientation: small.mullOrientation))
        completion(
          Draft(
            name: guess.name ?? "",
            price: guess.price,
            isNeed: defaultIsNeed,
            url: nil,
            image: small,
            imageData: small.jpegData(compressionQuality: 0.8)
          ),
          nil
        )
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
        guard let url = item as? URL, url.scheme?.hasPrefix("http") == true else {
          completion(nil, nil)
          return
        }
        // No title yet — reading the page would mean a network round trip the
        // share sheet cannot afford. Mull fills it in when it opens.
        completion(
          Draft(name: "", price: nil, isNeed: defaultIsNeed, url: url.absoluteString, image: nil, imageData: nil),
          url.absoluteString
        )
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
        guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
          completion(nil, nil)
          return
        }
        completion(
          Draft(name: text, price: nil, isNeed: defaultIsNeed, url: nil, image: nil, imageData: nil),
          nil
        )
      }
      return
    }

    completion(nil, nil)
  }

  private func didFinishReading() {
    spinner.stopAnimating()
    guard !drafts.isEmpty else {
      finish(saved: false)
      return
    }
    titleLabel.text = drafts.count == 1
      ? "Add this to Mull"
      : "Add \(drafts.count) things to Mull"
    saveButton.isHidden = false
    table.isHidden = false
    table.reloadData()
    updateSaveButton()
  }

  // ---------------------------------------------------------------------- save

  @objc private func save() {
    view.endEditing(true)

    let entries: [MullInbox.Entry] = drafts.compactMap { draft in
      let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
      // Everything answered — file it and the app adds it without asking.
      if !name.isEmpty, let price = draft.price, price > 0 {
        return .resolved(name: name, price: price, isNeed: draft.isNeed, url: draft.url)
      }
      // Something is still missing. Rather than drop it, hand the raw share
      // over and let Mull's own parser and add sheet finish the job.
      if let data = draft.imageData, let file = MullInbox.writeImage(data) {
        return .image(file: file)
      }
      if let url = draft.url { return .link(url: url) }
      return name.isEmpty ? nil : .text(name)
    }

    if let first = drafts.first {
      Self.defaults.set(first.isNeed, forKey: Self.lastKindKey)
    }
    finish(saved: MullInbox.append(entries))
  }

  @objc private func cancel() {
    // Nothing was written to the container, so backing out really does leave
    // no trace — images are only persisted at save.
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }

  private func updateSaveButton() {
    let ready = drafts.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.price ?? 0) > 0 }
    let title: String
    if drafts.count == 1 {
      title = ready.isEmpty ? "Save, sort later" : "Save it"
    } else if ready.count == drafts.count {
      title = "Save all \(drafts.count)"
    } else {
      title = "Save \(drafts.count) · \(ready.count) ready"
    }
    saveButton.setTitle(title, for: .normal)
  }

  private func finish(saved: Bool) {
    DispatchQueue.main.async {
      if saved { UINotificationFeedbackGenerator().notificationOccurred(.success) }
      self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
  }

  // ----------------------------------------------------------------- interface

  private func buildInterface() {
    view.backgroundColor = MullPalette.screen

    titleLabel.text = "Reading…"
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = MullPalette.ink3
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    let close = UIButton(type: .system)
    close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.tintColor = MullPalette.ink3
    close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    close.translatesAutoresizingMaskIntoConstraints = false

    spinner.color = MullPalette.ink3
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()

    table.backgroundColor = .clear
    table.separatorStyle = .none
    table.dataSource = self
    table.keyboardDismissMode = .interactive
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 168
    table.register(DraftCell.self, forCellReuseIdentifier: DraftCell.reuseID)
    table.isHidden = true
    table.translatesAutoresizingMaskIntoConstraints = false

    saveButton.backgroundColor = MullPalette.pill
    saveButton.setTitleColor(MullPalette.pillInk, for: .normal)
    saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
    saveButton.layer.cornerRadius = 28
    saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
    saveButton.isHidden = true
    saveButton.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(titleLabel)
    view.addSubview(close)
    view.addSubview(spinner)
    view.addSubview(table)
    view.addSubview(saveButton)

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 26),
      titleLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 18),

      close.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      close.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      close.widthAnchor.constraint(equalToConstant: 44),
      close.heightAnchor.constraint(equalToConstant: 44),

      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

      saveButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 22),
      saveButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -22),
      saveButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
      saveButton.heightAnchor.constraint(equalToConstant: 56),
    ])
  }
}

// ------------------------------------------------------------------ table data

extension ShareViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    drafts.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: DraftCell.reuseID, for: indexPath) as! DraftCell
    let draft = drafts[indexPath.row]
    cell.configure(name: draft.name, price: draft.price, isNeed: draft.isNeed, image: draft.image)
    cell.onChange = { [weak self] name, price, isNeed in
      guard let self, indexPath.row < drafts.count else { return }
      drafts[indexPath.row].name = name
      drafts[indexPath.row].price = price
      drafts[indexPath.row].isNeed = isNeed
      updateSaveButton()
    }
    return cell
  }
}

// ------------------------------------------------------------------------ cell

/// One shared thing: what we read, and the two answers only the user has.
private final class DraftCell: UITableViewCell {
  static let reuseID = "draft"

  var onChange: ((String, Int?, Bool) -> Void)?

  private let card = UIView()
  private let thumb = UIImageView()
  private let nameField = UITextField()
  private let priceField = UITextField()
  private let kind = UISegmentedControl(items: ["Need", "Want"])

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
    build()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A `cgColor` is resolved once, so the border would keep the appearance it
  /// was built in if the user flipped to dark mode mid-share.
  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    card.layer.borderColor = MullPalette.line.resolvedColor(with: traitCollection).cgColor
  }

  func configure(name: String, price: Int?, isNeed: Bool, image: UIImage?) {
    nameField.text = name
    priceField.text = price.map { "\($0)" } ?? ""
    kind.selectedSegmentIndex = isNeed ? 0 : 1
    thumb.image = image
    thumb.isHidden = image == nil
  }

  @objc private func changed() {
    let price = Int(priceField.text?.filter(\.isNumber) ?? "")
    onChange?(nameField.text ?? "", price, kind.selectedSegmentIndex == 0)
  }

  private func build() {
    card.backgroundColor = MullPalette.card
    card.layer.cornerRadius = 26
    card.layer.borderWidth = 1
    card.layer.borderColor = MullPalette.line.cgColor
    card.translatesAutoresizingMaskIntoConstraints = false

    thumb.contentMode = .scaleAspectFill
    thumb.clipsToBounds = true
    thumb.layer.cornerRadius = 12
    thumb.translatesAutoresizingMaskIntoConstraints = false

    style(nameField, placeholder: "What's it called?", size: 17)
    style(priceField, placeholder: "₹0", size: 17)
    priceField.keyboardType = .numberPad
    priceField.textAlignment = .right

    kind.selectedSegmentTintColor = MullPalette.pill
    kind.setTitleTextAttributes([.foregroundColor: MullPalette.pillInk], for: .selected)
    kind.setTitleTextAttributes([.foregroundColor: MullPalette.ink2], for: .normal)
    kind.addTarget(self, action: #selector(changed), for: .valueChanged)
    kind.translatesAutoresizingMaskIntoConstraints = false

    let fields = UIStackView(arrangedSubviews: [nameField, priceField])
    fields.axis = .horizontal
    fields.spacing = 12
    fields.alignment = .firstBaseline
    priceField.setContentHuggingPriority(.required, for: .horizontal)
    priceField.setContentCompressionResistancePriority(.required, for: .horizontal)

    let rule = UIView()
    rule.backgroundColor = MullPalette.line
    rule.translatesAutoresizingMaskIntoConstraints = false

    let column = UIStackView(arrangedSubviews: [fields, rule, kind])
    column.axis = .vertical
    column.spacing = 14
    column.setCustomSpacing(10, after: fields)
    column.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(card)
    card.addSubview(thumb)
    card.addSubview(column)

    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),

      thumb.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
      thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
      thumb.widthAnchor.constraint(equalToConstant: 52),
      thumb.heightAnchor.constraint(equalToConstant: 52),

      column.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
      column.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 14),
      column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
      column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),

      rule.heightAnchor.constraint(equalToConstant: 1),
      kind.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  private func style(_ field: UITextField, placeholder: String, size: CGFloat) {
    field.placeholder = placeholder
    field.font = .systemFont(ofSize: size)
    field.textColor = MullPalette.ink
    field.autocorrectionType = .no
    field.addTarget(self, action: #selector(changed), for: .editingChanged)
    field.translatesAutoresizingMaskIntoConstraints = false
  }
}

private extension UIImage {
  /// Longest edge capped, aspect kept. Vision reads a 1600px screenshot as
  /// well as a 3000px one and the extension has a fraction of the app's memory.
  func mullDownscaled(maxDimension: CGFloat) -> UIImage {
    let longest = max(size.width, size.height)
    guard longest > maxDimension else { return self }
    let scale = maxDimension / longest
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    return UIGraphicsImageRenderer(size: target).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }
}
