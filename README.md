# PanPanCamera · PanPan

PanPanCamera 是原生 iOS 美颜相机，当前 **0.1.0 仍处于基础架构阶段**。后续目标是在设备端提供主流美颜相机的美肌、美型与照片编辑能力。UI、命名和素材采用 PanPan 自己的设计，不复制其他 App；当前重点是清晰工程结构、真实相机与拍照路径、多语言和本地处理边界。

**当前版本不使用任何外部 AI API。Photos / Camera processing should remain on-device.** 没有照片上传、网络客户端、账号、后端、数据库、订阅、内购、广告、第三方 SDK 或第三方素材。

## 开发环境与打开方式

- iPhone、iOS 17.0+；首版 UI 固定竖屏，照片方向跟随设备物理旋转。
- Xcode 15+ / Swift 5.9+ 工具链，以 Swift 5 语言模式编译。
- SwiftUI、AVFoundation、Vision、Foundation、Combine、UIKit 和 ImageIO，全部为 Apple 原生框架。
- 直接打开 `PanPanCamera.xcodeproj`，选择共享的 `PanPanCamera` scheme。
- 没有 CocoaPods、Carthage、Swift Package 依赖、工程生成器安装步骤或服务器。
- 真机开发时，在 Signing & Capabilities 选择自己的 Team。仓库不包含个人 Team、证书、描述文件或 Secrets。当前工程实际 bundle identifier 为 `com.songlabs.PanPanCamera`；发布配置与 Apple App ID 必须匹配这个值。
- 首版没有制作发行用 App Icon；当前系统开发占位图标不代表最终品牌图标。界面图标使用 SF Symbols，粉色与组件布局在本仓库定义。

## Version 0.1 范围

“已实现”指代码路径和界面已建立；Apple SDK 编译、XCTest 的证据见对应提交的 GitHub Actions，真机行为仍需单独验收。

| 功能 | 当前实现 |
| --- | --- |
| 启动入口 | 直接进入 CameraView，没有首页、内容流或额外引导页 |
| 实时预览 | AVCaptureSession + AVCaptureVideoPreviewLayer，全屏 aspect fill |
| 人脸检测 | 本地 Vision 视频帧限频检测，输出全部人脸框及可选基础 landmarks；Apple Build 和真机验收待当前提交验证 |
| 相机权限 | 请求、授权、拒绝、系统限制说明；拒绝后可打开系统设置 |
| 前后切换 | 实际替换 AVCaptureDeviceInput；检查硬件、切换期间禁用竞争操作、失败回退 |
| 前后台 | 复用一个会话；非活跃或结果预览时停止，返回时恢复；处理中断与运行错误 |
| Flash | 按硬件/输出支持循环 Off / Auto / On，通过照片设置实际使用闪光灯；无硬件支持时禁用 |
| 拍照 | AVCapturePhotoOutput 正式拍照；原始 Data + 后台生成方向正确的预览图，结果仅保存在内存 |
| 主界面 | 半透明圆角顶部栏、白色/半透明底栏、柔粉色中央快门、照片模式 |
| 美肌 | 自动、磨皮、美白、肤色、祛痘、黑眼圈；各有独立 0–100 参数，默认 50 |
| 美型 | 在美肌面板切换至顔補正/美型，包含自动、瘦脸、脸宽、下巴、额头、颧骨、大眼、眼距、眼高、鼻宽、鼻长、嘴型、嘴宽 |
| 滤镜 | Original / Natural / Clear / Warm / Cool 本地化预设选择骨架 |
| 美妆 | Lip / Blush / Eye / Brow 本地化类别选择骨架 |
| Settings | 隐私与版本范围说明；没有虚假的功能开关 |
| 未实现入口 | 比例、Timer、相册点击后说明当前限制；视频、人像显示未支持且禁用 |
| 五语言 | UI、无障碍文字、权限说明与品牌名称 |
| Debug Screenshot Mode | 固定 SwiftUI 测试背景和页面参数；绕过真实相机与权限 |
| GitHub Actions | iOS CI、手动 Simulator Screenshot、TestFlight 交付基础设施；TestFlight 尚未实际执行 |

美肌／美型的 **19 个参数仅改变界面状态，不改变相机预览或照片**。Auto 不执行自动算法。滤镜／美妆也不渲染效果，各面板提供五语言说明。关闭面板再打开保留本次运行参数，重启 App 后恢复默认值。

照片不写入文件或系统 Photos Library。结果界面说明照片仅供本次预览；返回相机后丢弃。仅申请相机权限，不申请麦克风或照片图库权限。前置预览与拍摄结果采用一致镜像策略，后置不镜像。全屏预览会裁掉部分传感器画面边缘，照片保留原生完整比例；比例说明入口会提示这一点。

## 工程结构

```text
PanPanCamera.xcodeproj/        App + Unit Test targets，shared scheme
PanPanCamera/
├── App/                      直接启动相机，持有 CameraService
├── Camera/
│   ├── CameraService.swift   主线程状态与权限/生命周期边界
│   ├── Session/              串行队列上的真实 AVFoundation 会话
│   ├── Capture/              拍照 delegate、原始数据和结果缩略图
│   └── Permission/           相机授权状态与请求
├── FaceTracking/             Vision 检测、最新帧模型、坐标转换和有界结果交付；尚无跨帧追踪
├── Presentation/
│   ├── Camera/               Preview 桥接、主界面、错误/结果界面
│   ├── Beauty/               美肌与美型参数面板、独立 BeautyState
│   ├── Filter/               滤镜选择骨架
│   ├── Makeup/               美妆选择骨架
│   ├── Settings/             隐私、版本、未实现入口说明
│   └── Shared/               PanPan 视觉组件和本地化键映射
├── Domain/                   不依赖 SwiftUI/AVFoundation 的参数与状态
├── BeautyEngine/             Skin / FaceWarp / Makeup / Filters，仅说明
├── Rendering/                CoreImage / Metal，仅说明
├── Resources/                Info.plist、颜色资源、两个 String Catalog
└── Tests/                    参数、模式/能力状态、本地化的 XCTest
docs/                         架构与 Apple/真机验收清单
scripts/                      无第三方依赖的静态检查
```

更详细的线程、生命周期、方向、照片数据和未来模块边界见 [Architecture.md](docs/Architecture.md)。

依赖原则如下；FaceTracking 当前仅实现检测与 landmarks，BeautyEngine 处理和 Rendering 管线仍为下一阶段计划：

```text
Presentation（本地化、View）
    ↓
Application / State（当前由 CameraService 等状态边界承担）
    ↓
Camera / FaceTracking / BeautyEngine（计划）
    ↓
Rendering（计划）
```

**Camera 层不依赖 Presentation / L10n / SwiftUI UI 文案。** Camera 只输出 state、events、failures 和 capture data。`CameraFailure` 是 Domain 中的语义错误；Presentation 将其映射到既有本地化 key。参数、相机状态和面板状态保持分离。

相机行为测试使用最小权限／Session 命令注入，以及生产路径实际调用的 `CameraInputReplacement`、`PhotoCaptureRegistry`、`CameraSessionLifecycle`。输入事务、delegate 生命周期和恢复决策仍由原有串行 Session 队列调用；不模拟完整 AVFoundation 硬件。

人脸检测的 buffer／Vision／Preview 坐标契约、限频与生命周期说明见 [FaceDetection.md](docs/FaceDetection.md)。Debug scheme 添加启动参数 `-PanPanFaceDebugOverlay` 可绘制人脸框和 landmark 点；Release 不包含绘制代码。检测不修改 Preview 或照片像素，不保存或上传人脸数据。

## 五语言

正式资源包含 **日语 `ja`、简体中文 `zh-Hans`、繁体中文 `zh-Hant`、英语 `en`、韩语 `ko`**，Japanese 为项目 development region 与 String Catalog source language。

- `Localizable.xcstrings`：85 个 UI／无障碍／说明键，五语言均有非空完整翻译。
- `InfoPlist.xcstrings`：相机权限说明与 App 显示名称，五语言齐全。
- PanPan 在所有语言中保持不翻译；数值使用本地化数字格式。
- View 使用集中定义的 `L10n` 键。新增文字需同步添加五语言；catalog 为手动稳定键，关闭自动 Swift 字符串提取。
- 语言覆盖静态检查与编译后的 Bundle 本地化 XCTest 均已提供。自然措辞和长文本布局仍需在实际 Apple UI 上验收。

## 测试与当前验证状态

本地开发环境为 **Windows / PowerShell**，没有 Xcode、iOS SDK、Simulator 或连接的 iPhone。Apple 编译、XCTest 与截图由下述 GitHub macOS 工作流执行；不能把 Swift 语法解析当作 iOS 编译或真机运行证明。

| 项目 | 状态 |
| --- | --- |
| Python 工程/资源静态检查 | 已实际执行通过；包含目标引用、源码/资源归属、scheme/XML/plist/JSON、五语言与字面量/依赖扫描 |
| Swift syntax parse | 已实际执行通过；包含 App 与测试源码，仅语法解析 |
| 纯 Swift host typecheck | 4 个 Domain 文件和 3 个相机控制辅助类型，Windows Swift 5 语言模式类型检查，无硬件执行 |
| git diff --check | 已实际执行通过 |
| Xcode Build / Apple SDK typecheck | 由 iOS CI 的 Debug XCTest / Release Simulator Build 验证；以对应 commit 的 run 为准 |
| XCTest | 当前集合为 45 个 Debug 方法，含 12 个新增人脸检测相关方法；Release 单独执行 5 个截图隔离方法；新增测试尚未在 Apple 平台执行，实际结果以当前 SHA 的 `.xcresult` 为准 |
| Delivery script tests | 27 个 Python 测试，覆盖版本格式、PNG 数据流、Simulator 选择、CI gate、Profile 和上传失败传播 |
| Simulator UI | 手动 Simulator Screenshot 生成 10 张实际 UI 截图，需下载查看；不能证明真实相机 |
| Real Device Camera | 尚未执行；预览、拍照、闪光灯、方向、镜像与生命周期均待真机验收 |
| TestFlight | signing / Archive / Export / Upload 尚未实际验证 |

### Last verified baseline — 按当前 SHA 查询实际证据

验证状态保存在 [iOS CI 运行记录](https://github.com/songlabs/PanPanCamera/actions/workflows/ci.yml?query=branch%3Amain) 和 [Simulator Screenshot 运行记录](https://github.com/songlabs/PanPanCamera/actions/workflows/simulator-screenshot.yml?query=branch%3Amain)。README 不嵌入自身 commit SHA 或预测 run ID，避免回填文档后 SHA 再次变化；也不把历史成功 run 当作当前提交已通过。

在 checkout 中执行以下只读命令，取得**当前 SHA** 对应的实际 run ID、链接、状态和结果：

```powershell
$verifiedSha = git rev-parse HEAD
gh run list --repo songlabs/PanPanCamera --workflow ci.yml --commit $verifiedSha --json databaseId,headSha,status,conclusion,url
gh run list --repo songlabs/PanPanCamera --workflow simulator-screenshot.yml --commit $verifiedSha --json databaseId,headSha,status,conclusion,url
# 对上面返回的实际 ID 执行；CI 与 Screenshot 必须分别核对。
gh run view <RUN_ID> --repo songlabs/PanPanCamera --json headSha,status,conclusion,jobs,url
gh run view <RUN_ID> --repo songlabs/PanPanCamera --log
```

只有 `headSha` 完全相同且 `completed / success` 才算该提交完成验证；没有结果、仍运行或失败都不算通过。CI 还需确认 Debug XCTest、Release Simulator Build、Release isolation XCTest 三个步骤都成功，并读取 diagnostics 中两个 `.xcresult` 的 `passedTests / failedTests / skippedTests` 摘要。`xcode-version.log` 和 Simulator inventory 记录实际 Xcode、设备和 iOS 版本。

Screenshot 的 `screenshot-inventory.log` 记录实际路径、数量、分辨率、SHA256、Python 数据流检查与 macOS 原生读取结果，`capture.log` 记录五语言／locale。下载同一 run 的 `panpan-simulator-screenshots` 后人工检查黑图、权限弹窗和文字布局。实际分辨率以该 run 的原生 framebuffer 为准，不将某个历史设备尺寸写成所有 Simulator 的固定值。验收报告应同时记录这两个同 SHA run 的链接；artifact 保留期为 7 天。

Windows 可重复执行：

```powershell
python scripts/check_project.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_swift_syntax.ps1
python -m unittest discover -s scripts/tests -v
git diff --check
```

Swift Windows 工具链可能提示 Windows sysroot 与 iPhone target 不匹配；语法模式无需导入 Apple SDK，不能证明 App 的类型检查、链接或运行。脚本还分别对仅使用标准库的 Domain 和相机控制辅助类型执行 Windows host typecheck。Python 字面量扫描是基础防回归检查，不能替代全部 UI 语义和布局审查。

在 Mac 上也可执行：

```sh
xcodebuild -list -project PanPanCamera.xcodeproj
xcodebuild -project PanPanCamera.xcodeproj -scheme PanPanCamera \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .verification/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -showdestinations -project PanPanCamera.xcodeproj -scheme PanPanCamera
# 用上一条输出中的实际 iPhone Simulator UUID 替换 <SIMULATOR_ID>
xcodebuild -project PanPanCamera.xcodeproj -scheme PanPanCamera \
  -configuration Debug -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' \
  -derivedDataPath .verification/DerivedData \
  -resultBundlePath .verification/PanPanCameraTests.xcresult CODE_SIGNING_ALLOWED=NO test
```

45 个 Debug 方法覆盖参数、模式／能力状态、五语言编译资源、Screenshot 参数隔离、权限与 Session 协调、输入回退、拍照 delegate 生命周期，以及新增人脸坐标、可选 landmarks、多人脸映射、结果失效和限频逻辑。Release 运行其中 5 个 Screenshot 隔离方法。这里的行为测试不创建真实摄像头；新增测试尚未在 Apple 平台执行。详细边界和人工步骤见 [DeviceValidation.md](docs/DeviceValidation.md)。

## GitHub Actions

三个工作流用于 PanPan 的单 App / iPhone 工程。所有 Apple 作业固定 `macos-15`、`/Applications/Xcode_26.3.app/Contents/Developer`；Xcode 不存在或版本不匹配时失败，不自动换版本。实际执行版本仍需核对 run 日志。

### iOS CI

[打开 iOS CI](https://github.com/songlabs/PanPanCamera/actions/workflows/ci.yml)。自动流程：

```text
push main → Unit Test (Debug) → Release Simulator Build
          → Release 截图隔离 XCTest → Diagnostics Artifact
```

自动触发为 `push main`，也支持 `workflow_dispatch`（Run workflow）。使用实际 `PanPanCamera.xcodeproj`、`PanPanCamera` scheme、`PanPanCameraTests` target。动态从 `simctl list devices available -j` 选择最新可用 iOS 26.x 的 iPhone，优先顺序为 iPhone 17 Pro Max、17 Pro、16 Pro Max、16 Pro，其后选择可用的最新代 iPhone。没有合适设备时输出 inventory 并失败。Simulator CI 不能验证真实 Camera hardware，也没有覆盖 iOS 17 运行时。

`panpan-ios-ci-diagnostics` 保留 7 天，包含两个 `.xcresult`、测试/Release build 日志、Xcode 版本、Simulator inventory、Simulator 进程日志和可收集的 crash / `.ips`。诊断步骤即使前序失败也执行；测试、编译失败会使作业失败。Release Simulator Build 不等于真机 Release Archive。

### Simulator Screenshot

[打开 Simulator Screenshot](https://github.com/songlabs/PanPanCamera/actions/workflows/simulator-screenshot.yml)：`Actions → Simulator Screenshot → Run workflow → main`。仅手动触发，不随 push 运行。

```text
Build Debug App → Boot iPhone Simulator → Install → Launch
               → App 实际渲染 → simctl screenshot → 验证 → Artifact
```

下载 `panpan-simulator-screenshots`，保留 7 天。ZIP 根目录下包含以下路径（仓库运行时位于 `screenshots/`）：

```text
ja/camera.png       zh-Hans/camera.png   zh-Hant/camera.png
en/camera.png       ko/camera.png
ja/beauty.png       ja/reshape.png       ja/filter.png
ja/makeup.png       ja/settings.png
```

每张图重新安装 App，使用真实 `-AppleLanguages` / `-AppleLocale` 设置语言，并核对 App 返回的当前语言、Locale 和目标画面。App 通过 `--screenshot-mode --screenshot-screen camera|beauty|reshape|filter|makeup|settings` 打开现有界面。截图模式与测试背景仅用于 Debug；Release 忽略所有截图参数。截图模式不创建预览相机会话、不请求相机权限、不启动 AVCaptureSession。背景是 SwiftUI 绘制的固定渐变、圆形和取景框，代表 UI 测试背景，不是真实 Camera Feed，也不代表美颜效果。没有网络、外部图片或生成式素材。

截图检查要求恰好 10 张，且分辨率与未缩放的原生 `simctl` 基准图一致。标准库 Python verifier 验证 signature、IHDR／IEND、所有 chunk CRC、连续且总体非空的 IDAT、完整 zlib 流结束、扫描行长度及 filter byte；无 IDAT、损坏／截断流不能通过。当前明确支持静态、non-interlaced、8-bit RGB／RGBA；不支持的格式直接失败，不静默接受。另使用 macOS `sips` 读取每张原图的宽高进行二次核对，不重写图片、不引入 Pillow。

inventory 输出尺寸、大小、SHA256 和两种验证结果。下载后仍需人工查看文字、布局与弹窗；readiness 不是完整 UI 自动断言。Screenshot 面板固定为 large，普通运行支持 medium / large，截图未覆盖普通默认面板高度。`panpan-simulator-diagnostics` 保存 build、launch、capture、inventory 与设备清单，保留 7 天。

### TestFlight

[打开 TestFlight](https://github.com/songlabs/PanPanCamera/actions/workflows/testflight.yml)：`Actions → TestFlight → Run workflow → main → 输入 marketing_version`，例如 `0.1.0`。只允许 main，非 main 明确失败。

**交付 workflow 已实现；TestFlight signing / Archive / Export / Upload 尚未实际验证，实际上传尚未执行。** 当前缺少发行凭据配置和正式 AppIcon；这次基础架构修整不执行 TestFlight，不修改 Apple Developer 或 App Store Connect 配置。

项目统一要求 `MARKETING_VERSION` 为严格三段数字，例如 `0.1.0`、`1.2.3`。`0.1`、`1`、`1.2.3.4`、前缀和 beta 后缀均 fail-fast，不自动补齐。workflow、release configuration 和 Archive 校验共用 `scripts/validate_marketing_version.py`，没有多套格式规则。

**TestFlight 只有当前 commit 存在成功的 iOS CI run 才允许执行。** Linux preflight 查询该 SHA 的 `ci.yml` runs，要求 `iOS CI`、`main`、完全相同 SHA、`completed`、`success`；没有满足条件的成功 run 就在签名与 Archive 前停止。Gate 接受该 SHA 任意一次匹配的成功 run，不代表要求最新一次重跑成功。检查方式遵循 [GitHub workflow runs API](https://docs.github.com/en/rest/actions/workflow-runs)。

```text
手动版本输入 → main / 当前 SHA 的 CI Gate → 必要配置检查
            → Manual Distribution Signing → Release iOS Archive
            → 结构/版本/签名/Profile/Entitlement 验证
            → Export IPA → App Store Connect Upload
```

`archive-and-upload` 使用 `testflight` Environment。首次使用前，在 GitHub Settings → Environments 手工建立并按需要设置 main 部署限制；本任务不修改 Repository Settings。以下配置可放在 Repository 或 `testflight` Environment（同名 Environment 配置优先）：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | PanPan 所属 Apple Developer Team ID |
| Secret | `ASC_KEY_ID` | App Store Connect API Key ID |
| Secret | `ASC_ISSUER_ID` | API Key Issuer ID |
| Secret | `ASC_PRIVATE_KEY` | 原始 `.p8` 私钥内容 |
| Secret | `APPLE_DISTRIBUTION_P12_BASE64` | 含私钥的 Apple Distribution `.p12` 的 Base64 |
| Secret | `APPLE_DISTRIBUTION_P12_PASSWORD` | P12 导出密码 |
| Secret | `PROFILE_PANPAN_BASE64` | `com.songlabs.PanPanCamera` 的 App Store provisioning profile 的 Base64 |

截至 2026-09-08 的只读配置检查，Repository Secrets / Variables 与 Environment 均未配置；这不是以后配置状态的保证。工作流会一次列出缺失配置名称，不输出值。Apple Developer 中的 App ID、App Store Connect 中对应的 App、有效证书、含该证书的 App Store Profile 以及 API Key 权限需要另行准备／核实。

**当前工程尚无发行用 App Icon。** 必须先提供正式图标、加入 `AppIcon.appiconset` 并配置 AppIcon 编译设置；release preflight 会对此明确失败，避免耗时 Archive 后才被 Apple 拒绝。本任务不创作品牌素材、不改 Bundle ID、不修改 App Store Connect 配置。

签名脚本只安装一个主 App Profile，不要求固定 Profile 名称。验证 Team、App ID prefix / Bundle ID、Profile 类型、UTC 过期日期、证书有效性及证书是否被 Profile 授权，依据 [Apple provisioning profile 说明](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。Archive 使用明确的 Manual、证书 SHA1、Team 和 Profile UUID，不回退自动签名；本地工程默认签名设置保留。

`CFBundleShortVersionString` 必须等于输入版本，`CFBundleVersion` 必须等于本次 UTC Unix timestamp。Archive 必须只有一个主 App，嵌入 Profile 与安装 Profile 相同、签名证书匹配、entitlements 被授权且不能调试。动态导出配置为 `app-store-connect` / `export` / `manual`，只映射主 App；导出必须存在非空 `PanPanCamera.ipa`。上传检查 altool / tee 两个退出码及 Apple validation / invalid train / rejection 日志。临时 keychain、Profile、P12、API key 在 `always()` 清理；日志 Artifact 保留 7 天，不上传签名材料。

上传命令成功与 Apple 后续 processing / TestFlight 可分发状态分开；当前脚本不自动分配测试组。实际签名、Archive、IPA、上传与 Apple 接受状态只有执行 TestFlight 才能验证。

辅助脚本沿用本仓库已有小写 `scripts/` 目录。可在 Windows 运行 `python -m unittest discover -s scripts/tests -v` 检查 Simulator 选择、当前 SHA gate、Profile 验证、缺少配置和上传失败传播；它们不替代真实 Apple 签名测试。

## 尚未实现与后续计划

以下均未进入当前实现，不存在伪装的效果或隐式调用：

1. 在现有 Vision 检测和 landmarks 基础上实现 Stable Face Tracking。
2. 在现有 AVCaptureVideoDataOutput 检测路径基础上设计后续效果处理输入。
3. BeautyEngine、Skin Processing、Face Warp，及真正的磨皮／美白／瘦脸算法。
4. Metal Rendering、Core ML、真实 Filter Rendering、真实 Makeup Rendering。
5. Video Recording、Video Beauty、Photo Editor。
6. System Photos Save、照片导入、持久化照片存储。
7. 比例裁切、Timer、人像模式与发行用 App Icon；发行凭据仍需单独配置。

当前已经接入 Vision Face Detection、Face Landmarks 和限频视频帧检测；后续顺序为 Stable Face Tracking → BeautyEngine input model → Metal rendering。`check_project.py` 仅在 FaceTracking 放开 Vision、在 Camera 放开视频帧获取，继续禁止 Metal、CoreML、CoreImage、网络和其他范围外 API。

## Real Device Validation Pending

以下均仍为 **Pending**，不受 Unit Test／Simulator 绿灯替代：

- Camera Preview，前后摄像头的真实画面。
- Front / Rear switch，重复操作与切换失败恢复。
- Flash Off / Auto / On，前置无硬件闪光灯情况。
- Photo capture，原始照片、结果页及释放。
- Orientation，固定竖屏 UI 下物理旋转的照片方向。
- Mirroring，前后镜头含文字／不对称物体的测试。
- Background / Foreground、Home、锁屏／解锁、拍摄中离开 App。
- Interruption、media services reset，在可制造条件下分别记录结果。

详细 checklist 见 [DeviceValidation.md](docs/DeviceValidation.md)。TestFlight signing、设备 Archive、IPA Export 和 Upload 同样尚未验证。

## 隐私原则

当前不上传相机画面、不上传拍摄照片、不使用外部 AI API；照片仅用于本次内存预览。后续 BeautyEngine 目标仍为 on-device。这里描述当前代码和处理方向，不承诺尚未实现的隐私技术机制。

后续仍以 **设备端处理、原生框架、最小权限** 为原则。GitHub Simulator 即使编译、测试与截图全部成功，也不能证明真实 iPhone 的预览、拍照、闪光灯、方向、镜像或生命周期行为。
