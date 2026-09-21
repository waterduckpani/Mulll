import Flutter
import UIKit
import UserNotifications

/// The native half of push: permission, the device token, the badge, and
/// which notification was tapped.
///
/// Deliberately thin. What a notification says is decided on the server (the
/// `push` edge function); what happens when one is tapped is decided in Dart.
/// This only moves the pieces iOS keeps to itself across the channel.
final class PushChannel {
  static let shared = PushChannel()

  private var channel: FlutterMethodChannel?
  private var token: String?

  /// The notification that opened the app, held until Dart asks for it. A tap
  /// that cold-launches Mull arrives before Dart is listening, so telling it
  /// once is not enough; Dart takes it when ready and it is cleared then.
  private var opened: [String: Any]?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mull/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "status":
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          DispatchQueue.main.async { result(Self.name(settings.authorizationStatus)) }
        }
      case "request":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
          DispatchQueue.main.async {
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            result(granted)
          }
        }
      case "register":
        // Apple's advice is to register on every launch: the token can change
        // (a restore, a reinstall) and nothing else says so.
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
      case "token":
        result(self.token.map { ["token": $0, "environment": Self.environment] })
      case "setBadge":
        Self.setBadge((call.arguments as? Int) ?? 0)
        result(nil)
      case "takeOpened":
        result(self.opened)
        self.opened = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func didRegister(_ deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    token = hex
    channel?.invokeMethod("token", arguments: ["token": hex, "environment": Self.environment])
  }

  func didOpen(_ userInfo: [AnyHashable: Any]) {
    var payload: [String: Any] = [:]
    for key in ["notice_id", "group_id", "kind"] {
      if let value = userInfo[key] as? String { payload[key] = value }
    }
    opened = payload
    channel?.invokeMethod("opened", arguments: nil)
  }

  static func setBadge(_ count: Int) {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    } else {
      UIApplication.shared.applicationIconBadgeNumber = max(0, count)
    }
  }

  private static func name(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "denied"
    }
  }

  /// Which APNs host this build's tokens belong to.
  ///
  /// A build signed for development (Xcode, `./install-phone.sh`) gets sandbox
  /// tokens; TestFlight and the App Store get production ones, and a token
  /// sent to the wrong host is refused as a bad token. The provisioning
  /// profile says which: development builds carry one with `aps-environment`
  /// set, and App Store builds carry none.
  static let environment: String = {
    #if targetEnvironment(simulator)
      return "sandbox"
    #else
      guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
        let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .isoLatin1),
        let key = text.range(of: "<key>aps-environment</key>")
      else { return "production" }
      let rest = text[key.upperBound...]
      guard let open = rest.range(of: "<string>"), let close = rest.range(of: "</string>") else {
        return "production"
      }
      return rest[open.upperBound..<close.lowerBound] == "development" ? "sandbox" : "production"
    #endif
  }()
}
