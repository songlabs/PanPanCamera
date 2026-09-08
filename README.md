# PanPanCamera · PanPan

PanPanCamera 是 PanPan 的第一版原生 iOS 美颜相机开发基础。长期功能方向是设备端相机、美肌、美型与照片编辑；UI、命名和素材采用 PanPan 自己的设计，不复制其他 App。当前版本为 **0.1.0**，重点是清晰工程结构、真实相机与拍照路径、多语言和后续本地处理的职责边界。

**当前版本不使用任何外部 AI API。Photos / Camera processing should remain on-device.** 没有照片上传、网络客户端、账号、后端、数据库、订阅、内购、广告、第三方 SDK 或第三方素材。

## 开发环境与打开方式

- iPhone、iOS 17.0+；首版 UI 固定竖屏，照片方向跟随设备物理旋转。
- Xcode 15+ / Swift 5.9+ 工具链，以 Swift 5 语言模式编译。
- SwiftUI、AVFoundation、Foundation、Combine、UIKit 和 ImageIO，全部为 Apple 原生框架。
- 直接打开 `PanPanCamera.xcodeproj`，选择共享的 `PanPanCamera` scheme。
- 没有 CocoaPods、Carthage、Swift Package 依赖、工程生成器安装步骤或服务器。
- 真机运行时，在 Signing & Capabilities 选择自己的 Team。仓库不包含个人 Team、证书、描述文件或 Secrets。初始 bundle identifier 为 `com.songlabs.PanPanCamera`，按实际签名需要调整。
- 首版没有制作发行用 App Icon；当前系统开发占位图标不代表最终品牌图标。界面图标使用 SF Symbols，粉色与组件布局在本仓库定义。

## Version 0.1 范围

“已实现”指代码路径和界面已建立；Apple SDK 编译、XCTest 和真机行为的实际验证状态见下文，尚不能据此认定真机验收通过。

| 功能 | 当前实现 |
| --- | --- |
| 启动入口 | 直接进入 CameraView，没有首页、内容流或额外引导页 |
| 实时预览 | AVCaptureSession + AVCaptureVideoPreviewLayer，全屏 aspect fill |
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

## 五语言

正式资源包含 **日语 `ja`、简体中文 `zh-Hans`、繁体中文 `zh-Hant`、英语 `en`、韩语 `ko`**，Japanese 为项目 development region 与 String Catalog source language。

- `Localizable.xcstrings`：85 个 UI／无障碍／说明键，五语言均有非空完整翻译。
- `InfoPlist.xcstrings`：相机权限说明与 App 显示名称，五语言齐全。
- PanPan 在所有语言中保持不翻译；数值使用本地化数字格式。
- View 使用集中定义的 `L10n` 键。新增文字需同步添加五语言；catalog 为手动稳定键，关闭自动 Swift 字符串提取。
- 语言覆盖静态检查与编译后的 Bundle 本地化 XCTest 均已提供。自然措辞和长文本布局仍需在实际 Apple UI 上验收。

## 测试与当前验证状态

初版在 **Windows / PowerShell** 环境编写，没有 Xcode、iOS SDK、Simulator 或连接的 iPhone。不能把 Swift 语法解析当作 iOS 编译或真机运行证明。

| 项目 | 状态 |
| --- | --- |
| Python 工程/资源静态检查 | 已实际执行通过；包含目标引用、源码/资源归属、scheme/XML/plist/JSON、五语言与字面量/依赖扫描 |
| Swift syntax parse | 已实际执行通过；包含 App 与测试源码，仅语法解析 |
| 纯 Swift Domain typecheck | 已实际执行通过；3 个无框架依赖的 Domain 文件，Windows Swift 5 语言模式类型检查，无执行 |
| git diff --check | 已实际执行通过 |
| Xcode Build / Apple SDK typecheck | 尚未执行，当前 Windows 环境无法验证 |
| XCTest | 12 个测试方法已编写并接入共享 scheme，尚未执行 |
| Simulator UI | 尚未执行，当前环境不可用；也不能证明真实相机 |
| Real Device Camera | 尚未执行；预览、拍照、闪光灯、方向、镜像与生命周期均待真机验收 |

Windows 可重复执行：

```powershell
python scripts/check_project.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_swift_syntax.ps1
git diff --check
```

Swift Windows 工具链可能提示 Windows sysroot 与 iPhone target 不匹配；语法模式无需导入 Apple SDK，不能证明 App 的类型检查、链接或运行。脚本还单独对仅使用标准库的三个 Domain 文件执行 Windows host typecheck；它不导入 Foundation 或 Apple UI／相机框架。Python 的字面量扫描是基础防回归检查，不能替代全部 UI 语义和布局审查。

在 Mac 上执行（以下命令尚未在本任务运行）：

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

12 个测试方法覆盖全部参数默认值与范围、非法数值、工具／类别独立状态、模式门控、拍摄忙碌状态、方向状态切换、闪光灯能力变化和五语言编译资源。没有用复杂硬件 Mock 来模拟 AVCaptureSession 验收。详细人工步骤见 [DeviceValidation.md](docs/DeviceValidation.md)。

## 尚未实现与后续计划

以下均未进入当前实现，不存在伪装的效果或隐式调用：

1. BeautyEngine：本地美肌与真正的参数处理契约。
2. Face Tracking：Vision 人脸／Landmark 输入，以及独立的几何验证。
3. Metal Rendering：本地实时渲染、性能与功耗评估。
4. Makeup / Filters：真实本地美妆与滤镜处理。
5. Photo Editor、照片导入与保存：独立设计权限和数据生命周期。
6. Video Beauty、录制与编辑：后续独立范围。
7. Core ML 模型、实际磨皮／美白／瘦脸／美妆算法均未实现。
8. 比例裁切、Timer、人像模式、发行用 App Icon 与发布配置尚未实现。

后续仍以 **设备端处理、原生框架、最小权限** 为原则。当前任务不配置 GitHub Actions、Release、TestFlight、App Store Connect、仓库 Settings、Visibility 或 Secrets。
