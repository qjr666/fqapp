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
   - `fqapp/native_player` → media_kit（`media_kit_libs_ios_video` 提供 iOS 原生库，
     CI 产物里可见 `Payload/Runner.app/Frameworks/Mpv.framework`）；
   - `fqapp/system_tts` → `flutter_tts`（AVSpeechSynthesizer）。iOS 必须显式
     `setSharedInstance(true)` + `setIosAudioCategory(playback, …)` +
     `autoStopSharedSession(false)`，否则静音键一开朗读完全无声；还要按 FIFO
     管理预排的两句 utterance，否则 `done` 事件 id 错位会让朗读卡住。
   `native_player.dart` / `system_tts.dart` 的契约一行未改，渲染由
   `lib/services/video_surface.dart` 按平台分派（Android 用 `Texture`，
   Windows / iOS 用 media_kit 的 `Video`）。
4. **iOS 取流不带 `mode=stream`**：`episode_source_cache.dart` 的
   `videoContentMode` 在 iOS 返回 `null`。带 `mode=stream` 时 Rust 会把**上游直连
   的 CENC 加密地址 + key_hex** 原样返回（`video.rs:180-193`），而 iOS 没有端上
   解密能力，播放必然失败。去掉 mode 后 Rust 走 `download_and_save`，返回
   `/src/<id>.mp4`（无 key_hex），`ApiClient.absoluteUrl` 补上
   `/_session/<cap>/` 前缀，`serve_src_file` 按 Range 解密成明文再交给播放器。
   代价是**首次起播要等服务端把整集缓存完**；Android / Windows 仍用 stream。
   `VIDEO_DOWNLOAD_TIMEOUT` 相应从 15 秒放宽到 120 秒，`ApiClient` 对这条取流
   用 180 秒超时——否则整集还没下完请求就被取消，Rust 会静默回退成加密直连。
5. **听书音频走 `mode=plain`**：智能朗读 / 真人讲书的 playinfo
   (`/api/v1/audio/books/{id}/chapters/{cid}`) 同样只补 `key_hex`、返回上游
   加密直连地址。`audioContentMode` 在 iOS 传 `mode=plain`，Rust 的
   `audio.rs::handle_chapter_info` 复用 `video.rs` 的 `download_and_save` 把整章
   缓存进 `src/`（音频是单文件 ISO-BMFF + `enca` AAC 轨，CENC 解密代码原生
   支持 `enca→mp4a`），返回不带 `encrypt_info` 的
   `{"code":0,"data":[{"main_url":"/src/…"}]}`，`parsePlayinfoSource` 直接走
   明文分支。
   - `encrypted_audio_candidates` 同时接受 `data[].video_model` 与
     `data.video_model_datas[].video_model` 两种信封；只在 `media_type` 明确为
     `video` 时跳过；`key_hex` 缺失时现场从 `spade_a` 再派生一次；并收集
     `main_url` + `backup_url` 逐个重试（每个候选独立缓存 id）。真人讲书与
     智能朗读只是 `tone_id` 不同，上游会返回不同结构的流，早期「只认第一条
     且必须是 audio」的实现会让智能朗读漏匹配。
   - 真正明文的流（无加密流候选）保留原响应直连播放。**找到加密流但全部
     缓存失败时不再静默回退加密直连地址**——iOS 解不开，只会得到一句无意义
     的「播放出错」——改为返回 `code 4903 / IOS_AUDIO_CACHE_FAILED`，
     `audio_play_error.dart` 把它与 iOS 适配器的 4901 / 4902 一起映射成
     可操作的具体文案。
6. **图标与应用名**：`scripts/generate_ios_app_icon.py` 从 `assets/branding/app_icon_source.png` 生成 1024 无 alpha 图标（复用 Android 生成器的「去纸张外框」逻辑），`CFBundleDisplayName` 设为「什锦铺」。
7. **关掉 Swift Package Manager**：`flutter config --no-enable-swift-package-manager`（Xcode 27 + SPM 有已知构建失败）。

## 已知限制

> 首个 IPA（run 42497981164）已在 Xcode 27.2 / `xcode-27` runner 上**编译通过**
> 并成功真机自签安装；真机反馈「短剧全部播放失败 / 没法听书」后的两轮修复
> **仍需再跑一轮 CI 与真机复测**确认。第二轮含 Rust 改动，未经本机编译
> （Windows 无 Rust / Flutter 工具链），以 CI 日志为准。

- **在线短剧**：已改走服务端缓存 + 按 Range 解密的明文流，首次起播需等整集
  缓存完成（比 Android 慢）。若 Rust 缓存失败会回退成加密直连地址，此时
  适配器发 `errorCode 4901`，界面显示「该片源暂不支持」而不是笼统的
  「播放失败」（见 `playback_issue.dart`）。
- **智能朗读 / 真人讲书**：第二轮包（run 42505749165）真机反馈「真人讲书已能播，
  智能朗读仍提示播放出错，只能用系统朗读」。两者共用同一条 playinfo 请求、
  只是 `tone_id` 不同，因此最可能是上游对合成音色返回了另一形状 / 另一 CDN
  的流，早期只取第一条加密流的匹配漏掉了它。第三轮已放宽信封与字段匹配、
  补 `backup_url` 重试，并把 4901 / 4902 / 4903 映射成具体文案——**若仍有
  问题，屏幕上的新文案可直接区分「服务端没解出来」与「播放器没加载出来」**。
  首次起播需等整章缓存完。系统朗读（本地 `flutter_tts`）是独立链路。
- **离线加密缓存仍不可用**：`file://` + keyHex 需要端上 CENC 解密，而
  `desktop_media` / `desktop_fetch` 被 `#[cfg(target_os = "windows")]` 门住，
  iOS 静态库里没有 `fq_desktop_media_open`。同样走 4901 明确提示。要补齐需
  在 Rust 侧放开这两个 cfg 并给 iOS target 启用相应 feature。
- **系统朗读**：已配置 AVAudioSession（静音键不再静音）、按 FIFO 发
  `start` / `range` / `done`；但 WSOLA 变速引擎、系统朗读设置跳转、音频焦点
  事件仍走既有降级，改由 `AVSpeechUtterance.rate` 与 media_kit 内建变速承担。
- **其余降级**：悬浮窗、SMTC / 前台媒体卡片、亮度与音量手势在 iOS 返回中性值。
- `Info.plist` 已加 `NSAllowsLocalNetworking`（Rust 回环 HTTP）与
  `UIBackgroundModes: audio`；App 挂起后 tokio listener 会停止 accept，
  后台连续播放/朗读仍可能断流。
- `ios/Podfile.lock` 已同步为 CI 生成的版本（含 `media_kit_libs_ios_video 1.0.4`）。
  `media_kit_libs_ios_video` 的 pub 版本固定在 1.1.4；不要改用
  `media_kit_libs_video` umbrella，那会把全平台 libmpv 打进 Android APK。
- 首页「推荐 / 小说」排行榜已强制走 `HomeRankShelf(flat: true)`，直接显示
  圆角封面，`NO.00N` 名次、信息行与翻页器保留。
- 分享、导入导出、LAN 分享、番茄书架导入等只在 Android 上验证过。
- 免费 Apple ID 签名 7 天过期，过期后 App 闪退，重跑一次自签脚本即可。

## 与 Android 构建的关系

iOS 需要 Flutter 3.47+（Xcode 27 适配），因此 `pubspec.lock` 的传递依赖被一并升级到
3.47.9 能解析的版本，Android / Windows 的 CI 也统一到 3.47.9（见 `chore(deps)` 那个
commit）。若上游要保留旧 SDK，把那一个 commit 整体回退、再在 3.44.6 上重新生成
`pubspec.lock` 即可，iOS 侧的改动不受影响。
