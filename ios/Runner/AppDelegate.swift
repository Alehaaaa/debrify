import AVFoundation
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

  // MARK: Audio ownership
  //
  // The player must OWN the device's audio while it plays: pause the user's
  // music, and be the app iOS lists in Now Playing (iOS only shows an app
  // whose session is not mixable). mpv's audio output used to take that by
  // itself, but the ambient trailer / reel engine (`video_player` with
  // mixWithOthers) switches the app-wide session to playback+mixWithOthers
  // and never switches it back — after any trailer, the film played OVER the
  // music and never reached Now Playing.
  //
  // So the player claims the session explicitly when it starts playing, and
  // on close restores whatever the app had before (a muted trailer still on
  // screen behind the player must stay mixable and silent), then deactivates
  // with notifyOthers so the music the user was listening to resumes.
  private var ownsAudio = false
  private var savedCategory: AVAudioSession.Category?
  private var savedMode: AVAudioSession.Mode?
  private var savedOptions: AVAudioSession.CategoryOptions = []
  private var interruptionObserver: NSObjectProtocol?

  private func claimAudio() {
    let session = AVAudioSession.sharedInstance()
    let exclusive = session.category == .playback && session.mode == .moviePlayback
      && !session.categoryOptions.contains(.mixWithOthers)
      && !session.categoryOptions.contains(.duckOthers)
    if ownsAudio && exclusive { return }
    if !ownsAudio {
      savedCategory = session.category
      savedMode = session.mode
      savedOptions = session.categoryOptions
    }
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
      ownsAudio = true
    } catch {
      NSLog("NowPlaying: could not claim the audio session: \(error)")
    }
    if interruptionObserver == nil {
      // A call, Siri or another app starting audio takes the session away:
      // pause like every media app does rather than play on unheard.
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: session, queue: .main
      ) { [weak self] note in
        guard let self, self.ownsAudio,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        self.send("pause")
      }
    }
  }

  private func releaseAudio() {
    guard ownsAudio else { return }
    ownsAudio = false
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
    if let category = savedCategory {
      try? session.setCategory(category, mode: savedMode ?? .default, options: savedOptions)
    }
    savedCategory = nil
    savedMode = nil
    savedOptions = []
  }

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
    if playing == true { claimAudio() }
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
    releaseAudio()
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

// MARK: - System volume (the player's volume swipe)

/// Reads and sets the DEVICE volume for the player's right-side swipe, the
/// same way the left side sets screen brightness. iOS has no public setter:
/// the supported route is MPVolumeView's slider. Keeping that (invisible)
/// view in the window is also what stops iOS drawing its own volume HUD over
/// the player's.
private final class SystemVolumeBridge {
  private var volumeView: MPVolumeView?

  func install(
    on messenger: FlutterBinaryMessenger,
    controller: @escaping () -> UIViewController?
  ) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "debrify/system_volume", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "get":
        result(Double(AVAudioSession.sharedInstance().outputVolume))
      case "set":
        let args = call.arguments as? [String: Any]
        let value = min(max((args?["value"] as? NSNumber)?.floatValue ?? 0, 0), 1)
        self.set(value, host: controller()?.view)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private func slider(host: UIView?) -> UISlider? {
    if volumeView == nil, let host {
      // On screen but out of sight: a hidden or alpha-0 view stops working
      // (and lets the system HUD back in), so park it just off the corner.
      let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
      view.alpha = 0.01
      view.isUserInteractionEnabled = false
      host.addSubview(view)
      volumeView = view
    }
    return volumeView?.subviews.compactMap { $0 as? UISlider }.first
  }

  private func set(_ value: Float, host: UIView?) {
    guard let slider = slider(host: host) else { return }
    // The slider lays out lazily; a value set before that is dropped.
    DispatchQueue.main.async {
      slider.setValue(value, animated: false)
      slider.sendActions(for: .valueChanged)
    }
  }
}

/// Uses the official public clip URL rather than a temporary playback stream.
private final class ReelShareBridge {
  private var pendingResult: FlutterResult?

  func install(
    on messenger: FlutterBinaryMessenger,
    controller: @escaping () -> UIViewController?
  ) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "debrify/reel_share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "share" else { result(FlutterMethodNotImplemented); return }
      guard let self, self.pendingResult == nil,
            let args = call.arguments as? [String: Any],
            let value = args["url"] as? String,
            let url = URL(string: value), url.scheme == "https", url.host == "youtu.be",
            let sourceController = controller(),
            let sourceView = sourceController.view, sourceView.window != nil else {
        result(false)
        return
      }
      var presenter = sourceController
      while let presented = presenter.presentedViewController { presenter = presented }
      let caption = args["text"] as? String ?? ""
      let share = UIActivityViewController(activityItems: [caption, url], applicationActivities: nil)
      if let title = args["title"] as? String { share.setValue(title, forKey: "subject") }
      if let popover = share.popoverPresentationController {
        popover.sourceView = sourceView
        let center = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        var anchor = center
        if let origin = args["origin"] as? [String: NSNumber],
           let x = origin["x"], let y = origin["y"],
           let width = origin["width"], let height = origin["height"] {
          let candidate = CGRect(x: x.doubleValue, y: y.doubleValue,
                                 width: width.doubleValue, height: height.doubleValue)
            .intersection(sourceView.bounds)
          if !candidate.isNull && !candidate.isEmpty { anchor = candidate }
        }
        popover.sourceRect = anchor
        popover.permittedArrowDirections = args["origin"] == nil ? [] : .any
      }
      self.pendingResult = result
      share.completionWithItemsHandler = { [weak self] _, _, _, _ in
        let reply = self?.pendingResult
        self?.pendingResult = nil
        // Cancellation is handled too: do not open a fallback after dismissal.
        reply?(true)
      }
      presenter.present(share, animated: true)
    }
    return channel
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
  private let reelShare = ReelShareBridge()
  private var reelShareChannel: FlutterMethodChannel?
  private let systemVolume = SystemVolumeBridge()
  private var systemVolumeChannel: FlutterMethodChannel?
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
      reelShareChannel = reelShare.install(on: registrar.messenger()) { registrar.viewController }
      systemVolumeChannel = systemVolume.install(on: registrar.messenger()) { registrar.viewController }
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
