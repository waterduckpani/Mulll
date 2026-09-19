import UIKit
import UniformTypeIdentifiers

/// Share a UPI receipt into Mull and the debt it pays off settles itself.
///
/// This is the loop that makes "I already sent it" mean something. You pay Sahil
/// in GPay, share the confirmation screen here, and the claim reaches him
/// carrying the amount and the reference off the payment itself — so the person
/// owed is confirming evidence rather than taking your word for it.
///
/// The extension reads the screenshot but never decides anything. Vision runs
/// here because the share sheet has no Flutter engine and never will — the user
/// is two taps from the back button and waiting on us. What it reads is shown
/// back for confirmation; `UpiReceiptReader` in Dart, which has the test suite,
/// is what actually matches a receipt to a debt when Mull next opens.
final class ShareViewController: UIViewController {
  /// One shared screenshot, as far as it has been worked out.
  private struct Draft {
    var image: UIImage
    /// JPEG, written to the App Group only at save.
    var data: Data
    var guess: MullReceiptGuess.Result
  }

  private var drafts: [Draft] = []
  private let table = UITableView(frame: .zero, style: .plain)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let saveButton = UIButton(type: .system)

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

    for (index, provider) in attachments.enumerated() {
      group.enter()
      load(provider) { draft in
        lock.lock()
        if let draft { found[index] = draft }
        lock.unlock()
        group.leave()
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.drafts = found.sorted { $0.key < $1.key }.map(\.value)
      self.didFinishReading()
    }
  }

  private func load(_ provider: NSItemProvider, completion: @escaping (Draft?) -> Void) {
    // Only images now. A shared link or a line of text has nowhere to go in a
    // split app, and queueing one so Mull can silently drop it later is worse
    // than declining it here.
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      completion(nil)
      return
    }

    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
      guard let data, let image = UIImage(data: data) else {
        completion(nil)
        return
      }
      // Full-resolution screenshots would put several of these in memory at
      // once; Vision does not need the pixels and the extension cannot afford
      // them.
      let small = image.mullDownscaled(maxDimension: 1600)
      guard let cgImage = small.cgImage, let jpeg = small.jpegData(compressionQuality: 0.8) else {
        completion(nil)
        return
      }
      let guess = MullReceiptGuess.read(MullScreenshot.lines(cgImage, orientation: small.mullOrientation))
      completion(Draft(image: small, data: jpeg, guess: guess))
    }
  }

  private func didFinishReading() {
    spinner.stopAnimating()
    guard !drafts.isEmpty else {
      showNothingToDo()
      return
    }

    let payments = drafts.filter { $0.guess.looksLikePayment && !$0.guess.failed }
    titleLabel.text = drafts.count == 1 ? "Send this to Mull" : "Send \(drafts.count) to Mull"
    subtitleLabel.text = payments.isEmpty
      ? "Mull will check it against what you owe when you open it."
      : "Mull will match it to what you owe and record the payment."
    subtitleLabel.isHidden = false
    saveButton.isHidden = false
    table.isHidden = false
    table.reloadData()
    saveButton.setTitle(drafts.count == 1 ? "Send it" : "Send all \(drafts.count)", for: .normal)
  }

  /// Someone shared a link or a note. Say so rather than appearing to save it.
  private func showNothingToDo() {
    titleLabel.text = "Mull takes screenshots"
    subtitleLabel.text = "Share a UPI payment screen and Mull will settle the debt it pays off."
    subtitleLabel.isHidden = false
    saveButton.isHidden = true
  }

  // ---------------------------------------------------------------------- save

  @objc private func save() {
    let entries: [MullInbox.Entry] = drafts.compactMap { draft in
      guard let file = MullInbox.writeImage(draft.data) else { return nil }
      return .image(file: file)
    }
    finish(saved: MullInbox.append(entries))
  }

  @objc private func cancel() {
    // Nothing was written to the container, so backing out really does leave
    // no trace — images are only persisted at save.
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
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
    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textColor = MullPalette.ink
    titleLabel.numberOfLines = 2

    subtitleLabel.font = .systemFont(ofSize: 13)
    subtitleLabel.textColor = MullPalette.ink3
    subtitleLabel.numberOfLines = 3
    subtitleLabel.isHidden = true

    let cancelButton = UIButton(type: .system)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.setTitleColor(MullPalette.ink3, for: .normal)
    cancelButton.titleLabel?.font = .systemFont(ofSize: 15)
    cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

    saveButton.setTitleColor(MullPalette.pillInk, for: .normal)
    saveButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
    saveButton.backgroundColor = MullPalette.pill
    saveButton.layer.cornerRadius = 28
    saveButton.isHidden = true
    saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)

    table.dataSource = self
    table.separatorStyle = .none
    table.backgroundColor = .clear
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 96
    table.isHidden = true
    table.register(ReceiptCell.self, forCellReuseIdentifier: ReceiptCell.id)

    for subview in [titleLabel, subtitleLabel, cancelButton, saveButton, table, spinner] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    spinner.startAnimating()

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
      cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),

      titleLabel.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 18),
      titleLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
      titleLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      table.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
      table.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

      saveButton.heightAnchor.constraint(equalToConstant: 56),
      saveButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
      saveButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
      saveButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),

      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }
}

extension ShareViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { drafts.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: ReceiptCell.id, for: indexPath) as! ReceiptCell
    let draft = drafts[indexPath.row]
    cell.configure(image: draft.image, guess: draft.guess)
    return cell
  }
}

/// What Mull thinks it is looking at, with the screenshot beside it.
///
/// Nothing here is editable, and that is the point: this screen is not asking
/// the user to enter a payment, it is showing them what they shared so they can
/// tell at a glance that it is the right one. The numbers that matter are read
/// again, properly, inside the app.
private final class ReceiptCell: UITableViewCell {
  static let id = "receipt"

  private let card = UIView()
  private let thumb = UIImageView()
  private let amountLabel = UILabel()
  private let detailLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    card.backgroundColor = MullPalette.card
    card.layer.cornerRadius = 24
    card.layer.borderWidth = 1

    thumb.contentMode = .scaleAspectFill
    thumb.clipsToBounds = true
    thumb.layer.cornerRadius = 14

    amountLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    amountLabel.textColor = MullPalette.ink

    detailLabel.font = .systemFont(ofSize: 13)
    detailLabel.textColor = MullPalette.ink3
    detailLabel.numberOfLines = 2

    for subview in [card, thumb, amountLabel, detailLabel] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    contentView.addSubview(card)
    for subview in [thumb, amountLabel, detailLabel] {
      card.addSubview(subview)
    }

    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

      thumb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      thumb.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
      thumb.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14),
      thumb.widthAnchor.constraint(equalToConstant: 56),
      thumb.heightAnchor.constraint(equalToConstant: 72),

      amountLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 16),
      amountLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      amountLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),

      detailLabel.leadingAnchor.constraint(equalTo: amountLabel.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: amountLabel.trailingAnchor),
      detailLabel.topAnchor.constraint(equalTo: amountLabel.bottomAnchor, constant: 6),
      detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A `cgColor` is resolved once, so the border would keep the appearance it
  /// was first drawn in unless it is refreshed when the trait changes.
  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    card.layer.borderColor = MullPalette.line.resolvedColor(with: traitCollection).cgColor
  }

  func configure(image: UIImage, guess: MullReceiptGuess.Result) {
    thumb.image = image
    amountLabel.text = guess.amount.map { "₹\(grouped($0))" } ?? "Screenshot"

    if guess.failed {
      detailLabel.text = "This one says the payment did not go through."
    } else if let payee = guess.payee {
      detailLabel.text = "To \(payee)"
    } else if guess.hasReference {
      detailLabel.text = "Payment reference found"
    } else {
      detailLabel.text = "Mull will read this when you open it."
    }
  }

  /// Indian digit grouping: 1,24,600. Matches `inr()` in lib/core/money.dart.
  private func grouped(_ amount: Int) -> String {
    let digits = String(amount)
    guard digits.count > 3 else { return digits }
    let last3 = String(digits.suffix(3))
    var rest = String(digits.dropLast(3))
    var parts: [String] = []
    while rest.count > 2 {
      parts.insert(String(rest.suffix(2)), at: 0)
      rest = String(rest.dropLast(2))
    }
    if !rest.isEmpty { parts.insert(rest, at: 0) }
    return parts.joined(separator: ",") + "," + last3
  }
}
