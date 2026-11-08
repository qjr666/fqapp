# iOS 版：构建与已知限制

仓库原本只有 Android / Windows 两个平台。iOS 端是后补的，当前目标是「能在 iPhone 上搜书、管书架、看小说」，不是全功能对齐 Android。

## 构建环境

| 组件 | 版本 | 备注 |
|---|---|---|
| macOS | 27.2+ | |
| Xcode | 27.2 | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| Flutter | **3.47.9** | Xcode 27 的适配补丁在 3.47.0 才进，别用 3.44.x 建 iOS |
| CocoaPods | 1.17.0 | `brew install cocoapods`（系统 Ruby 太旧，别用 gem 装） |
| Rust | 1.99.1 | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` |
| flutter_rust_bridge_codegen | 2.13.0 | 必须与 `rust/Cargo.toml` 里的版本一致 |

## 构建

```bash
flutter pub get
./scripts/build_rust_ios.sh          # Rust → ios/Frameworks/libfqapi_core.a
flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`（未签名）。

打包成未签名 IPA：

```bash
rm -rf /tmp/pack && mkdir -p /tmp/pack/Payload
ditto build/ios/iphoneos/Runner.app /tmp/pack/Payload/Runner.app
(cd /tmp/pack && zip -qry fqapp_ios_unsigned.ipa Payload)
```

## 签名

`DEVELOPMENT_TEAM` 不入库。首次构建前把它放进本地文件：

```bash
cp ios/Flutter/Signing.xcconfig.example ios/Flutter/Signing.xcconfig
# 把 DEVELOPMENT_TEAM 改成自己的 Team ID；该文件已被 ios/.gitignore 忽略
```

只要改 `Signing.xcconfig` 就够了，别在 Xcode 的 Signing 页里再选一次 Team——那样
Xcode 会把 `DEVELOPMENT_TEAM` 写回 `ios/Runner.xcodeproj/project.pbxproj`，让工程文件变脏。
`CODE_SIGN_STYLE` 仍是 Automatic，Team 由 xcconfig 供值。

装到真机可以走自签（免费 Apple ID 7 天有效，过期后 App 闪退，重新签一次即可）。
下面的命令按你自己的签名脚本替换：

```bash
BUNDLE_ID=com.fqapp.fqapp IPA=/tmp/pack/fqapp_ios_unsigned.ipa ./your-sign-script.sh
```

## iOS 专用改动（为什么需要）

1. **Rust 核心以静态库链接**。iOS 不允许从 App 包内 dlopen 共享库，所以：
   - `scripts/build_rust_ios.sh` 用 `--crate-type staticlib` 编出 `ios/Frameworks/libfqapi_core.a`（`CARGO_PROFILE_RELEASE_STRIP=debuginfo`，因为 release profile 的 `strip = true` 会裁掉符号）；
   - `ios/Flutter/{Debug,Release}.xcconfig` 追加三个必需设置：
     - `-force_load` 把静态库目标文件全部装进来；
     - `DEAD_CODE_STRIPPING = NO`，否则「只在运行时 dlsym」的符号会被 dead_strip 删掉；
     - `-Wl,-export_dynamic`，主可执行文件默认不导出全局符号，dlsym 会找不到 Rust 入口；
   - `lib/services/rust_bootstrap_io.dart` 在 iOS 上改用 `ExternalLibrary.process()`（接缝在 `lib/services/backend_transport.dart` 的 `runtimeInitializer`）。
2. **桌面专用依赖**（`webview_windows` / `smtc_windows` / `window_manager` / `screen_retriever`）不需要条件导入：它们都能在 iOS 上编译，运行时只在 `isWindowsDesktop` 分支调用。
3. **视频与听书走进程内适配器**：iOS 不写 Swift 插件，而是沿用 Windows 的
   `PlatformChannels.invoke/events` 注入点（`lib/services/platform_channel.dart`），
   由 `lib/services/ios_platform.dart` 在 `runApp` 之前接管两条自定义通道：
   - `fqapp/native_player` → media_kit（`media_kit_libs_ios_video` 提供 iOS 原生库），
     播放源是 Rust 回环服务的 `/_session/<cap>/src/*` 明文流；
   - `fqapp/system_tts` → `flutter_tts`（AVSpeechSynthesizer），pod 早已在
     `ios/Podfile.lock` 里。
   `native_player.dart` / `system_tts.dart` 的契约一行未改，渲染由
   `lib/services/video_surface.dart` 按平台分派（Android 用 `Texture`，
   Windows / iOS 用 media_kit 的 `Video`）。
4. **图标与应用名**：`scripts/generate_ios_app_icon.py` 从 `assets/branding/app_icon_source.png` 生成 1024 无 alpha 图标（复用 Android 生成器的「去纸张外框」逻辑），`CFBundleDisplayName` 设为「什锦铺」。
5. **关掉 Swift Package Manager**：`flutter config --no-enable-swift-package-manager`（Xcode 27 + SPM 有已知构建失败）。

## 已知限制

> 下面这套 iOS 播放/朗读实现是照既有 Windows 适配器的契约写的，**尚未经过
> iOS 编译与真机验证**。首次构建请以 `.github/workflows/ios-ipa.yml` 的日志为准。

- **视频与系统朗读已接入**，但以下能力在 iOS 没有原生实现，适配器返回中性值或
  走既有降级：悬浮窗、SMTC / 前台媒体卡片、亮度与音量手势、系统朗读设置跳转、
  WSOLA 变速引擎（改走 media_kit 内建变速与 `AVSpeechUtterance.rate`）。
- **加密片源不可用**：上游直连加密 URL 与 `file://` 离线缓存需要端上 CENC
  解密，而 Rust 的 `desktop_media` / `desktop_fetch` 被
  `#[cfg(target_os = "windows")]` 门住，还依赖只在 Windows 启用的
  `reqwest/blocking`，iOS 静态库里没有 `fq_desktop_media_open`。适配器会
  明确提示「该加密片源在 iOS 上暂不支持」。在线主路径 `/_session/<cap>/src/*`
  由服务端解密成明文，不受影响。要补齐需先在 Rust 侧放开这两个 cfg，并给
  iOS target 启用 `reqwest` 的 blocking feature。
- `media_kit_libs_ios_video` 固定在 1.1.4（2023 年的预编译 xcframework），
  Xcode 27 / iOS 27 SDK 的兼容性需在 CI 上确认；链接失败时不要改用
  `media_kit_libs_video` umbrella，那会破坏 Android 包体约束。
- `Info.plist` 已加 `NSAllowsLocalNetworking`（Rust 回环 HTTP）与
  `UIBackgroundModes: audio`（后台听书），后台行为仍需真机验证。
- 分享、导入导出、LAN 分享、番茄书架导入等只在 Android 上验证过。
- 免费 Apple ID 签名 7 天过期，过期后 App 闪退，重跑一次自签脚本即可。

## 与 Android 构建的关系

iOS 需要 Flutter 3.47+（Xcode 27 适配），因此 `pubspec.lock` 的传递依赖被一并升级到
3.47.9 能解析的版本，Android / Windows 的 CI 也统一到 3.47.9（见 `chore(deps)` 那个
commit）。若上游要保留旧 SDK，把那一个 commit 整体回退、再在 3.44.6 上重新生成
`pubspec.lock` 即可，iOS 侧的改动不受影响。
