import Flutter
import UIKit

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
