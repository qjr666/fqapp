import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS 没有共享的 Downloads 目录，日志导出与分享走系统能力：文件落到
    // 应用的 Documents（开了文件共享后能在「文件」App 里看到），同时调起
    // 系统分享面板，用户可以存到「文件」、发给自己或放进任何一个 App。
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FqappIosExport") else {
      return
    }
    let messenger = registrar.messenger()
    DownloadsChannel(messenger: messenger).register()
    ShareChannel(messenger: messenger).register()
    LibraryBackupChannel(messenger: messenger).register()
  }
}

/// `fqapp/downloads`：把导出的文本写进应用目录，并调起系统分享面板。
final class DownloadsChannel {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fqapp/downloads", binaryMessenger: messenger)
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let fileName = args["fileName"] as? String,
        let text = args["text"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "缺少 fileName 或 text", details: nil))
        return
      }
      do {
        let url = try DownloadsChannel.write(fileName: fileName, text: text)
        result([
          "path": url.path,
          "public": false,
          "hint": "到系统分享面板（文件同时存在「文件」App 的 什锦铺 目录）",
        ])
        DownloadsChannel.presentShareSheet(items: [url])
      } catch {
        result(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
      }
    }
  }

  /// 写进 `Documents/exports`：iOS 上没有共享的 Downloads 目录，
  /// Documents 开了文件共享开关后能在「文件」App 里看到。
  static func write(fileName: String, text: String) throws -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let directory = documents.appendingPathComponent("exports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safe = fileName
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let target = directory.appendingPathComponent(safe)
    try text.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  static func presentShareSheet(items: [Any]) {
    guard let presenter = topViewController() else { return }
    let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: true)
  }
}

/// `fqapp/share`：分享一段文本。
final class ShareChannel {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fqapp/share", binaryMessenger: messenger)
  }

  func register() {
    channel.setMethodCallHandler { call, result in
      guard call.method == "shareText" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let text = args?["text"] as? String ?? ""
      guard !text.isEmpty else {
        result(false)
        return
      }
      guard topViewController() != nil else {
        result(false)
        return
      }
      DownloadsChannel.presentShareSheet(items: [text])
      result(true)
    }
  }
}

/// 当前最上面的视图控制器：分享面板要从它弹出来。
func topViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let windows = scenes.flatMap { $0.windows }
  let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
  var top = window?.rootViewController
  while let presented = top?.presentedViewController {
    top = presented
  }
  return top
}

/// `fqapp/library_backup`：系统文件选择器（导入/导出备份）与应用私有采集文件。
///
/// Android 用 `ACTION_CREATE_DOCUMENT` / `ACTION_OPEN_DOCUMENT`，iOS 没有
/// 对应的 Intent，这里用 `UIDocumentPickerViewController` 对齐同一套通道契约：
/// 打开模式回传文件内容，导出模式让用户自己挑一个保存位置（通常是「文件」App）。
///
/// 通道在 Android 与桌面端都有实现；这里补上 iOS，否则导入/导出会因为找不到
/// 处理器而退化成「当前运行环境不支持系统文件选择器」。
final class LibraryBackupChannel: NSObject, UIDocumentPickerDelegate {
  /// 与 Android 端一致的备份体积上限：16 MB。
  private static let maxBytes = 16 * 1024 * 1024
  /// 分卷文件名必须是这个形状，读回来时才知道没有越出采集目录。
  private static let partPattern = "^part-[0-9]+-[a-fA-F0-9-]+\\.json$"
  /// 导出文件名由调用方给出，必须是普通文件名，不能带路径分隔符。
  private static let safeNamePattern = "^[a-zA-Z0-9_.-]{1,100}$"

  /// 一次只处理一个文件操作：系统选择器是模态的，并发会互相顶掉。
  private enum Job {
    /// 打开一个文件，把内容读回来。
    case open
    /// 把一段内容交给用户保存。
    case save(Data, String)
    /// 采集分卷导出：iOS 没有系统 zip API，交回 Dart 用纯 Dart 压缩后
    /// 再走 `saveBackup`，这里只负责给出明确的 unsupported 答复。
    case exportZip
  }

  private let channel: FlutterMethodChannel
  private var pendingResult: FlutterResult?
  private var pendingJob: Job?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fqapp/library_backup", binaryMessenger: messenger)
    super.init()
  }

  func register() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        // The channel outlives the handler only if the app is tearing down;
        // answering keeps the Dart side from waiting forever.
        result(FlutterError(code: "no_channel", message: "通道已释放", details: nil))
        return
      }
      self.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "hasPicker":
      // 能力探测：这个平台有没有系统文件选择器。
      result(true)
    case "openBackup":
      begin(.open, result)
    case "saveBackup":
      guard let data = byteArgument(args, "bytes") else {
        result(FlutterError(code: "bad_args", message: "缺少备份内容", details: nil))
        return
      }
      begin(.save(data, exportName(args, fallback: "fqapp-backup.json")), result)
    case "exportFanqieCapture":
      // 打包交给 Dart 的 `archive`：iOS 没有公开的 FileManager.zipItem，
      // 直接回一个契约里约定好的错误，Dart 会把 zip 字节通过 saveBackup
      // 再送回来，用系统选择器导出。
      begin(.exportZip, result)
    case "storeFanqieCapture":
      guard let data = byteArgument(args, "bytes") else {
        result(FlutterError(code: "bad_args", message: "缺少采集内容", details: nil))
        return
      }
      storeCapture(data, result)
    case "storeFanqieCapturePart":
      guard let data = byteArgument(args, "bytes") else {
        result(FlutterError(code: "bad_args", message: "缺少分卷内容", details: nil))
        return
      }
      storeCapturePart(data, result)
    case "latestFanqieCapture":
      latestCapture(result)
    case "readFanqieCapturePart":
      guard let name = args?["name"] as? String, LibraryBackupChannel.matchesPart(name) else {
        result(FlutterError(code: "invalid_part", message: "分卷名称无效", details: nil))
        return
      }
      readCapturePart(name, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 从调用参数里取一段字节。Flutter 的 `Uint8List` 到 Swift 是
  /// `FlutterStandardTypedData`。
  private func byteArgument(_ args: [String: Any]?, _ key: String) -> Data? {
    guard let typed = args?[key] as? FlutterStandardTypedData else { return nil }
    return typed.data
  }

  /// 导出文件名由调用方给出，必须是普通文件名；不合法就用兜底名字。
  private func exportName(_ args: [String: Any]?, fallback: String) -> String {
    guard let name = args?["name"] as? String, LibraryBackupChannel.isSafeName(name) else {
      return fallback
    }
    return name
  }

  // MARK: - 文件选择

  private func begin(_ job: Job, _ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "BACKUP_BUSY", message: "备份文件正在处理", details: nil))
      return
    }
    pendingResult = result
    pendingJob = job
    switch job {
    case .open:
      let picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [.json, .plainText, .data])
      present(picker)
    case .save(let data, let name):
      do {
        let url = try writeTemporary(data: data, name: name)
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: true))
      } catch {
        finish(FlutterError(code: "write_failed", message: error.localizedDescription, details: nil))
      }
    case .exportZip:
      finish(
        FlutterError(
          code: "BACKUP_ZIP_UNSUPPORTED",
          message: "本机不直接打包采集分卷，请使用 Dart 压缩兜底",
          details: nil))
    }
  }

  private func present(_ picker: UIDocumentPickerViewController) {
    guard let presenter = topViewController() else {
      finish(FlutterError(code: "BACKUP_NO_ACTIVITY", message: "应用窗口不可用", details: nil))
      return
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  /// 结束一次操作并把结果交回 Dart。`nil` 表示用户取消。
  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    pendingJob = nil
    result?(value)
  }

  public func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    switch pendingJob {
    case .open:
      guard let url = urls.first else {
        finish(nil)
        return
      }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        let data = try Data(contentsOf: url)
        guard data.count <= LibraryBackupChannel.maxBytes else {
          finish(
            FlutterError(
              code: "BACKUP_SIZE", message: "备份文件超过 16 MB", details: nil))
          return
        }
        finish(FlutterStandardTypedData(bytes: data))
      } catch {
        finish(
          FlutterError(
            code: "BACKUP_IO_FAILED", message: "读取失败，请选择不超过 16 MB 的备份文件",
            details: nil))
      }
    case .save, .exportZip:
      // 导出模式下系统已经把文件复制到用户选的位置。
      finish(true)
    case .none:
      break
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    switch pendingJob {
    case .open:
      finish(nil)
    case .save, .exportZip:
      finish(false)
    case .none:
      break
    }
  }

  // MARK: - 导出文件

  /// 把内容写到临时目录，交给系统选择器让用户决定存到哪。
  private func writeTemporary(data: Data, name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fqapp-export", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent(name)
    try data.write(to: target, options: .atomic)
    return target
  }

  // MARK: - 采集文件

  /// 采集文件放在 Application Support 里：和 Android 的 filesDir 一样属于
  /// 应用私有目录，不会出现在「文件」App 里被随手删掉。
  private func captureDirectory() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = base.appendingPathComponent("fanqie-library-captures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func storeCapture(_ data: Data, _ result: FlutterResult) {
    guard !data.isEmpty, data.count <= LibraryBackupChannel.maxBytes else {
      result(
        FlutterError(code: "CAPTURE_SIZE", message: "采集文件为空或超过 16 MB", details: nil))
      return
    }
    do {
      let directory = try captureDirectory()
      let name = "capture-\(stamp())-\(UUID().uuidString.lowercased()).json"
      try data.write(to: directory.appendingPathComponent(name), options: .atomic)
      result(true)
    } catch {
      result(
        FlutterError(
          code: "CAPTURE_IO_FAILED", message: "本机采集文件写入失败，可尝试导出", details: nil))
    }
  }

  private func storeCapturePart(_ data: Data, _ result: FlutterResult) {
    guard !data.isEmpty, data.count <= LibraryBackupChannel.maxBytes else {
      result(
        FlutterError(code: "CAPTURE_SIZE", message: "采集文件为空或超过 16 MB", details: nil))
      return
    }
    do {
      let directory = try captureDirectory()
      let name = "part-\(stamp())-\(UUID().uuidString.lowercased()).json"
      try data.write(to: directory.appendingPathComponent(name), options: .atomic)
      result(name)
    } catch {
      result(
        FlutterError(
          code: "CAPTURE_IO_FAILED", message: "本机采集文件写入失败，可尝试导出", details: nil))
    }
  }

  private func latestCapture(_ result: FlutterResult) {
    do {
      let directory = try captureDirectory()
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      // 文件名里带毫秒时间戳，字典序就是时间序。
      let latest =
        files
        .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        .first
      guard let url = latest else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: try Data(contentsOf: url)))
    } catch {
      result(nil)
    }
  }

  private func readCapturePart(_ name: String, _ result: FlutterResult) {
    do {
      let directory = try captureDirectory()
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: try Data(contentsOf: url)))
    } catch {
      result(nil)
    }
  }

  // MARK: - 工具

  private func stamp() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private static func matchesPart(_ name: String) -> Bool {
    name.range(of: partPattern, options: .regularExpression) != nil
  }

  /// 导出文件名必须是普通文件名。
  private static func isSafeName(_ name: String) -> Bool {
    name.range(of: safeNamePattern, options: .regularExpression) != nil
  }
}
