# PanPanCamera · PanPan

PanPanCamera 是原生 iOS 美颜相机，当前 **0.1.0 仍处于基础架构阶段**。后续目标是在设备端提供主流美颜相机的美肌、美型与照片编辑能力。UI、命名和素材采用 PanPan 自己的设计，不复制其他 App；当前重点是清晰工程结构、真实相机与拍照路径、多语言和本地处理边界。

**当前版本不使用任何外部 AI API。Photos / Camera processing should remain on-device.** 没有照片上传、网络客户端、账号、后端、数据库、订阅、内购、广告、第三方 SDK 或第三方素材。

## 开发环境与打开方式

- iPhone、iOS 17.0+；首版 UI 固定竖屏，照片方向跟随设备物理旋转。
- Xcode 15+ / Swift 5.9+ 工具链，以 Swift 5 语言模式编译。
- SwiftUI、AVFoundation、Vision、Core Image、Metal、Foundation、Combine、UIKit 和 ImageIO，全部为 Apple 原生框架。
- 直接打开 `PanPanCamera.xcodeproj`，选择共享的 `PanPanCamera` scheme。
- 没有 CocoaPods、Carthage、Swift Package 依赖、工程生成器安装步骤或服务器。
- 真机开发时，在 Signing & Capabilities 选择自己的 Team。仓库不包含个人 Team、证书、描述文件或 Secrets。当前工程实际 bundle identifier 为 `com.songlabs.PanPanCamera`；发布配置与 Apple App ID 必须匹配这个值。
- 首版没有制作发行用 App Icon；当前系统开发占位图标不代表最终品牌图标。界面图标使用 SF Symbols，粉色与组件布局在本仓库定义。

## Version 0.1 范围

“已实现”指代码路径和界面已建立；Apple SDK 编译、XCTest 的证据见对应提交的 GitHub Actions，真机行为仍需单独验收。

| 功能 | 当前实现 |
| --- | --- |
| 启动入口 | 直接进入 CameraView，没有首页、内容流或额外引导页 |
| 实时预览 | AVCaptureVideoPreviewLayer 保留为原始/降级层；Beauty 生效时由最新 VideoDataOutput frame 经 Core Image + Metal 覆盖显示，保持全屏 aspect fill |
| 人脸检测 | 本地 Vision 视频帧限频检测，输出全部人脸框及可选基础 landmarks；Apple Build 和真机验收待当前提交验证 |
| 相机权限 | 请求、授权、拒绝、系统限制说明；拒绝后可打开系统设置 |
| 前后切换 | 实际替换 AVCaptureDeviceInput；检查硬件、切换期间禁用竞争操作、失败回退 |
| 前后台 | 复用一个会话；非活跃或结果预览时停止，返回时恢复；处理中断与运行错误 |
| Flash | 按硬件/输出支持循环 Off / Auto / On，通过照片设置实际使用闪光灯；无硬件支持时禁用 |
| 拍照 | 支持 shutter suppression 时使用 AVCapturePhotoOutput 原始高质量 Data，否则使用原生最新 VideoDataOutput frame；Beauty 后保存相册并显示结果 |
| 主界面 | 半透明圆角顶部栏、白色/半透明底栏、柔粉色中央快门、照片模式 |
| 美肌 | 总强度、磨皮、提亮、肤色一致性已接入实时预览与最终照片；祛痘、黑眼圈仍为参数 UI；各值独立 0–100，默认 50 |
| 美型 | 自动作为总强度，瘦脸、脸宽、下巴、额头、颧骨已接入实时 Preview；大眼、眼距、眼高、鼻宽、鼻长、嘴型、嘴宽仍为参数 UI；照片暂不应用美型 |
| 滤镜 | Original / Natural / Clear / Warm / Cool 本地化预设选择骨架 |
| 美妆 | Lip / Blush / Eye / Brow 本地化类别选择骨架 |
| Settings | 隐私与版本范围说明；没有虚假的功能开关 |
| 未实现入口 | 比例、Timer、相册点击后说明当前限制；视频、人像显示未支持且禁用 |
| 五语言 | UI、无障碍文字、权限说明与品牌名称 |
| Debug Screenshot Mode | 固定 SwiftUI 测试背景和页面参数；绕过真实相机与权限 |
| DEBUG 照片处理 | Mock FaceRegion / FacialLandmarks / Skin Semantic Mask → 每脸柔边覆盖与皮肤权重配对 → 五官和细节保护 → EffectiveSkinMaskComposer → 原两尺度纹理重建及单次 Blend；支持六种 Mask、原图、处理图、Difference 与 0 / 0.25 / 0.5 A/B，未接入正式照片流程 |
| GitHub Actions | iOS CI、手动 Simulator Screenshot、TestFlight 交付基础设施；TestFlight 尚未实际执行 |

美肌和美型的总强度是分类内全部参数的批量控制器，并与具体参数相乘得到实际强度。美肌的磨皮、提亮和肤色一致性使用同一不可变 `BeautyConfiguration` 语义接入 Preview 与 Final，快门时会保存配置快照。顔補正的瘦脸／脸宽／下巴／额头／颧骨复用同一配置传播链路，但几何处理只在 Preview 执行。祛痘、黑眼圈与其余眼鼻嘴美型参数仍不改变像素，界面提供五语言准确说明。滤镜／美妆也不渲染效果。关闭面板再打开保留本次运行参数，重启 App 后恢复默认值。

照片通过现有 add-only Photos 权限流程保存到系统相册，结果界面同时持有本次预览对象；返回相机后释放内存对象。不申请麦克风权限。前置预览与拍摄结果采用一致镜像策略，后置不镜像。全屏预览会裁掉部分传感器画面边缘，照片保留原生完整比例；比例说明入口会提示这一点。

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
│   ├── Beauty/               绑定 CameraService 共享参数的美肌与美型面板
│   ├── Filter/               滤镜选择骨架
│   ├── Makeup/               美妆选择骨架
│   ├── Settings/             隐私、版本、未实现入口说明
│   └── Shared/               PanPan 视觉组件和本地化键映射
├── Domain/                   不依赖 SwiftUI/AVFoundation 的参数与状态
├── BeautyEngine/             Skin / FaceWarp / Makeup / Filters 的能力边界说明
├── Rendering/                Preview/Final Beauty、Preview Face Correction、Core Image/Metal 与 DEBUG Pipeline
├── Resources/                Info.plist、颜色资源、两个 String Catalog
└── Tests/                    参数、模式/能力状态、本地化的 XCTest
docs/                         架构与 Apple/真机验收清单
scripts/                      无第三方依赖的静态检查
```

更详细的线程、生命周期、方向、照片数据和未来模块边界见 [Architecture.md](docs/Architecture.md)。

依赖原则如下；FaceTracking 实现检测与 landmarks，Rendering 已接入正式 Preview/Final 美肌处理及 Preview-only Face Correction，BeautyEngine 记录能力边界。柔边 Mask 参数、DEBUG 检查入口、测试及平台证据边界见 [Rendering/README.md](PanPanCamera/Rendering/README.md)：

```text
Presentation（本地化、View）
    ↓
Application / State（当前由 CameraService 等状态边界承担）
    ↓
Camera / FaceTracking / BeautyEngine（计划）
    ↓
Rendering（独立开发链路）
```

**Camera 层不依赖 Presentation / L10n / SwiftUI UI 文案。** Camera 只输出 state、events、failures 和 capture data。`CameraFailure` 是 Domain 中的语义错误；Presentation 将其映射到既有本地化 key。参数、相机状态和面板状态保持分离。

相机行为测试使用最小权限／Session 命令注入，以及生产路径实际调用的 `CameraInputReplacement`、`PhotoCaptureRegistry`、`CameraSessionLifecycle`。输入事务、delegate 生命周期和恢复决策仍由原有串行 Session 队列调用；不模拟完整 AVFoundation 硬件。

人脸检测的 buffer／Vision／Preview 坐标契约、限频与生命周期说明见 [FaceDetection.md](docs/FaceDetection.md)。当前诊断 TestFlight 由内部 `FaceGeometryDebugMode.isEnabled` 开启 Face Geometry Overlay：它显示生产 Beauty renderer 最终使用的人脸框、contour、小顔 center／radius／vector 和简洁参数信息，不另跑 Vision；正式 App Store Release 前可将单一内部 flag 关闭。Beauty 只在本地消费瞬时检测结果，不保存或上传人脸数据。

## 五语言

正式资源包含 **日语 `ja`、简体中文 `zh-Hans`、繁体中文 `zh-Hant`、英语 `en`、韩语 `ko`**，Japanese 为项目 development region 与 String Catalog source language。设置页可选择上述语言或跟随系统；选择通过 `AppStorage` 持久化，并由 App Root 的 Locale environment 立即应用到 SwiftUI 界面。

- `Localizable.xcstrings`：94 个 UI／无障碍／说明键，五语言均有非空完整翻译。
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
| XCTest | 当前 24 个测试源文件静态统计 210 个方法；Face Correction 参数、主脸选择、landmark 映射、无脸/无效输入、镜像和 Preview-only 照片边界测试尚未在 Apple 平台执行 |
| Delivery / scope tests | 45 个 Python 测试已通过，包含 Beauty 两条原生 capture 路径、Face Correction Preview-only 边界、bypass、back-pressure、单一 CIContext、无 screenshot/upscale/网络/第三方依赖等范围检查 |
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

现有 XCTest 覆盖参数、相机控制、人脸坐标、独立照片处理、Beauty 连接与 Face Correction 纯几何逻辑，当前共 24 个测试源文件、210 个方法，均为静态计数；本次新增 Apple 测试尚未执行。45 个 Python 测试、project checks、88 个 Swift 文件语法解析及现有 4 个 Domain／3 个 camera control helper host typecheck 已通过；这不是 Apple 编译证明。先前 Windows Foundation／host XCTest 已确认缺少 `errno.h`、`msvcrt.lib`、`oldnames.lib`、`msvcprt.lib`，本任务未重试或修复该环境。Apple 边界见 [DeviceValidation.md](docs/DeviceValidation.md) 及 [Core Image README](PanPanCamera/Rendering/CoreImage/README.md)。

本阶段按「组件实现 → 当前环境静态检查 → commit → push → 确认 Actions 已触发 → 结束」交付。不会等待／轮询本次 CI 结果，也不会自动启动统一 Apple 测试；`queued` 或 `in_progress` 不代表 CI passed。以下 Mac 与 Actions 验证说明保留给后续统一阶段使用。

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
2. 将顔補正扩展到最终照片，并实现其余眼鼻嘴参数；本次仅做 Preview 的五项局部几何。
3. 实现祛痘、黑眼圈、真实 Filter Rendering 与真实 Makeup Rendering。
4. Video Recording、Video Beauty、Photo Editor。
5. 照片导入、持久化照片存储。
6. 比例裁切、Timer、人像模式；发行凭据仍需单独配置。

当前已有 Vision Face Detection、Face Landmarks 和限频视频帧检测代码，但真实检测尚未验证。以 `main` 的 `ffa7f23a6b0708fa96c4a1bb8556033867be80e0` 为基准，独立 Rendering 入口已完成 **Natural Skin Tone & Illumination v1** 与 **NaturalSkinRetouchSteps v1**，形成：

```text
Face / Landmark / Skin Data
→ EffectiveSkinMask（Mask + Feature / Detail Protection）
→ TexturePreservingSkinSmoothingStep（Texture）
→ NaturalSkinToneAdjustmentStep（Tone）
→ Natural Skin Retouch Output
```

**Tone Consistency ≠ Skin Whitening。** Tone v1 只调整很轻微的低频亮度不均，参考来自当前图像 Effective Skin Area 的加权局部统计，没有固定 brightness／exposure 提升、目标肤色、去黄、粉色或 hue 调整；本次没有实现 chroma consistency。局部尺度为 `clamp(0.025 × 最小可用脸短边, 4, 32)` 像素，参考尺度为其 3 倍。修正为 `clamp(0.2 × (reference - local), ±maxLuminanceCorrection)`，再应用现有 Effective Skin Mask、Tone 强度及光影／高光／深阴影／透明度／统计支持／通道余量保护。产品 Final mapping 使用 `toneConsistencyStrength = 0.50`、`maxLuminanceCorrection = 0.006`（上限 0.012）；默认总 intensity 仍为 0.25，默认最终修正界为 0.00075 线性工作空间单位，RGBA8 下仍可能量化为零。**这些是工程初值，尚未通过真实照片视觉验收。**

`NaturalSkinRetouchSteps.make(...)` 是唯一组合入口，默认 Texture → Tone；现有 `ImageProcessingPipeline` 继续管理加载、人脸检测、worker、顺序、busy 和错误。组合层只返回 Step 数组，没有第二个 Pipeline／Task／线程队列。两个组件各保持现有 CGImage 渲染边界，Combined 最多渲染两次、使用同一个 CIContext；providers 与既有 Mask helpers 在各自输入上可能执行两次。本任务没有修改 Texture 算法或任何 Mask 算法。旧 `NaturalSkinProcessingStep` 的固定 brightness +0.008／saturation 1.005 实验代码及测试保留，不用于默认 DEBUG 链路。

Mock Skin Mask 仍支持 normal skin、hair exclusion、glasses／矩形遮挡、beard reduced weight 和 unavailable。原有 `max(Fj × Sj) × (1 - protection) × intensity` 逐脸组合／统一处理与 unavailable 的 `Sj = 1` 降级保持。Tone 不重复逐脸处理照片。alpha、extent、orientation 和颜色空间契约保持；intensity 0／无脸严格原图透传，Tone 强度或修正上限为零也提前返回。

DEBUG 保留九种既有输出及别名，新增 `.processedTexture`、`.toneAdjusted`、`.toneDifference`，共十二种；`.processed` 默认 Combined，`.difference` 比较实际渲染结果与原图。`components: .textureOnly / .toneOnly / .combined` 可独立排查；预设仅 `.original / .naturalDefault / .strongerDebug`，不增加正式 UI。完整公式、每项保护阈值、DEBUG 示例和阶段渲染边界见 [Core Image README](PanPanCamera/Rendering/CoreImage/README.md)。

**Natural Skin Processing Core Components 已完成代码层基础闭环。这只代表基础组件代码完成，不代表视觉质量验收完成。**

- Natural Skin Tone / Illumination 的实际 Core Image 图像行为尚未在 Apple 平台验证。
- Mock Skin Mask 不代表真实 Skin Segmentation。
- 真实 Vision 人脸检测 / landmarks 尚未验证。
- 真实 Skin Segmentation 尚未实现。
- 尚未完成 Apple 平台 / 真机验收。
- TexturePreservingSkinSmoothingStep 仍使用 deprecated `CIColorKernel(source:)`；本任务未修改、未复制、未新增第二处、未解决。

本任务只完成组件与当前环境静态验证；commit → push → 确认 GitHub Actions 已触发后立即结束，不等待、不轮询 CI，不自动进入统一 Apple 测试。正式相机、照片捕获／保存、产品 UI、网络、依赖保持不变；没有新增 ML、Metal、MPS、几何或局部缺陷删除功能。

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
