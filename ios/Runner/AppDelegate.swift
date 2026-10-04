import Flutter
import MediaPlayer
import UIKit
import CryptoKit
import Security

private enum DeviceSecretError: Error {
  case missing
  case unreadable
}

private final class DeviceSecretCipher {
  private let service = "com.debrify.app.profile-device-secret"
  private let account = "device-key-v1"

  func install(on messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "debrify/device_secret", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: nil, details: nil)); return }
      do {
        switch call.method {
        case "initialize":
          let args = call.arguments as? [String: Any]
          let allowCreate = args?["allowCreate"] as? Bool ?? true
          _ = try self.key(allowCreate: allowCreate)
          result(true)
        case "seal":
          let (input, aad) = try self.arguments(call)
          let box = try AES.GCM.seal(input, using: try self.key(allowCreate: false), authenticating: aad)
          guard let combined = box.combined else { throw NSError(domain: "DeviceSecret", code: 2) }
          result(combined.base64EncodedString())
        case "open":
          let (input, aad) = try self.arguments(call, payloadName: "envelope")
          let box = try AES.GCM.SealedBox(combined: input)
          result(try AES.GCM.open(box, using: try self.key(allowCreate: false), authenticating: aad).base64EncodedString())
        case "destroy": try self.destroy(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch DeviceSecretError.missing {
        result(FlutterError(code: "device_secret_missing", message: nil, details: nil))
      } catch DeviceSecretError.unreadable {
        result(FlutterError(code: "device_secret_unreadable", message: nil, details: nil))
      } catch CryptoKitError.authenticationFailure {
        result(FlutterError(code: "device_secret_record_unreadable", message: nil, details: nil))
      } catch {
        result(FlutterError(code: "device_secret_failed", message: error.localizedDescription, details: nil))
      }
    }
    return channel
  }

  private func destroy() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private func arguments(_ call: FlutterMethodCall, payloadName: String = "plaintext") throws -> (Data, Data) {
    guard let args = call.arguments as? [String: Any],
          let payload = args[payloadName] as? String,
          let input = Data(base64Encoded: payload),
          let aadText = args["associatedData"] as? String,
          let aad = Data(base64Encoded: aadText) else {
      throw NSError(domain: "DeviceSecret", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid channel arguments"])
    }
    return (input, aad)
  }

  private func key(allowCreate: Bool) throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess {
      guard let data = item as? Data, data.count == 32 else {
        throw DeviceSecretError.unreadable
      }
      return SymmetricKey(data: data)
    }
    guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    guard allowCreate else { throw DeviceSecretError.missing }
    var bytes = Data(count: 32)
    let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard randomStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(randomStatus)) }
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: bytes,
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
    return SymmetricKey(data: bytes)
  }
}

private final class ProfilePrivacyController {
  var sensitive = false
  private var cover: UIView?

  func install(on messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "com.debrify.app/profile_privacy", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setSensitive",
            let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented); return
      }
      self?.sensitive = args["sensitive"] as? Bool ?? false
      result(true)
    }
    return channel
  }

  func coverIfNeeded(_ window: UIWindow?) {
    guard sensitive, cover == nil, let window else { return }
    let view = UIView(frame: window.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.backgroundColor = .black
    window.addSubview(view)
    cover = view
  }

  func uncover() { cover?.removeFromSuperview(); cover = nil }
}

// MARK: - Now Playing (media keys, headset/AirPods, lock screen, Control Center)

/// The in-app player's Now Playing entry: title, poster and progress for the
/// system media controls, whose play/pause/skip/seek commands go back to Dart
/// over `debrify/media_session` as `command`. Fed by MediaSessionService.
private final class NowPlayingBridge {
  private var channel: FlutterMethodChannel?
  private var commandsInstalled = false
  private var info: [String: Any] = [:]
  private var title = ""
  private var subtitle: String?
  private var canNext = false
  private var canPrevious = false

  func install(on messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "debrify/media_session", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "update":
        self.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "clear":
        self.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    return channel
  }

  private func send(_ action: String, _ extra: [String: Any] = [:]) {
    var args = extra
    args["action"] = action
    DispatchQueue.main.async { self.channel?.invokeMethod("command", arguments: args) }
  }

  private func installCommands() {
    guard !commandsInstalled else { return }
    commandsInstalled = true
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in self?.send("play"); return .success }
    center.pauseCommand.addTarget { [weak self] _ in self?.send("pause"); return .success }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send("toggle"); return .success }
    center.stopCommand.addTarget { [weak self] _ in self?.send("pause"); return .success }
    center.nextTrackCommand.addTarget { [weak self] _ in self?.send("next"); return .success }
    center.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous"); return .success }
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipForwardCommand.addTarget { [weak self] event in
      let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
      self?.send("seekBy", ["offsetMs": Int(interval * 1000)])
      return .success
    }
    center.skipBackwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.addTarget { [weak self] event in
      let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
      self?.send("seekBy", ["offsetMs": -Int(interval * 1000)])
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.send("seek", ["positionMs": Int(event.positionTime * 1000)])
      return .success
    }
  }

  private func setCommandsEnabled(_ enabled: Bool) {
    let center = MPRemoteCommandCenter.shared()
    for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                    center.stopCommand, center.skipForwardCommand, center.skipBackwardCommand,
                    center.changePlaybackPositionCommand] {
      command.isEnabled = enabled
    }
    center.nextTrackCommand.isEnabled = enabled && canNext
    center.previousTrackCommand.isEnabled = enabled && canPrevious
  }

  private func update(_ args: [String: Any]) {
    installCommands()
    if let value = args["title"] as? String { title = value }
    if args.keys.contains("subtitle") { subtitle = args["subtitle"] as? String }
    if let value = args["canNext"] as? Bool { canNext = value }
    if let value = args["canPrevious"] as? Bool { canPrevious = value }
    info[MPMediaItemPropertyTitle] = title
    if let subtitle { info[MPMediaItemPropertyArtist] = subtitle } else { info.removeValue(forKey: MPMediaItemPropertyArtist) }
    info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
    if let ms = args["durationMs"] as? NSNumber {
      info[MPMediaItemPropertyPlaybackDuration] = ms.doubleValue / 1000
    }
    if let ms = args["positionMs"] as? NSNumber {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = ms.doubleValue / 1000
    }
    var playing: Bool?
    if let value = args["playing"] as? Bool {
      playing = value
      let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
      info[MPNowPlayingInfoPropertyPlaybackRate] = value ? rate : 0
      info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    }
    if args["clearArtwork"] as? Bool == true {
      info.removeValue(forKey: MPMediaItemPropertyArtwork)
    }
    if let data = (args["artwork"] as? FlutterStandardTypedData)?.data, let artwork = makeArtwork(data) {
      info[MPMediaItemPropertyArtwork] = artwork
    }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    #if os(macOS)
    if let playing { center.playbackState = playing ? .playing : .paused }
    #endif
    _ = playing
    setCommandsEnabled(true)
  }

  private func clear() {
    info = [:]
    title = ""
    subtitle = nil
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    #if os(macOS)
    center.playbackState = .stopped
    #endif
    if commandsInstalled { setCommandsEnabled(false) }
  }

  private func makeArtwork(_ data: Data) -> MPMediaItemArtwork? {
    #if os(macOS)
    guard let image = NSImage(data: data) else { return nil }
    #else
    guard let image = UIImage(data: data) else { return nil }
    #endif
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let deviceSecretCipher = DeviceSecretCipher()
  private let profilePrivacy = ProfilePrivacyController()
  private var deviceSecretChannel: FlutterMethodChannel?
  private var profilePrivacyChannel: FlutterMethodChannel?
  private let nowPlaying = NowPlayingBridge()
  private var nowPlayingChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = excludeDeviceBoundStateFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  @discardableResult
  private func excludeDeviceBoundStateFromBackup() -> Bool {
    let manager = FileManager.default
    var urls: [URL] = []
    if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      try? manager.createDirectory(at: support, withIntermediateDirectories: true)
      urls.append(support)
    }
    if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
      let profiles = documents.appendingPathComponent("profiles", isDirectory: true)
      try? manager.createDirectory(at: profiles, withIntermediateDirectories: true)
      urls.append(profiles)
    }
    if let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
      // Mark the container, not only today's plist. SharedPreferences can
      // create/replace its plist after didFinishLaunching; directory-level
      // exclusion covers that first write and future atomic replacements.
      let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
      try? manager.createDirectory(at: preferences, withIntermediateDirectories: true)
      urls.append(preferences)
    }
    var allExcluded = true
    for url in urls {
      guard manager.fileExists(atPath: url.path) else {
        allExcluded = false
        continue
      }
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        let verified = try mutable.resourceValues(forKeys: [.isExcludedFromBackupKey])
        allExcluded = allExcluded && verified.isExcludedFromBackup == true
      } catch {
        allExcluded = false
      }
    }
    return allExcluded
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DebrifyDeviceSecret") {
      deviceSecretChannel = deviceSecretCipher.install(on: registrar.messenger())
      profilePrivacyChannel = profilePrivacy.install(on: registrar.messenger())
      nowPlayingChannel = nowPlaying.install(on: registrar.messenger())
    }
  }


  override func applicationWillResignActive(_ application: UIApplication) {
    profilePrivacy.coverIfNeeded(window)
    super.applicationWillResignActive(application)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    // Re-assert after Flutter/plugins have created their containers. This is
    // idempotent and closes the clean-install timing window.
    _ = excludeDeviceBoundStateFromBackup()
    profilePrivacy.uncover()
    super.applicationDidBecomeActive(application)
  }
}
