import ActivityKit
import AVFoundation
import CoreMedia
import Dispatch
import Flutter
import MediaPlayer
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import os

/// 原生日志双写：os_log 供系统统一日志 / Console.app 抓取，同时立即落盘，
/// 让 App 内的日志导出能带上原生事件。系统日志是内存环形缓冲，进程被系统
/// 终止或缓冲滚掉后就没了；文件跨冷启动保留。
private final class FqNativeLog {
  static let shared = FqNativeLog()

  private static let subsystem = Bundle.main.bundleIdentifier ?? "fqapp"
  private static let osLog = OSLog(subsystem: subsystem, category: "NowPlaying")
  private static let maxBytes: UInt64 = 512 * 1024

  private let lock = NSLock()
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  /// 与 Dart 的 getApplicationSupportDirectory()/logs 指向同一目录。
  private var fileURL: URL? {
    guard let support = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let dir = support.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("native.log")
  }

  /// 导出头从这行取构建号，避免日志与 IPA 版本对不上。
  private var buildHeader: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "# fqapp native log | build \(version) (\(build))"
      + " | bundle \(Self.subsystem)"
  }

  static func log(_ message: String) {
    os_log(.default, log: osLog, "%{public}@", message)
    shared.write(message)
  }

  private func write(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let url = fileURL else { return }
    let fm = FileManager.default
    let header = buildHeader + "\n"
    if !fm.fileExists(atPath: url.path) {
      try? header.write(to: url, atomically: true, encoding: .utf8)
    } else {
      let attrs = try? fm.attributesOfItem(atPath: url.path)
      let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
      if size > Self.maxBytes {
        let backup = url.deletingPathExtension().appendingPathExtension("old.log")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
        try? header.write(to: url, atomically: true, encoding: .utf8)
      }
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    try? handle.seekToEnd()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    try? handle.write(contentsOf: Data(line.utf8))
    try? handle.synchronize()
  }
}

/// 旧版本在锁屏挂过一张灵动岛 Live Activity；升级后它仍会留在锁屏上。
/// 本版本删除了 Live Activity app extension，系统再无 UI 可渲染，同时把
/// 系统守护进程里遗留的 activity 逐条结束，避免条目一直挂到 staleDate。
/// 每次回前台都重跑一次，直到枚举为空。
@available(iOS 16.2, *)
private func endLegacyLiveActivities() {
  Task {
    let activities = await Activity<FqListeningAttributes>.activities
    for activity in activities {
      await activity.end(using: nil, dismissalPolicy: .immediate)
    }
    FqNativeLog.log("[fqapp] legacy live activities ended: \(activities.count)")
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 应用级通道实例必须被 AppDelegate **持有**。
  ///
  /// 这些通道早先是以临时变量创建的（`DownloadsChannel(...).register()`），
  /// register() 返回后对象立刻释放 —— 而 `LibraryBackupChannel` 的 handler
  /// 用 `[weak self]` 捕获自己，回调时 self 已经是 nil，于是每个调用都走
  /// 「通道已释放」分支：备份页的 `hasPicker` 探针拿不到 true，界面就一直
  /// 显示「当前运行环境没有系统文件选择器」。这里改成强持有的属性。
  private let downloadsChannel = DownloadsChannel()
  private let shareChannel = ShareChannel()
  private let libraryBackupChannel = LibraryBackupChannel()
  private let readerDeviceChannel = ReaderDeviceChannel()
  private let notificationPermissionChannel = NotificationPermissionChannel()
  private let nowPlayingChannel = NowPlayingChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 锁屏只保留系统 Now Playing 卡片：清掉旧版本投递的本地通知与
    // 灵动岛实时活动，避免升级后仍出现两条额外入口。
    cleanupLegacyLockScreenEntries()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 冷启动与每次回前台都执行：旧版本曾用动态 identifier 重投通知，也可能
  /// 留下未结束的实时活动，只按固定 identifier 清一条是清不干净的。
  func cleanupLegacyLockScreenEntries() {
    nowPlayingChannel.removePlaybackNotifications()
    if #available(iOS 16.2, *) { endLegacyLiveActivities() }
  }

  /// 自有 URL scheme（Info.plist 里声明 `fqapp`）：自己消费掉，别再交给
  /// 插件链去猜一个不存在的深链。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool {
    if url.scheme == "fqapp" {
      FqNativeLog.log("[fqapp] open url: \(url.absoluteString)")
      return true
    }
    return super.application(app, open: url, options: options)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS 没有共享的 Downloads 目录，日志导出与分享走系统能力：文件落到
    // 应用的 Documents（开了文件共享后能在「文件」App 里看到），同时调起
    // 系统分享面板，用户可以存到「文件」、发给自己或放进任何一个 App。
    //
    // messenger 取自 `applicationRegistrar` 而不是
    // `pluginRegistry.registrar(forPlugin:)`：后者是**插件**注册表，给一个
    // 从未注册过的插件名去要 registrar，语义上不对（引擎会现造一个，
    // 但它不是「应用级」通道该用的入口）。应用级通道统一走
    // `applicationRegistrar.messenger()`。
    let messenger = engineBridge.applicationRegistrar.messenger()
    downloadsChannel.register(messenger: messenger)
    shareChannel.register(messenger: messenger)
    libraryBackupChannel.register(messenger: messenger)
    readerDeviceChannel.register(messenger: messenger)
    notificationPermissionChannel.register(messenger: messenger)
    nowPlayingChannel.register(messenger: messenger)
  }
}

/// `fqapp/downloads`：把导出的文本写进应用目录，并调起系统分享面板。
final class DownloadsChannel {
  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/downloads", binaryMessenger: messenger)
    self.channel = channel
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
  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/share", binaryMessenger: messenger)
    self.channel = channel
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

  private var channel: FlutterMethodChannel?
  private var pendingResult: FlutterResult?
  private var pendingJob: Job?

  override init() {
    super.init()
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/library_backup", binaryMessenger: messenger)
    self.channel = channel
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

/// `fqapp/reader`：阅读器与设备相关的原生能力，其中 iOS 缺的是**导入字体**。
///
/// Android 用 `ACTION_OPEN_DOCUMENT` + `ACTION_OPEN_DOCUMENT` 的 mime 过滤，
/// 桌面端用 `file_selector`；iOS 之前完全没有这个通道，于是阅读页的「导入字体」
/// 一点就抛 `MissingPluginException`，面板上显示成「无法载入字体，请选择有效的
/// TTF、OTF 或 TTC 文件」—— 那句文案讲的是文件格式，而真实原因是通道不存在。
///
/// 这里用 `UIDocumentPickerViewController` 选字体，复制到应用私有的
/// `Documents/reader-fonts` 目录，再把**绝对路径**回给 Dart：Dart 侧用
/// `FontLoader` 从文件字节加载，路径必须在应用沙盒里才读得到。
///
/// 契约与 Android 端 `ReaderDevicePlugin.pickFont` 完全一致：
/// 成功返回 `{path, name}`，用户取消返回 null。
final class ReaderDeviceChannel: NSObject, UIDocumentPickerDelegate {
  /// 与 Android 端一致：字体文件不超过 32 MB。
  private static let maxBytes = 32 * 1024 * 1024
  /// 字体魔数：TTF / OTF / TTC / TrueType Collection。
  private static let signatures: Set<String> = [
    "00010000",  // TTF
    "4f54544f",  // OTF
    "74746366",  // ttc
    "74727565",  // true
  ]

  private var channel: FlutterMethodChannel?
  private var pendingResult: FlutterResult?
  /// 当前是否要求常亮。
  ///
  /// iOS 在应用退到后台再回前台时会重置 `isIdleTimerDisabled`，于是开关
  /// 「看起来是开的、实际不生效」。这里记住最后一次的请求，回前台时重放一次。
  private var keepScreenOnEnabled = false
  private var foregroundObserver: NSObjectProtocol?

  override init() {
    super.init()
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, self.keepScreenOnEnabled else { return }
      UIApplication.shared.isIdleTimerDisabled = true
    }
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/reader", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "no_channel", message: "通道已释放", details: nil))
        return
      }
      self.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "pickFont":
      pickFont(result)
    case "keepScreenOn":
      // 屏幕常亮：iOS 用 `isIdleTimerDisabled` 关掉系统的自动锁屏。
      //
      // 之前这个方法和「亮度」「沉浸式」一起被归到「回中性值」的分支里，
      // 于是阅读器设置里的「屏幕常亮」开关在 iOS 上点了完全不生效 ——
      // 开关的偏好存下来了，但原生什么都没做，屏幕照常按系统超时熄灭。
      //
      // 与 Android 的 `FLAG_KEEP_SCREEN_ON` 一致，开关是**全局**状态：
      // 关闭时必须显式复位，否则阅读器退出后屏幕会一直亮着。
      setKeepScreenOn(call.arguments as? [String: Any])
      result(nil)
    case "start", "setBrightness", "suspend", "stop", "setImmersive":
      // 阅读器在 iOS 上没有亮度/沉浸式这些原生能力（`ReaderDevice` 的
      // 每个方法都自带 MissingPluginException 降级），这里明确回中性值，
      // 让 Dart 侧走同一条降级路径而不是整个方法找不到处理器。
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 打开/关闭「屏幕常亮」。
  ///
  /// `isIdleTimerDisabled` 是 UIApplication 的全局开关：置为 true 后系统不再
  /// 因为空闲而自动锁屏。阅读器退出时 Dart 侧会再调一次 `on: false` 复位。
  private func setKeepScreenOn(_ arguments: [String: Any]?) {
    let on = arguments?["on"] as? Bool ?? false
    keepScreenOnEnabled = on
    DispatchQueue.main.async {
      UIApplication.shared.isIdleTimerDisabled = on
    }
  }

  private func pickFont(_ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "FONT_PICKER_BUSY", message: "请先关闭已打开的字体选择器", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "FONT_PICKER_UNAVAILABLE", message: "无法打开文件选择器", details: nil))
      return
    }
    pendingResult = result
    // 字体在 iOS 上的 UTI 没有单一「字体」类型：TrueType / OpenType / 字体集合
    // 各自一个。把这几类都放进去，用户在「文件」里看到 .ttf/.otf/.ttc 就能选。
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: ReaderDeviceChannel.fontContentTypes,
      asCopy: true
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  /// 可选的字体类型。
  ///
  /// `UTType` 没有 `truetypeFont` / `opentypeFont` 这两个静态属性（Xcode 27
  /// SDK 的公开接口里就不存在），只能按 UTI 标识符或文件扩展名构造。标识符
  /// 优先、扩展名兜底：系统里 .ttf/.otf/.ttc 各对应一个类型，缺一类就少一类
  /// 字体可选。
  private static let fontContentTypes: [UTType] = {
    var types: [UTType] = []
    for identifier in [
      "public.truetype-font",
      "public.opentype-font",
      "public.font",
    ] {
      if let type = UTType(identifier) { types.append(type) }
    }
    if types.isEmpty {
      for ext in ["ttf", "otf", "ttc"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
      }
    }
    if types.isEmpty {
      types = [UTType.font]
    }
    return types
  }()

  public func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first else {
      finish(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let imported = try importFont(url)
      finish(imported)
    } catch {
      finish(
        FlutterError(
          code: "FONT_IMPORT_FAILED",
          message: error.localizedDescription,
          details: nil))
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  /// 把字体复制进应用私有目录，并回传绝对路径。
  ///
  /// 沙盒外的原文件路径 Dart 读不到（而且可能随时被系统回收），必须复制。
  /// 文件名用内容哈希，和 Android 端一样：同一份字体重复导入不会堆积副本。
  private func importFont(_ url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    guard data.count <= ReaderDeviceChannel.maxBytes else {
      throw NSError(
        domain: "fqapp.reader", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "请选择小于 32 MB 的字体文件"])
    }
    guard data.count >= 12 else {
      throw NSError(
        domain: "fqapp.reader", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "字体文件不完整"])
    }
    let signature = data.prefix(4).map { String(format: "%02x", $0) }.joined()
    guard ReaderDeviceChannel.signatures.contains(signature) else {
      throw NSError(
        domain: "fqapp.reader", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "请选择 TTF、OTF 或 TTC 字体文件"])
    }
    let directory = try fontDirectory()
    let hash = ReaderDeviceChannel.stableHash(data)
    let target = directory.appendingPathComponent("\(hash).font")
    if !FileManager.default.fileExists(atPath: target.path) {
      try data.write(to: target, options: .atomic)
    }
    return ["path": target.path, "name": url.lastPathComponent]
  }

  /// 内容寻址的稳定哈希（FNV-1a 64 位）。
  ///
  /// 不能用 Swift 的 `hashValue`：它按进程随机种子生成，**每次启动都不一样**，
  /// 同一份字体每开一次应用就会多出一个副本。
  static func stableHash(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }

  /// 字体目录放在 Documents 下而不是 Application Support：与 Android 的
  /// `filesDir` 不同，Dart 侧只需要一个能读到的绝对路径，放哪儿都能读。
  private func fontDirectory() throws -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let directory = documents.appendingPathComponent("reader-fonts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }
}

/// `fqapp/ios_notification`：通知（通知栏）权限。
///
/// Android 的 POST_NOTIFICATIONS 是运行时权限，iOS 这边对应
/// `UNUserNotificationCenter`：应用必须**主动**调
/// `requestAuthorization` 才会弹系统授权框，从不询问的话用户永远看不到通知，
/// 而且通知栏里也不会出现任何本应用的通知。
///
/// 三个方法与 Android 端 `NativePlayerPlugin` 的同名方法一一对应，Dart 侧的
/// `NotificationPermission` 服务因此在两个平台上走同一套契约：
/// - `status`：granted / denied / notDetermined / unknown
/// - `request`：只在系统**还没问过**（notDetermined）时才弹框；已经问过
///   （用户点过允许或拒绝）就直接回当前状态 —— 系统对这两种情况都不会再弹框，
///   反复调用只会白等一次回调。
/// - `openSettings`：跳到本应用的系统设置页，用户在那里可以打开通知。
final class NotificationPermissionChannel {
  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "fqapp/ios_notification",
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "no_channel", message: "通道已释放", details: nil))
        return
      }
      self.handle(call, result)
    }
  }

  /// 授权状态 → Dart 侧认识的字符串。
  ///
  /// `.provisional`（静默 provisional 授权）与 `.ephemeral`（App Clip）都能收到
  /// 通知，按已授权处理。
  private func statusString(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return "granted"
    case .denied:
      return "denied"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "unknown"
    }
  }

  private func currentStatus(_ completion: @escaping (String) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      completion(self.statusString(settings.authorizationStatus))
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      currentStatus { status in
        DispatchQueue.main.async { result(status) }
      }
    case "request":
      currentStatus { status in
        guard status == "notDetermined" else {
          // 已经问过：系统不会再弹框，直接回当前状态。
          DispatchQueue.main.async { result(status) }
          return
        }
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge]
        ) { _, error in
          if let error = error {
            FqNativeLog.log("[fqapp] notification authorization failed: \(error)")
          }
          self.currentStatus { next in
            DispatchQueue.main.async { result(next) }
          }
        }
      }
    case "openSettings":
      // iOS 没有「通知」设置的深链，只能进本应用的设置页（里面第一项就是
      // 「通知」）。系统设置页打不开时回 false，让界面给出手动引导。
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// `fqapp/ios_now_playing`：iOS 标准 Now Playing 媒体会话。
///
/// 音乐类 App 在锁屏 / 通知中心 / 控制中心里那张带 ⏮ ⏯ ⏭ 的「播放器」，
/// 由系统按 Now Playing App 渲染，第三方 App 不能自己画一张通知出来替代它。
/// 因此这一层只负责把本 App 稳定登记成 Now Playing App，并把系统派下来的
/// 远控动作交给 Dart：
/// - `AVAudioSession`：独占 playback、常驻 active，是登记身份的前提；
/// - 后台静音音轨：换章 / 取流间隙保持音频渲染，避免进程被挂起；
/// - `MPNowPlayingInfoCenter`：完整、合法的媒体条目（非直播流）；
/// - `MPRemoteCommandCenter`：上一首 / 下一首等远控，target 只挂自己的。
///
/// 锁屏入口只有系统渲染的这一张卡片：不再投递本地通知、不再请求 Live
/// Activity，卡片主体点击由系统按当前 Now Playing App 唤起本进程。
final class NowPlayingChannel: NSObject {
  private static let channelName = "fqapp/ios_now_playing"
  /// 系统朗读没有真实时长，给一个有限占位，让卡片是「有进度的曲目」
  /// 而不是直播流 —— 直播流会把 ⏮ / ⏭ 换成 15 秒快退 / 快进。
  private static let placeholderDurationMs = 3_600_000.0

  /// 持久化曲目 ID 用书名的稳定哈希，跨切章保持不变；不用 String.hashValue，
  /// 后者每次进程启动都会变，系统会把同一本书认成不同曲目。
  private static func stableID(_ text: String) -> UInt64 {
    var hash: UInt64 = 5_381
    for byte in text.utf8 {
      hash = ((hash << 5) &+ hash) &+ UInt64(byte)
    }
    return hash
  }

  private var channel: FlutterMethodChannel?
  private var artworkTask: URLSessionDataTask?
  private var artworkURL: String?
  private var artwork: MPMediaItemArtwork?
  private lazy var placeholderArtwork: MPMediaItemArtwork? = {
    guard let image = UIImage(named: "AppIcon") else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }()
  private var info: [String: Any] = [:]
  private var silentPlayer: AVAudioPlayer?
  private var cachedSilenceURL: URL?
  private var sessionPublished = false
  private var hasNext = true
  /// 切章取流时 durationMs 会短暂回落成 0，沿用上一章真实时长，不让
  /// nowPlayingInfo 在「1 小时占位 → 真实时长」之间抖动重绘。
  private var lastKnownDurationMs = 0.0
  private var lastEpisode = ""
  private var queueIndex = 0
  /// 后台通知动作可能早于 Flutter 隐式引擎桥接完成，先缓存再补发。
  private var pendingRemoteActions: [String] = []
  /// 后台换章时旧播放器被 pause / dispose，常把共享 AVAudioSession 一起
  /// deactivate：音频输出一断 iOS 立即挂起 App，Dart 侧的取流与建播放器
  /// 冻结到下次回前台。收到切章远控后的一段窗口里持续恢复会话身份。
  private var actionWatchdog: DispatchWorkItem?
  private var watchdogDeadline: Date?
  /// 原生常驻守护：Dart 的 15 秒元数据心跳在后台会被节流，Now Playing
  /// App 的资格（独占且 active 的会话 + 持续音频输出 + 完整条目）必须由
  /// 原生层独立维持，不能依赖 isolate 存活。
  private var sessionGuard: DispatchSourceTimer?
  private var lastInfoRefresh = Date.distantPast
  /// 独占 playback 会话只在首次配置或系统重置 / 中断后配置一次。播放中
  /// 反复 setCategory / setActive 会中断 AVPlayer 的输出，后台切章就哑了。
  private var audioSessionConfigured = false

  /// 真实音频时间线：AVPlayer 持续渲染章节音频（本地回环服务解密后的明文流
  /// 或本地静音轨），volume 置 0 只是不重复出声，媒体客户端与时间线仍然
  /// 真实存在。系统据此把本 App 登记为 Now Playing App，锁屏卡片主体点击
  /// 才有可唤起的进程。
  private var timelinePlayer: AVPlayer?
  private var timelineItem: AVPlayerItem?
  private var timelineURL: String?
  /// iOS 16+ 的显式会话登记对象。部署目标为 iOS 15，用 NSObject 持有，
  /// 避免在存储属性上直接标注 @available。
  private var sessionObject: NSObject?

  private var infoCenter: MPNowPlayingInfoCenter {
    if #available(iOS 16.0, *),
       let session = sessionObject as? MPNowPlayingSession {
      return session.nowPlayingInfoCenter
    }
    return MPNowPlayingInfoCenter.default()
  }

  private var commandCenter: MPRemoteCommandCenter {
    if #available(iOS 16.0, *),
       let session = sessionObject as? MPNowPlayingSession {
      return session.remoteCommandCenter
    }
    return MPRemoteCommandCenter.shared()
  }

  // MARK: - 注册

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: NowPlayingChannel.channelName,
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "no_channel", message: "通道已释放", details: nil))
        return
      }
      self.handle(call, result)
    }
    // 缓存的动作等 Dart 挂好 setMethodCallHandler 后由 ready 补发：引擎刚
    // 创建通道时 Dart 侧还没有接收者，这里立刻补发会永久丢失。
    installRemoteTargets()
    UIApplication.shared.beginReceivingRemoteControlEvents()
    observeSystemEvents()
    startSessionGuard()
    // 冷启动不激活 playback 会话，避免抢走用户正在听的音乐；第一次起播
    // （apply）再激活。
  }

  /// 后台全程维持系统登记身份：会话独占且 active、静音音轨不断、媒体条目
  /// 不丢。2 秒一次，全部为幂等操作，不重设已正确的 category，也不重装
  /// 远控 target，避免打断 AVPlayer 输出或让恰好按下的按钮找不到 target。
  private func startSessionGuard() {
    guard sessionGuard == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    timer.schedule(
      deadline: .now() + 2,
      repeating: .seconds(2),
      leeway: .milliseconds(500)
    )
    timer.setEventHandler { [weak self] in
      guard let self, self.sessionPublished else { return }
      self.activateSession()
      if let timeline = self.timelinePlayer {
        if timeline.rate == 0 { timeline.play() }
      } else if self.silentPlayer?.isPlaying != true {
        self.startSilentPlayback(force: true)
      }
      guard Date().timeIntervalSince(self.lastInfoRefresh) >= 10,
            !self.info.isEmpty else { return }
      self.infoCenter.nowPlayingInfo = self.info
      let rate =
        (self.info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
          .doubleValue ?? 0
      self.infoCenter.playbackState =
        rate > 0 ? .playing : .paused
      self.lastInfoRefresh = Date()
    }
    timer.resume()
    sessionGuard = timer
  }

  /// 旧版本曾以固定和动态 identifier 投递常驻通知作为回 App 的入口。
  /// 现在锁屏只保留系统 Now Playing 卡片，全量清空通知栈与待投递请求，
  /// 并注销旧分类；升级后通知中心里不再出现本地通知横幅。
  func removePlaybackNotifications() {
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()
    center.removeAllPendingNotificationRequests()
    center.setNotificationCategories([])
  }

  // MARK: - 会话身份

  /// 独占 playback + active 的会话是系统把本 App 登记为 Now Playing App
  /// 的必要条件；带 mixWithOthers 的会话不会被登记，卡片主体点击就没有
  /// 可唤起的目标，⏮ / ⏭ 也会派给上一个播放方。
  private func activateSession() {
    // 一次性布尔挡不住「插件自行 deactivate 共享会话」：flutter_tts /
    // media_kit 在换章 dispose 时会 deactivate，却不会发系统中断通知，
    // 布尔仍为 true，会话就永久 inactive，本 App 不再是 Now Playing App，
    // 卡片主体点击便没有可唤起的目标。改为按会话的实际 category / options
    // 判断：只在确实不符时才 setCategory（在已激活会话上改 options 会打断
    // AVPlayer 输出），setActive(true) 则每次调用 —— 它对已激活会话是幂等
    // 的，能把被插件关掉的会话重新激活。
    let session = AVAudioSession.sharedInstance()
    do {
      // .duckOthers 与 .mixWithOthers 一样让会话成为 mixable，而 mixable
      // 会话按 Apple 的 Now Playing 资格规则永远不会被登记；插件写入这两种
      // 选项时都必须纠正回独占 playback。
      let mixable: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers]
      if session.category != .playback ||
         !session.categoryOptions.intersection(mixable).isEmpty {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.allowBluetoothA2DP]
        )
        FqNativeLog.log("[fqapp] audio session category restored to playback")
      }
      try session.setActive(true, options: [])
      audioSessionConfigured = true
    } catch {
      FqNativeLog.log("[fqapp] audio session activate failed: \(error)")
    }
  }

  /// 守护窗口内只保「会话处于 active」，不改 category / options，避免播放中
  /// 重设类别打断输出。插件 deactivate 后靠这里在数秒内恢复。
  private func keepSessionActive() {
    do {
      try AVAudioSession.sharedInstance().setActive(true, options: [])
      audioSessionConfigured = true
    } catch {
      FqNativeLog.log("[fqapp] audio session reactivate failed: \(error)")
    }
  }

  private func invalidateAudioSession() {
    audioSessionConfigured = false
  }

  /// 章末换章、下一集取流的间隙播放器会完全静下来，iOS 随即挂起 App：
  /// Dart 的切章与取流全部冻结。循环一段极低幅度的音轨让音频渲染管线
  /// 一直运行，这是后台音频 App 的标准做法。采样值不能全为 0 —— 全零
  /// 输出会被 CoreAudio 判成无音频活动，系统就不把本 App 记为正在播放。
  private func startSilentPlayback(force: Bool = false) {
    guard sessionPublished else { return }
    // iOS 16+ 由 AVPlayer 时间线提供媒体身份，不再叠加 AVAudioPlayer，
    // 避免两个音频客户端争抢同一会话的归属。iOS 15 保留原有静音轨。
    if #available(iOS 16.0, *), timelinePlayer != nil { return }
    // 会话被别的组件 deactivate 时 isPlaying 可能仍为 true，却没有音频输出；
    // 看门狗用 force 重启音轨，重新向 CoreAudio 声明本 App 正在播放。
    if !force && silentPlayer?.isPlaying == true { return }
    silentPlayer?.stop()
    silentPlayer = nil
    do {
      let url = try silenceFileURL()
      let player = try AVAudioPlayer(contentsOf: url)
      // volume 保持 1：置 0 会让 CoreAudio 优化掉输出。
      player.volume = 1.0
      player.numberOfLoops = -1
      player.prepareToPlay()
      silentPlayer = player
      if !player.play() {
        FqNativeLog.log("[fqapp] silent playback did not start")
      }
    } catch {
      FqNativeLog.log("[fqapp] silent playback unavailable: \(error)")
    }
  }

  private func stopSilentPlayback() {
    silentPlayer?.stop()
    silentPlayer = nil
  }

  /// 临时 WAV + `AVAudioPlayer(contentsOf:)`：内存 data 的 UTI 猜测在
  /// 部分系统版本会失败，失败被吞掉后整条保活链路其实没跑起来。
  private func silenceFileURL() throws -> URL {
    if let cached = cachedSilenceURL,
       FileManager.default.fileExists(atPath: cached.path) {
      return cached
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("fqapp-silence.wav")
    let frames = 8000  // 8kHz 单声道 16bit，1 秒
    var wav = Data()
    func bytes(_ values: [UInt8]) { wav.append(contentsOf: values) }
    func text(_ value: String) { wav.append(contentsOf: value.utf8) }
    func int32(_ value: Int32) {
      let bits = UInt32(bitPattern: value).littleEndian
      bytes([
        UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
        UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff),
      ])
    }
    func int16(_ value: Int16) {
      let bits = UInt16(bitPattern: value).littleEndian
      bytes([UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff)])
    }
    text("RIFF"); int32(Int32(36 + frames * 2)); text("WAVE")
    text("fmt "); int32(16); int16(1); int16(1)
    int32(8000); int32(16000); int16(2); int16(16)
    text("data"); int32(Int32(frames * 2))
    // ±1 LSB（约 -90dB）的方波：有真实采样输出，人耳完全听不到。
    var samples = Data(count: frames * 2)
    for i in 0..<frames {
      samples[i * 2] = (i % 2 == 0) ? 1 : 255
      samples[i * 2 + 1] = (i % 2 == 0) ? 0 : 255
    }
    wav.append(samples)
    try wav.write(to: url, options: .atomic)
    cachedSilenceURL = url
    return url
  }

  /// 后台全程保持「正在播放」身份与远控注册。第三方媒体组件起播时常会
  /// 重建自己的远控 target 并 `removeTarget(nil)` 清掉别人的，所以每次
  /// 状态刷新、进后台、回前台、音频中断结束都要重新立一次。
  private func ensurePlaybackIdentity() {
    activateSession()
    startSilentPlayback()
    UIApplication.shared.beginReceivingRemoteControlEvents()
    installRemoteTargets()
    ensureSessionActive()
  }

  /// 后台按上一章 / 下一章时，Dart 会停掉旧播放器再取流重建。旧播放器
  /// dispose 会 deactivate 共享会话，音频一断系统就挂起 App，切章于是卡在
  /// 半路、直到回前台才继续。Apple 的后台音频规则要求这段时间里始终有
  /// 真实音频输出且本 App 仍是 Now Playing App，所以守护窗口内周期性恢复
  /// 会话、保活音轨、远控注册与媒体元数据。
  private func beginActionWatchdog() {
    actionWatchdog?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.sessionPublished else { return }
      // 守护只负责两件事：音频输出不断、卡片元数据不丢。会话已配置好，
      // 播放中再改 category / 重装远控 target 会打断输出或让恰好按下的
      // ⏮ / ⏭ 找不到 target，这两项改由系统事件驱动恢复。
      if let timeline = self.timelinePlayer {
        if timeline.rate == 0 { timeline.play() }
      } else if self.silentPlayer?.isPlaying != true {
        self.startSilentPlayback(force: true)
      }
      self.keepSessionActive()
      UIApplication.shared.beginReceivingRemoteControlEvents()
      if !self.info.isEmpty {
        // 重新写回完整条目：系统按当前 Now Playing App 决定卡片主体点击
        // 唤起哪个进程，元数据被别的组件清掉后卡片就没有可唤起目标。
        self.infoCenter.nowPlayingInfo = self.info
        let rate: Double
        if let value = self.info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber {
          rate = value.doubleValue
        } else {
          rate = 0
        }
        self.infoCenter.playbackState = rate > 0 ? .playing : .paused
      }
      guard let deadline = self.watchdogDeadline else { return }
      if Date() < deadline {
        self.beginActionWatchdog()
      } else {
        self.watchdogDeadline = nil
        self.actionWatchdog = nil
      }
    }
    actionWatchdog = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
  }

  private func stopActionWatchdog() {
    watchdogDeadline = nil
    actionWatchdog?.cancel()
    actionWatchdog = nil
  }

  private func observeSystemEvents() {
    let events: [Notification.Name] = [
      UIApplication.didEnterBackgroundNotification,
      UIApplication.didBecomeActiveNotification,
    ]
    for name in events {
      NotificationCenter.default.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] note in
        if note.name == UIApplication.didBecomeActiveNotification {
          // Scene 生命周期下 AppDelegate 不收 didBecomeActive 回调，但
          // UIApplication 通知仍会发出；系统从锁屏卡片唤起时在这里收尾。
          (UIApplication.shared.delegate as? AppDelegate)?
            .cleanupLegacyLockScreenEntries()
        }
        guard let self, self.sessionPublished else { return }
        FqNativeLog.log("[fqapp] lifecycle: \(note.name.rawValue)")
        self.ensurePlaybackIdentity()
        if note.name == UIApplication.didBecomeActiveNotification {
          // 系统从锁屏卡片唤起 App 时不带 URL，也不会保留被别的组件清掉的
          // 元数据：补写完整条目，让会话仍是系统认定的 Now Playing App。
          if !self.info.isEmpty {
            self.infoCenter.nowPlayingInfo = self.info
            let rate =
              (self.info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
                .doubleValue ?? 0
            self.infoCenter.playbackState =
              rate > 0 ? .playing : .paused
          }
          // 后台冻结 / 冷启动期间缓存的动作，回前台立即补发，不等下一次
          // 15 秒元数据心跳，避免「进 App 之后还要等一会才切章」。
          self.drainPendingRemoteActions()
        }
      }
    }
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      guard let self, self.sessionPublished else { return }
      guard
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      if type == .began {
        FqNativeLog.log("[fqapp] audio interruption began")
        // 系统中断会 deactivate 会话；结束后才有资格重新配置一次。
        self.invalidateAudioSession()
        return
      }
      guard type == .ended else { return }
      FqNativeLog.log("[fqapp] audio interruption ended")
      self.activateSession()
      self.ensurePlaybackIdentity()
    }
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // 媒体服务重置会丢掉会话配置、远控 target 与正在播放的音轨；只置标志
      // 不重建，本 App 就再也不会被登记为 Now Playing App。
      self.invalidateAudioSession()
      self.activateSession()
      if self.sessionPublished { self.ensurePlaybackIdentity() }
    }
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self, self.sessionPublished else { return }
      FqNativeLog.log("[fqapp] audio route changed")
    }
  }

  // MARK: - 真实音频时间线 / Now Playing 会话登记

  /// 用真实播放的 AVPlayer 取代「只写 nowPlayingInfo 字典」的伪会话。
  /// MPNowPlayingSession 把这个播放器显式登记为系统的 Now Playing session，
  /// SpringBoard 解析卡片主体点击时才能按 bundle id 唤起本 App。
  private func installTimeline(urlString: String, startMs: Double) {
    guard #available(iOS 16.0, *) else { return }
    let resolved: URL
    if let url = URL(string: urlString),
       url.scheme == "http" || url.scheme == "https" || url.isFileURL {
      resolved = url
    } else if let silence = try? silenceFileURL() {
      resolved = silence
    } else {
      return
    }
    let key = resolved.absoluteString
    let start = CMTime(value: Int64(max(startMs, 0)), timescale: 1000)
    if key == timelineURL, let player = timelinePlayer {
      if startMs > 0 { player.seek(to: start) }
      if player.rate == 0 { player.play() }
      ensureSessionActive()
      return
    }
    // commandCenter 会从 shared 切到 session：先把挂在 shared 上的 target
    // 摘干净，避免一次按键被两个命令中心各派发一次。
    removeRemoteTargets()
    timelinePlayer?.pause()
    let item = AVPlayerItem(url: resolved)
    let player = AVPlayer(playerItem: item)
    // 声音仍由 media_kit / 系统朗读负责，这条时间线只提供媒体身份。
    player.volume = 0
    timelineItem = item
    timelinePlayer = player
    timelineURL = key
    let session = MPNowPlayingSession(players: [player])
    // 章节名、进度与倍速由 Dart 维护；自动发布会把音轨时长写进卡片，
    // 覆盖真实章节时长，所以这里保持手动发布。
    session.automaticallyPublishesNowPlayingInfo = false
    sessionObject = session
    if startMs > 0 { player.seek(to: start) }
    player.play()
    installRemoteTargets()
    ensureSessionActive()
    if !info.isEmpty { applyStaticMetadata(info) }
    FqNativeLog.log(
      "[fqapp] audio timeline installed: \(resolved.isFileURL ? "silence" : "chapter")"
    )
  }

  private func ensureSessionActive() {
    if #available(iOS 16.0, *) {
      guard let session = sessionObject as? MPNowPlayingSession else { return }
      FqNativeLog.log(
        "[fqapp] now playing session: canBecomeActive=\(session.canBecomeActive)"
          + " isActive=\(session.isActive)"
      )
      session.becomeActiveIfPossible { [weak self] success in
        FqNativeLog.log("[fqapp] now playing session become active: \(success)")
        guard let self, success, !self.info.isEmpty else { return }
        self.infoCenter.nowPlayingInfo = self.info
        let rate =
          (self.info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
            .doubleValue ?? 0
        self.infoCenter.playbackState = rate > 0 ? .playing : .paused
      }
    }
  }

  private func applyStaticMetadata(_ next: [String: Any]) {
    guard #available(iOS 16.0, *), let item = timelineItem else { return }
    let keys = [
      MPMediaItemPropertyTitle,
      MPMediaItemPropertyArtist,
      MPMediaItemPropertyAlbumTitle,
      MPMediaItemPropertyArtwork,
      MPMediaItemPropertyPersistentID,
      MPNowPlayingInfoPropertyMediaType,
      MPNowPlayingInfoPropertyPlaybackQueueIndex,
      MPNowPlayingInfoPropertyPlaybackQueueCount,
    ]
    var staticInfo: [String: Any] = [:]
    for key in keys {
      if let value = next[key] { staticInfo[key] = value }
    }
    item.nowPlayingInfo = staticInfo
  }

  // MARK: - MPRemoteCommandCenter

  /// 用 self + selector 挂 target，才能 `removeTarget(self)` 精确重装：
  /// 既不会叠加，也不会误删别的组件挂的 target。skip / seek / rating 等
  /// 一律禁用且不挂 target，否则控制中心会把「上一首 / 下一首」换成
  /// 15 秒快退 / 快进。
  private func installRemoteTargets() {
    let center = self.commandCenter
    let unavailable: [MPRemoteCommand] = [
      center.skipForwardCommand,
      center.skipBackwardCommand,
      center.seekForwardCommand,
      center.seekBackwardCommand,
      center.changePlaybackPositionCommand,
      center.likeCommand,
      center.dislikeCommand,
      center.bookmarkCommand,
      center.ratingCommand,
      center.enableLanguageOptionCommand,
      center.disableLanguageOptionCommand,
    ]
    for command in unavailable { command.isEnabled = false }

    let targets: [(MPRemoteCommand, Selector)] = [
      (center.playCommand, #selector(onPlayCommand(_:))),
      (center.pauseCommand, #selector(onPauseCommand(_:))),
      (center.togglePlayPauseCommand, #selector(onTogglePlayPauseCommand(_:))),
      (center.nextTrackCommand, #selector(onNextTrackCommand(_:))),
      (center.previousTrackCommand, #selector(onPreviousTrackCommand(_:))),
      (center.stopCommand, #selector(onStopCommand(_:))),
    ]
    for (command, selector) in targets {
      command.removeTarget(self)
      // 第三方音频组件起播常把 next / previous 置为不可用或摘掉 target；
      // 播放 / 暂停是系统默认命令仍能显示，两端按钮却会整排消失。
      command.isEnabled = true
      command.addTarget(self, action: selector)
    }
    applyCommandAvailability()
  }

  @objc private func onPlayCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("play")
    return .success
  }

  @objc private func onPauseCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("pause")
    return .success
  }

  @objc private func onTogglePlayPauseCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("playPause")
    return .success
  }

  @objc private func onNextTrackCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    guard sessionPublished else { return .noActionableNowPlayingItem }
    // 不用 hasNext 在这里拦截：换章取流期间 Dart 会先上报 loading 态的
    // 边界值，章末判断交给会话自己，按下去至少有动作被转发。
    sendRemoteAction("next")
    return .success
  }

  @objc private func onPreviousTrackCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    guard sessionPublished else { return .noActionableNowPlayingItem }
    sendRemoteAction("prev")
    return .success
  }

  @objc private func onStopCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("stop")
    return .success
  }

  private func applyCommandAvailability() {
    let center = self.commandCenter
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.stopCommand.isEnabled = true
    // 有会话就声明两条轨道切换命令。用 isEnabled 按章节边界隐藏按钮时，
    // 首 / 末章或 hasPrev / hasNext 未透传都会让整排按钮消失，系统只剩
    // 播放 / 暂停；边界改由 onPreviousTrackCommand / onNextTrackCommand 拒绝。
    center.previousTrackCommand.isEnabled = sessionPublished
    center.nextTrackCommand.isEnabled = sessionPublished
    center.skipBackwardCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
  }

  /// 只摘自己挂的 target，配合 endReceivingRemoteControlEvents() 完整退出
  /// 远控响应链；不能用 removeTarget(nil)，那会连带摘掉别的音频组件。
  private func removeRemoteTargets() {
    let center = self.commandCenter
    let commands: [MPRemoteCommand] = [
      center.playCommand,
      center.pauseCommand,
      center.togglePlayPauseCommand,
      center.nextTrackCommand,
      center.previousTrackCommand,
      center.stopCommand,
    ]
    for command in commands { command.removeTarget(self) }
  }

  private func sendRemoteAction(_ action: String) {
    // 远控回调不保证在主线程，FlutterMethodChannel 只能在主线程发消息。
    // 后台按键时先恢复音频渲染，Apple 才继续给本 App 派发远控和后台
    // 执行时间，Dart 的切章取流才不会被冻结。
    let send: () -> Void = { [weak self] in
      guard let self else { return }
      self.activateSession()
      self.startSilentPlayback()
      if action == "prev" || action == "next" {
        self.watchdogDeadline = Date().addingTimeInterval(45)
        self.beginActionWatchdog()
      }
      let task = UIApplication.shared.beginBackgroundTask(
        withName: "fqapp.remote.\(action)"
      ) { [weak self] in
        // 系统给的后台时间到期时再立一次会话，别让换章停在半路。
        self?.ensurePlaybackIdentity()
      }
      guard let channel = self.channel else {
        self.pendingRemoteActions.append(action)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        return
      }
      // Dart isolate 被挂起时回执既不成功也不失败，动作会一直躺在引擎
      // 队列里，直到回前台才被消费。给一个短超时：收不到回执就缓存，
      // 等 ready / 回前台 / 下一次 update 补发。
      var acknowledged = false
      let ackTimeout = DispatchWorkItem { [weak self] in
        guard let self, !acknowledged else { return }
        FqNativeLog.log("[fqapp] remote action ack timeout: \(action)")
        self.pendingRemoteActions.append(action)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: ackTimeout)
      FqNativeLog.log("[fqapp] remote action send: \(action)")
      channel.invokeMethod("onRemoteAction", arguments: ["action": action]) {
        [weak self] result in
        guard let self else { return }
        acknowledged = true
        ackTimeout.cancel()
        if result is FlutterError {
          self.pendingRemoteActions.append(action)
        }
      }
      if task != .invalid {
        // 覆盖 Dart 切章、取流到新音频起播的窗口；新音频一起播，
        // audio 后台模式接手，不再依赖这段临时执行时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
          UIApplication.shared.endBackgroundTask(task)
        }
      }
    }
    if Thread.isMainThread {
      send()
    } else {
      DispatchQueue.main.async { send() }
    }
  }

  /// 冷启动 / 引擎重建期间缓存的远控动作，只在 Dart 接收者就绪后补发。
  private func drainPendingRemoteActions() {
    guard let channel, !pendingRemoteActions.isEmpty else { return }
    let queued = pendingRemoteActions
    pendingRemoteActions.removeAll()
    for action in queued {
      channel.invokeMethod("onRemoteAction", arguments: ["action": action])
    }
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      apply(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "ready":
      // Dart 已挂好 onRemoteAction 接收者，此时补发才有人接。
      drainPendingRemoteActions()
      result(nil)
    case "setAudioSource":
      let source = call.arguments as? [String: Any] ?? [:]
      installTimeline(
        urlString: source["url"] as? String ?? "",
        startMs: (source["startMs"] as? NSNumber)?.doubleValue ?? 0
      )
      result(nil)
    case "clear":
      // 保留暂停态卡片：音乐类 App 停止播放后控制中心仍留一张可重新唤起
      // 的卡片。只把速率与播放态写成 paused，元数据、远控注册、静音桥接
      // 全部保留 —— 过去「info=nil + endReceiving」留下的是一张有卡片却
      // 没有可唤起进程的幽灵会话，点主体自然进不了 App。锁屏不再附带
      // Live Activity 与本地通知。
      var paused = info
      paused[MPNowPlayingInfoPropertyPlaybackRate] = 0
      info = paused
      self.infoCenter.nowPlayingInfo = paused
      self.infoCenter.playbackState = .paused
      keepSessionActive()
      startSilentPlayback()
      applyCommandAvailability()
      FqNativeLog.log("[fqapp] now playing session paused")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ args: [String: Any]) {
    // 系统朗读没有音频地址时也要有真实时间线：退回本地静音轨，
    // 由 AVPlayer 而非 AVAudioPlayer 提供媒体客户端身份。
    if timelinePlayer == nil {
      installTimeline(urlString: "", startMs: 0)
    }
    let wasPublished = sessionPublished
    sessionPublished = true
    // 元数据刷新很频繁（切章、进度、15 秒心跳）。播放中只补会话活性、
    // 保活音轨与命令可用性；重设 category、重装远控 target 交给真实事件
    // 与 clear 后的首次发布，否则 AVPlayer 会被反复打断。
    activateSession()
    if wasPublished {
      // 15 秒心跳必须能把被插件 deactivate 的会话救回来：卡片上写着
      // playing 却没有真实音频输出时，系统不再把本 App 认作当前播放方，
      // 卡片主体点击就没有可唤起的目标。
      keepSessionActive()
      if silentPlayer?.isPlaying != true { startSilentPlayback(force: true) }
    } else {
      // clear 已完整退出远控响应链，这里首次发布时重新登记身份。
      ensurePlaybackIdentity()
    }
    applyCommandAvailability()

    let title = args["title"] as? String ?? ""
    let episode = args["episode"] as? String ?? ""
    let playing = args["playing"] as? Bool ?? false
    hasNext = args["hasNext"] as? Bool ?? true
    let positionMs = args["positionMs"] as? Double ?? 0
    let durationMs = args["durationMs"] as? Double ?? 0
    let speed = args["speed"] as? Double ?? 1
    // 切章取流窗口（durationMs=0）不是用户暂停：保持上一帧的播放速率，
    // 避免系统在这段音频真空里把本 App 从 Now Playing App 归属中撤销。
    let transientGap = !playing && durationMs <= 0
    let previousRate =
      (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?
        .doubleValue ?? speed
    let reportedRate =
      playing ? speed : (transientGap ? max(previousRate, speed) : 0)
    let coverUrl = args["coverUrl"] as? String ?? ""
    if durationMs > 0 { lastKnownDurationMs = durationMs }
    // 切章取流窗口 durationMs=0 时沿用上一章真实时长，不再写 1 小时占位，
    // 避免 nowPlayingInfo 在同一秒内被覆盖两次、卡片反复重绘。
    let duration = durationMs > 0
      ? durationMs
      : (lastKnownDurationMs > 0
          ? lastKnownDurationMs
          : NowPlayingChannel.placeholderDurationMs)

    var next: [String: Any] = [
      // 系统靠 mediaType 把会话归类成音频播放器；缺了它卡片不把本 App
      // 认成「正在播放」的一方，点主体也不唤起 App。
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      // 恒按「有进度的曲目」上报。声明成直播流会让控制中心把 ⏮ / ⏭
      // 换成 15 秒快退 / 快进，且系统不给该会话登记上一首 / 下一首。
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPNowPlayingInfoPropertyPlaybackRate: reportedRate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
      // duration 与 elapsed 必须成对下发，缺一项卡片可能显示却不把本 App
      // 登记成 Now Playing App，主体点击与 ⏮ / ⏭ 都会落空。
      MPMediaItemPropertyPlaybackDuration: duration / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime:
        min(max(positionMs, 0), duration) / 1000,
      MPMediaItemPropertyPersistentID:
        NSNumber(value: NowPlayingChannel.stableID(title)),
    ]
    // 队列字段让系统把会话识别成「有前后曲目的音频」而非单曲直播，两端
    // 按钮与主体归属才稳定。章节序号由 episode 变化累计，不动公共通道签名。
    if episode != lastEpisode {
      if !lastEpisode.isEmpty { queueIndex += 1 }
      lastEpisode = episode
    }
    next[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
    next[MPNowPlayingInfoPropertyPlaybackQueueCount] =
      queueIndex + (hasNext ? 2 : 1)
    if !title.isEmpty {
      next[MPMediaItemPropertyTitle] = title
      next[MPMediaItemPropertyAlbumTitle] = title
    }
    if !episode.isEmpty { next[MPMediaItemPropertyArtist] = episode }
    if let image = artwork ?? placeholderArtwork {
      next[MPMediaItemPropertyArtwork] = image
    }

    info = next
    self.infoCenter.nowPlayingInfo = next
    self.infoCenter.playbackState =
      reportedRate > 0 ? .playing : .paused
    applyStaticMetadata(next)
    if playing, timelinePlayer?.rate == 0 { timelinePlayer?.play() }
    applyCommandAvailability()
    loadArtwork(coverUrl)
    drainPendingRemoteActions()
    FqNativeLog.log(
      "[fqapp] now playing apply: playing=\(playing) rate=\(playing ? speed : 0)"
        + " duration=\(duration / 1000) published=\(wasPublished)"
        + " episode=\(episode)"
    )
  }

  // MARK: - 封面

  private func loadArtwork(_ urlString: String) {
    guard !urlString.isEmpty else { return }
    if urlString == artworkURL { return }
    artworkTask?.cancel()
    artworkURL = urlString
    guard let url = URL(string: urlString) else { return }
    artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        guard self.artworkURL == urlString else { return }
        self.artworkTask = nil
        self.artwork = artwork
        self.info[MPMediaItemPropertyArtwork] = artwork
        self.infoCenter.nowPlayingInfo = self.info
        self.applyStaticMetadata(self.info)
      }
    }
    artworkTask?.resume()
  }
}
