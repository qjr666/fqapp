import Flutter
import MediaPlayer
import UIKit
import UniformTypeIdentifiers
import UserNotifications

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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
            NSLog("[fqapp] notification authorization failed: \(error)")
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

/// `fqapp/ios_now_playing`：把当前在读/在听的内容发布成系统媒体元数据，
/// 并把锁屏、控制中心、灵动岛上的播放控制回抛给 Dart。
///
/// iOS 没有 Android 那套「通知栏媒体卡片」，但有等价的系统能力：
/// `MPNowPlayingInfoCenter` 负责锁屏 / 控制中心 / 灵动岛上的播放器卡片，
/// `MPRemoteCommandCenter` 负责播放、暂停、切章、停止。两边都要求音频会话
/// 处于 `playback` 类别且 App 正在发声，否则系统一个卡片都不显示。
///
/// 元数据字段与 Android 的媒体会话对齐（`ListenKeepAliveService`）：
/// title = 书名，artist = 章节名，封面图 = 书籍封面。
final class NowPlayingChannel {
  private var channel: FlutterMethodChannel?
  private var artworkTask: URLSessionDataTask?
  private var artworkURL: String?
  private var artwork: MPMediaItemArtwork?
  /// 最近一次下发的元数据：封面下载完成后要拿它整体重发一次。
  private var info: [String: Any] = [:]

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "fqapp/ios_now_playing",
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
    configureRemoteCommands()
  }

  /// 远控按钮。系统控制中心与锁屏上的「播放 / 暂停」是**两个**命令，
  /// 这里分别回传 `play` / `pause` —— 不能都当成切换：正在播放时点「播放」
  /// 应该是继续，而不是暂停。Android 那边只有一枚 playPause 按钮，
  /// Dart 侧按同一套动作名处理两个平台。
  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    // 引擎可能重建、register 被调用多次：先摘掉本 App 之前的 target。
    center.playCommand.removeTarget(nil)
    center.pauseCommand.removeTarget(nil)
    center.togglePlayPauseCommand.removeTarget(nil)
    center.nextTrackCommand.removeTarget(nil)
    center.previousTrackCommand.removeTarget(nil)
    center.stopCommand.removeTarget(nil)
    center.skipForwardCommand.removeTarget(nil)
    center.skipBackwardCommand.removeTarget(nil)

    center.playCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("play")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("pause")
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("playPause")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("next")
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("prev")
      return .success
    }
    center.stopCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("stop")
      return .success
    }
    // 锁屏 / 控制中心 / 灵动岛展开卡片对有声书类内容给的是「快进 / 快退」
    // 两枚按钮（skipForward / skipBackward），不是 nextTrack / previousTrack。
    // 只注册后者时用户按到的那一枚什么也不发，看起来就是「切不了下一章」。
    center.skipForwardCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("next")
      return .success
    }
    center.skipBackwardCommand.addTarget { [weak self] _ in
      self?.sendRemoteAction("prev")
      return .success
    }
  }

  private func sendRemoteAction(_ action: String) {
    // MPRemoteCommandCenter 的回调不保证在主线程，而 FlutterMethodChannel
    // 只能在主线程发消息。后台收到远控时走错线程，动作会石沉大海。
    if Thread.isMainThread {
      channel?.invokeMethod("onRemoteAction", arguments: ["action": action])
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.channel?.invokeMethod(
          "onRemoteAction",
          arguments: ["action": action]
        )
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      apply(args)
      result(nil)
    case "clear":
      artworkTask?.cancel()
      artworkTask = nil
      artworkURL = nil
      artwork = nil
      info = [:]
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 把一次播放状态写成系统媒体元数据。
  ///
  /// `positionMs` 与 `durationMs` 必须一起给：系统按这两个值外推进度条，
  /// 只给一个会让卡片两侧的时间对不上。
  private func apply(_ args: [String: Any]) {
    let title = args["title"] as? String ?? ""
    let episode = args["episode"] as? String ?? ""
    let playing = args["playing"] as? Bool ?? false
    let hasPrev = args["hasPrev"] as? Bool ?? true
    let hasNext = args["hasNext"] as? Bool ?? true
    let positionMs = args["positionMs"] as? Double ?? 0
    let durationMs = args["durationMs"] as? Double ?? 0
    let speed = args["speed"] as? Double ?? 1
    let coverUrl = args["coverUrl"] as? String ?? ""

    var next: [String: Any] = [:]
    if !title.isEmpty { next[MPMediaItemPropertyTitle] = title }
    if !episode.isEmpty {
      next[MPMediaItemPropertyArtist] = episode
      next[MPMediaItemPropertyAlbumTitle] = episode
    }
    if durationMs > 0 { next[MPMediaItemPropertyPlaybackDuration] = durationMs / 1000 }
    if positionMs > 0 { next[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionMs / 1000 }
    next[MPNowPlayingInfoPropertyPlaybackRate] = playing ? speed : 0
    next[MPNowPlayingInfoPropertyDefaultPlaybackRate] = speed
    if let artwork = artwork { next[MPMediaItemPropertyArtwork] = artwork }

    info = next
    MPNowPlayingInfoCenter.default().nowPlayingInfo = next
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused

    let center = MPRemoteCommandCenter.shared()
    center.previousTrackCommand.isEnabled = hasPrev
    center.nextTrackCommand.isEnabled = hasNext
    center.skipBackwardCommand.isEnabled = hasPrev
    center.skipForwardCommand.isEnabled = hasNext

    loadArtwork(coverUrl)
  }

  /// 封面图：锁屏卡片没有图就只剩一行字，观感差很多。
  ///
  /// 下载是异步的，拿到图后要把整份元数据重发一次；同一个 URL 不重复下载。
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
        // 下载期间可能已经切到别的内容了：只认最后一次请求的 URL。
        guard self.artworkURL == urlString else { return }
        self.artworkTask = nil
        self.artwork = artwork
        self.info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
      }
    }
    artworkTask?.resume()
  }
}
