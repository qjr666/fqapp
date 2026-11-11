import AVFoundation
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
    // Apple 要求 UNUserNotificationCenter.delegate 在
    // didFinishLaunchingWithOptions 返回之前挂好：冷启动时点通知进 App，
    // 系统在这个方法结束就开始找处理者，晚一步通知点击就没人接。
    nowPlayingChannel.installNotificationDelegate()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 通知条目点进来时用的自有 URL scheme（Info.plist 里声明 `fqapp`）。
  /// 自己消费掉，别再交给插件链去猜一个不存在的深链。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any]
  ) -> Bool {
    if url.scheme == "fqapp" { return true }
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
    // 插件注册阶段可能有别的插件抢过通知 delegate，这里再挂回来。
    nowPlayingChannel.installNotificationDelegate()
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

/// `fqapp/ios_now_playing`：iOS 标准 Now Playing 媒体会话。
///
/// 音乐类 App 在锁屏 / 通知中心 / 控制中心里那张带 ⏮ ⏯ ⏭ 的「播放器」，
/// 由系统按 Now Playing App 渲染，第三方 App 不能自己画一张通知出来替代它。
/// 因此这一层只负责把本 App 稳定登记成 Now Playing App，并把系统派下来的
/// 远控动作交给 Dart：
/// - `AVAudioSession`：独占 playback、常驻 active，是登记身份的前提；
/// - 后台静音音轨：换章 / 取流间隙保持音频渲染，避免进程被挂起；
/// - `MPNowPlayingInfoCenter`：完整、合法的媒体条目（非直播流）；
/// - `MPRemoteCommandCenter`：上一首 / 下一首等远控，target 只挂自己的；
/// - `UNUserNotificationCenter`：可点击回到 App 的常驻通知条目与切章动作。
final class NowPlayingChannel: NSObject, UNUserNotificationCenterDelegate {
  private static let channelName = "fqapp/ios_now_playing"
  private static let notificationID = "fqapp.nowplaying"
  private static let categoryID = "fqapp.playback"
  private static let actionPrev = "fqapp.action.prev"
  private static let actionPlayPause = "fqapp.action.playPause"
  private static let actionNext = "fqapp.action.next"
  private static let actionOpen = "fqapp.action.open"
  /// 系统朗读没有真实时长，给一个有限占位，让卡片是「有进度的曲目」
  /// 而不是直播流 —— 直播流会把 ⏮ / ⏭ 换成 15 秒快退 / 快进。
  private static let placeholderDurationMs = 3_600_000.0

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
  private var hasPrev = true
  private var hasNext = true
  private var lastNotificationTitle = ""
  private var lastNotificationEpisode = ""
  private var notificationNeedsRefresh = true
  /// 后台通知动作可能早于 Flutter 隐式引擎桥接完成，先缓存再补发。
  private var pendingRemoteActions: [String] = []

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
    let queued = pendingRemoteActions
    pendingRemoteActions.removeAll()
    for action in queued {
      channel.invokeMethod("onRemoteAction", arguments: ["action": action])
    }
    installRemoteTargets()
    UIApplication.shared.beginReceivingRemoteControlEvents()
    observeSystemEvents()
    // 冷启动不激活 playback 会话，避免抢走用户正在听的音乐；第一次起播
    // （apply）再激活。
  }

  /// Apple 要求通知 delegate 与 category 在 didFinishLaunchingWithOptions
  /// 返回之前挂好：冷启动点通知进 App 时，系统这时就开始找处理者。
  /// category 以**投递时**的内容为准，事后重设不会给旧条目补按钮。
  func installNotificationDelegate() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let actions = [
      UNNotificationAction(identifier: NowPlayingChannel.actionPrev, title: "上一首", options: []),
      UNNotificationAction(identifier: NowPlayingChannel.actionPlayPause, title: "播放 / 暂停", options: []),
      UNNotificationAction(identifier: NowPlayingChannel.actionNext, title: "下一首", options: []),
      // .foreground：系统负责把 App 从后台拉回前台。
      UNNotificationAction(
        identifier: NowPlayingChannel.actionOpen,
        title: "打开应用",
        options: [.foreground]
      ),
    ]
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: NowPlayingChannel.categoryID,
        actions: actions,
        intentIdentifiers: [],
        options: []
      )
    ])
    notificationNeedsRefresh = true
  }

  // MARK: - UNUserNotificationCenterDelegate

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // 只进通知中心、不弹横幅：前台界面里已有播放器，后台下拉必须看得到
    // 这一条，且它得带着切章按钮。回空数组系统连通知中心都不写。
    completionHandler([.list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    switch response.actionIdentifier {
    case NowPlayingChannel.actionPrev:
      sendRemoteAction("prev")
    case NowPlayingChannel.actionPlayPause:
      sendRemoteAction("playPause")
    case NowPlayingChannel.actionNext:
      sendRemoteAction("next")
    case NowPlayingChannel.actionOpen:
      // .foreground action：系统已经负责把 App 拉回前台。
      break
    case UNNotificationDefaultActionIdentifier:
      // 点通知主体。按 Apple 的通知交互约定，default action 由系统把 App
      // 从后台带回前台；delegate 只恢复会话并尽快结束 response。
      break
    default:
      break
    }
    if sessionPublished { ensurePlaybackIdentity() }
    completionHandler()
  }

  // MARK: - 会话身份

  /// 独占 playback + active 的会话是系统把本 App 登记为 Now Playing App
  /// 的必要条件；带 mixWithOthers 的会话不会被登记，卡片主体点击就没有
  /// 可唤起的目标，⏮ / ⏭ 也会派给上一个播放方。
  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .playback ||
         session.categoryOptions.contains(.mixWithOthers) {
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.allowBluetoothA2DP]
        )
      }
      try session.setActive(true, options: [])
    } catch {
      NSLog("[fqapp] audio session activate failed: \(error)")
    }
  }

  /// 章末换章、下一集取流的间隙播放器会完全静下来，iOS 随即挂起 App：
  /// Dart 的切章与取流全部冻结。循环一段极低幅度的音轨让音频渲染管线
  /// 一直运行，这是后台音频 App 的标准做法。采样值不能全为 0 —— 全零
  /// 输出会被 CoreAudio 判成无音频活动，系统就不把本 App 记为正在播放。
  private func startSilentPlayback() {
    guard sessionPublished else { return }
    if silentPlayer?.isPlaying == true { return }
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
        NSLog("[fqapp] silent playback did not start")
      }
    } catch {
      NSLog("[fqapp] silent playback unavailable: \(error)")
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
      ) { [weak self] _ in
        guard let self, self.sessionPublished else { return }
        self.ensurePlaybackIdentity()
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
        let type = AVAudioSession.InterruptionType(rawValue: raw),
        type == .ended
      else { return }
      self.ensurePlaybackIdentity()
    }
  }

  // MARK: - MPRemoteCommandCenter

  /// 用 self + selector 挂 target，才能 `removeTarget(self)` 精确重装：
  /// 既不会叠加，也不会误删别的组件挂的 target。skip / seek / rating 等
  /// 一律禁用且不挂 target，否则控制中心会把「上一首 / 下一首」换成
  /// 15 秒快退 / 快进。
  private func installRemoteTargets() {
    let center = MPRemoteCommandCenter.shared()
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
    sendRemoteAction("next")
    return .success
  }

  @objc private func onPreviousTrackCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("prev")
    return .success
  }

  @objc private func onStopCommand(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
    sendRemoteAction("stop")
    return .success
  }

  private func applyCommandAvailability() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.stopCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = hasPrev
    center.nextTrackCommand.isEnabled = hasNext
    center.skipBackwardCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
  }

  private func sendRemoteAction(_ action: String) {
    // 远控回调不保证在主线程，FlutterMethodChannel 只能在主线程发消息。
    // 后台按键时先恢复音频渲染，Apple 才继续给本 App 派发远控和后台
    // 执行时间，Dart 的切章取流才不会被冻结。
    let send: () -> Void = { [weak self] in
      guard let self else { return }
      self.activateSession()
      self.startSilentPlayback()
      let task = UIApplication.shared.beginBackgroundTask(
        withName: "fqapp.remote.\(action)"
      ) {}
      guard let channel = self.channel else {
        self.pendingRemoteActions.append(action)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        return
      }
      channel.invokeMethod("onRemoteAction", arguments: ["action": action])
      if task != .invalid {
        // 覆盖 Dart 切章、取流到新音频起播的窗口；新音频一起播，
        // audio 后台模式接手，不再依赖这段临时执行时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
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

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      apply(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "clear":
      artworkTask?.cancel()
      artworkTask = nil
      artworkURL = nil
      artwork = nil
      info = [:]
      sessionPublished = false
      removeNotification()
      stopSilentPlayback()
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      // 不调 endReceivingRemoteControlEvents()：退出远控响应链后系统不再
      // 把本 App 记为候选的 Now Playing App，后台卡片主体点击无目标、
      // ⏮ / ⏭ 会被派给上一个播放方。远控注册全程保留。
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ args: [String: Any]) {
    sessionPublished = true
    ensurePlaybackIdentity()

    let title = args["title"] as? String ?? ""
    let episode = args["episode"] as? String ?? ""
    let playing = args["playing"] as? Bool ?? false
    hasPrev = args["hasPrev"] as? Bool ?? true
    hasNext = args["hasNext"] as? Bool ?? true
    let positionMs = args["positionMs"] as? Double ?? 0
    let durationMs = args["durationMs"] as? Double ?? 0
    let speed = args["speed"] as? Double ?? 1
    let coverUrl = args["coverUrl"] as? String ?? ""
    let duration = durationMs > 0
      ? durationMs
      : NowPlayingChannel.placeholderDurationMs

    var next: [String: Any] = [
      // 系统靠 mediaType 把会话归类成音频播放器；缺了它卡片不把本 App
      // 认成「正在播放」的一方，点主体也不唤起 App。
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      // 恒按「有进度的曲目」上报。声明成直播流会让控制中心把 ⏮ / ⏭
      // 换成 15 秒快退 / 快进，且系统不给该会话登记上一首 / 下一首。
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
      // duration 与 elapsed 必须成对下发，缺一项卡片可能显示却不把本 App
      // 登记成 Now Playing App，主体点击与 ⏮ / ⏭ 都会落空。
      MPMediaItemPropertyPlaybackDuration: duration / 1000,
      MPNowPlayingInfoPropertyElapsedPlaybackTime:
        min(max(positionMs, 0), duration) / 1000,
    ]
    if !title.isEmpty {
      next[MPMediaItemPropertyTitle] = title
      next[MPMediaItemPropertyAlbumTitle] = title
    }
    if !episode.isEmpty { next[MPMediaItemPropertyArtist] = episode }
    if let image = artwork ?? placeholderArtwork {
      next[MPMediaItemPropertyArtwork] = image
    }

    info = next
    MPNowPlayingInfoCenter.default().nowPlayingInfo = next
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    applyCommandAvailability()
    updateNotification(title: title, episode: episode)
    loadArtwork(coverUrl)
  }

  // MARK: - 通知栏

  /// 固定 identifier 的本地通知：重复 add 会替换同一条，不会堆积；点主体
  /// 由系统带回 App，delegate 里恢复媒体会话。
  private func updateNotification(title: String, episode: String) {
    guard !title.isEmpty else { return }
    if !notificationNeedsRefresh &&
       title == lastNotificationTitle &&
       episode == lastNotificationEpisode { return }
    lastNotificationTitle = title
    lastNotificationEpisode = episode
    notificationNeedsRefresh = false
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let status = settings.authorizationStatus
      guard status == .authorized || status == .provisional || status == .ephemeral else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = episode.isEmpty ? "正在播放" : episode
      content.threadIdentifier = NowPlayingChannel.notificationID
      // category 决定展开后的上一首 / 下一首按钮；不设的话通知栏里只有
      // 一条纯文本，按哪里都切不了章。
      content.categoryIdentifier = NowPlayingChannel.categoryID
      content.userInfo = ["nowPlaying": true]
      content.interruptionLevel = .passive
      let request = UNNotificationRequest(
        identifier: NowPlayingChannel.notificationID,
        content: content,
        trigger: nil
      )
      DispatchQueue.main.async {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
      }
    }
  }

  private func removeNotification() {
    lastNotificationTitle = ""
    lastNotificationEpisode = ""
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: [NowPlayingChannel.notificationID]
    )
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: [NowPlayingChannel.notificationID]
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = self.info
      }
    }
    artworkTask?.resume()
  }
}
