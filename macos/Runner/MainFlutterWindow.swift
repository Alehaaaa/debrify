import Cocoa
import FlutterMacOS
import CryptoKit
import Security

private enum DeviceSecretError: Error {
  case missing
  case unreadable
}

private final class MacOsDeviceSecretCipher {
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
          let value = args[payloadName] as? String,
          let input = Data(base64Encoded: value),
          let aadValue = args["associatedData"] as? String,
          let aad = Data(base64Encoded: aadValue) else {
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
      kSecValueData as String: bytes,
    ]
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
    return SymmetricKey(data: bytes)
  }
}

private final class ReelShareBridge: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
  private var picker: NSSharingServicePicker?
  private var pendingResult: FlutterResult?
  private var title = ""

  func install(on messenger: FlutterBinaryMessenger, view: NSView) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: "debrify/reel_share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self, weak view] call, result in
      guard call.method == "share" else { result(FlutterMethodNotImplemented); return }
      guard let self, self.pendingResult == nil, let view, view.window != nil,
            let args = call.arguments as? [String: Any],
            let value = args["url"] as? String,
            let url = URL(string: value), url.scheme == "https" else {
        result(false)
        return
      }
      let center = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
      var anchor = center
      if let origin = args["origin"] as? [String: NSNumber],
         let x = origin["x"], let y = origin["y"],
         let width = origin["width"], let height = origin["height"] {
        // Flutter coordinates start at the top; an AppKit view may not.
        let top = CGFloat(y.doubleValue)
        let h = CGFloat(height.doubleValue)
        let nativeY = view.isFlipped ? top : view.bounds.maxY - top - h
        let candidate = NSRect(x: CGFloat(x.doubleValue), y: nativeY,
                               width: CGFloat(width.doubleValue), height: h)
          .intersection(view.bounds)
        if !candidate.isNull && !candidate.isEmpty { anchor = candidate }
      }
      self.title = args["title"] as? String ?? ""
      let caption = args["text"] as? String ?? ""
      let picker = NSSharingServicePicker(items: [caption, url])
      picker.delegate = self
      self.picker = picker
      self.pendingResult = result
      picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
    return channel
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                            didChoose service: NSSharingService?) {
    if service == nil { finish() }
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                            delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
    sharingService.subject = title
    return self
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }

  func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
    finish()
  }

  private func finish() {
    let reply = pendingResult
    pendingResult = nil
    picker = nil
    // A dismissed native share sheet should never open another sheet.
    reply?(true)
  }
}

class MainFlutterWindow: NSWindow {
  private var deviceSecretChannel: FlutterMethodChannel?
  private var profilePrivacyChannel: FlutterMethodChannel?
  private let deviceSecretCipher = MacOsDeviceSecretCipher()
  private let reelShare = ReelShareBridge()
  private var reelShareChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    deviceSecretChannel = deviceSecretCipher.install(on: flutterViewController.engine.binaryMessenger)
    reelShareChannel = reelShare.install(
      on: flutterViewController.engine.binaryMessenger,
      view: flutterViewController.view
    )
    profilePrivacyChannel = FlutterMethodChannel(
      name: "com.debrify.app/profile_privacy",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    profilePrivacyChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setSensitive",
            let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let sensitive = args["sensitive"] as? Bool ?? false
      self?.sharingType = sensitive ? .none : .readOnly
      result(true)
    }

    excludeDeviceBoundStateFromBackup()

    super.awakeFromNib()
  }

  private func excludeDeviceBoundStateFromBackup() {
    let manager = FileManager.default
    let roots = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    for root in roots {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutable = root
      try? mutable.setResourceValues(values)
    }
  }
}
