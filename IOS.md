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
     `main_url` + `backup_url` 逐个重试。真人讲书与智能朗读只是 `tone_id`
     不同，上游会返回不同结构的流，早期「只认第一条且必须是 audio」的
     实现会让智能朗读漏匹配。
   - **两种信封都必须补 `key_hex`**：`patch_playinfo_keys` 只处理 `data[]`，
     `patch_encrypted_audio_keys` 只处理 `data.video_model_datas[]`，章节接口
     两者都要跑。只做其中之一时，另一种信封的音色拿不到 `key_hex`，核心与
     Dart 两侧都会认为「没有可播的流」。
   - **回环服务的取流预算**：`server.rs` 给每个请求 20 秒的通用预算，而取流
     必须先把整集 / 整章下载并落盘（iOS 没有端上 CENC 解密）。短剧一集勉强
     够，整章有声书必然下不完，于是被判缓存失败。`/api/v1/videos/` 与
     `/api/v1/audio/books/…/chapters/` 两条路由改用 300 秒预算，其余请求
     保持 20 秒；音频的下载超时同样从 120 秒放宽到 300 秒。
   - **缓存 id 复用**：第一个候选沿用旧 id（`audio_<chapter>_<tone>`），设备上
     还留着上一版缓存的同名文件时直接命中；后续候选才带序号后缀。
   - **明文兜底**：带密钥的候选全部失败后，用空密钥再下载一次。有些音色标称
     `encrypt=true` 实际并未加密，空密钥缓存不写 key sidecar，播放器可以直接
     播放原始字节。
   - **失败带原因**：4903 的 message 现在带脱敏后的真实原因
     （如 `IOS_AUDIO_CACHE_FAILED: download video: HTTP 403`），
     `audio_play_error.dart` 直接显示原因，真机反馈能一眼定位。
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
- **智能朗读 / 真人讲书**：第三轮包（run 42544196720）真机反馈「真人讲书从能播
  变成不能播（4903），智能朗读仍提示播放出错，只能用系统朗读」。查下来是两个
  独立问题：
  1. **回环服务给每个请求只有 20 秒预算**（`server.rs`），而取流必须先把整章
     下载并落盘——短剧一集勉强够，整章有声书必然下不完，于是被判缓存失败。
     第四轮把 `/api/v1/videos/` 与 `/api/v1/audio/books/…/chapters/` 放宽到
     300 秒，音频下载超时也从 120 秒放宽到 300 秒。
  2. **两种信封只有一种补了 `key_hex`**：`patch_playinfo_keys` 处理 `data[]`，
     `patch_encrypted_audio_keys` 处理 `data.video_model_datas[]`，而章节接口
     原来只调用前者——智能朗读走的是后者，于是拿不到密钥、被 Dart 侧判成
     「没有可播的流」，最终落到笼统的「播放出错」。第四轮在章节接口里两种都
     跑，并补了针对两种信封的回归测试。
  此外第四轮还：复用旧缓存 id（设备上可能还留着能播的那份）、加空密钥的明文
  兜底、失败时把脱敏后的真实原因带给界面。首次起播需等整章缓存完。系统朗读
  （本地 `flutter_tts`）是独立链路。
- **智能朗读 / 真人讲书**：第四轮包（run 42547362598）真机反馈：
  - 真人讲书：`这个声音暂时无法在 iPhone 上播放（download video: error sending
    request for url (<url>)）` —— 诊断信息生效了，但原因是 reqwest 在**传输层**
    就断了，不是 HTTP 403、也不是超时。
  - 智能朗读：仍是笼统的「播放出错」—— 走的是另一条路：信封没被识别成候选，
    于是核心**静默落回**加密直连地址，Dart 侧解析不了那个信封。

  查下来的三个结论（第五轮改动）：
  1. **`error sending request` 是 reqwest 对所有传输层故障的统一文案**
     （TLS / DNS / 连接被重置 / 超时都长这样）。第五轮把错误链展开成
     `host=… | timeout | <cause>`，并把脱敏从「抹掉整个 URL」改成「保留域名、
     丢掉带签名的路径与查询串」——域名正是区分两种故障的关键。
  2. **同一个地址，苹果网络栈能下、Rust 的 reqwest 不能**。苹果栈有 Happy
     Eyeballs（IPv6 失败立刻回退 IPv4），hyper 没有；reqwest 的 TLS 走
     `rustls-platform-verifier`（系统信任库）。第五轮给下载加了三段递进
     兜底：默认（h2）→ HTTP/1.1 + 浏览器请求头 → 再强制 IPv4（本地地址绑到
     `0.0.0.0`）。每段失败都很快，走完不增加等待。
  3. **服务端缓存失败时必须落回加密直连地址**。真人讲书的「加密」标记早已
     失效，直连地址在 iPhone 上本来就能播——第三轮把这条静默兜底换成硬报错
     4903，正是「真人讲书从能播变成不能播」的回归。第五轮在 Dart 侧恢复：
     `mode=plain` 收到 4903 时，退回不带 `mode` 的原始答案再试一次；兜底也
     失败才把 4903 的真实原因抛给界面。
  另外核心现在能区分「真的没有加密流」与「有加密流但没认出来」：后者不再
  静默落回，而是显式报 4903 + 「未能识别其结构」。
  为拿到真机截图答不出的信息，第五轮加了 `rust/tests/audio_live_probe.rs`：
  它对着真实上游取一次音频章节，打印信封结构、音频地址（去查询串）与传输层
  的真实失败原因，并在 Android 工作流里以 `continue-on-error` 方式跑。
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
