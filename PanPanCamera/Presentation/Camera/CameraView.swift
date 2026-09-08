import SwiftUI

@MainActor
struct CameraView: View {
    @ObservedObject var camera: CameraService
    @StateObject private var beauty = BeautyState()
    @StateObject private var tools = CameraToolState()
    @Environment(\.scenePhase) private var scenePhase
    private let screenshot = ScreenshotConfiguration(arguments: ProcessInfo.processInfo.arguments)

    private var shouldRunCamera: Bool {
        !screenshot.isEnabled && scenePhase == .active && camera.capturedPhoto == nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            preview
            if !screenshot.isEnabled && (camera.state.status != .running || camera.state.access != .authorized) {
                CameraStatusView(state: camera.state) {
                    Task { await camera.setActive(shouldRunCamera) }
                }
                .padding(24)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topControls }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .task(id: shouldRunCamera) {
            guard !screenshot.isEnabled else { return }
            await camera.setActive(shouldRunCamera)
        }
        .onDisappear {
            guard !screenshot.isEnabled else { return }
            Task { await camera.setActive(false) }
        }
        .task {
            #if DEBUG
            guard let screen = screenshot.screen else { return }
            switch screen {
            case .camera: await ScreenshotReadiness.record(screen)
            case .beauty: tools.beautyCategory = .skin; tools.panel = .beauty
            case .reshape: tools.beautyCategory = .face; tools.panel = .beauty
            case .filter: tools.panel = .filters
            case .makeup: tools.panel = .makeup
            case .settings: tools.panel = .settings
            }
            #endif
        }
        .sheet(item: $tools.panel) { panel in
            panelView(panel).task {
                #if DEBUG
                if let screen = screenshot.screen { await ScreenshotReadiness.record(screen) }
                #endif
            }
        }
        .fullScreenCover(item: $camera.capturedPhoto) { photo in
            CaptureResultView(photo: photo)
        }
        .alert(Text(L10n.errorTitle), isPresented: Binding(
            get: { camera.failure != nil },
            set: { if !$0 { camera.failure = nil } }
        )) {
            Button { camera.failure = nil } label: { Text(L10n.close) }
        } message: {
            if let failure = camera.failure { Text(failure.localizedKey) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if screenshot.isEnabled {
            ScreenshotPreview().ignoresSafeArea()
        } else {
            livePreview
        }
        #else
        livePreview
        #endif
    }

    private var livePreview: some View {
        CameraPreview(session: camera.previewSession, device: camera.previewDevice)
            .ignoresSafeArea()
            .accessibilityLabel(Text(L10n.livePreview))
    }

    private var topControls: some View {
        HStack(spacing: 4) {
            CameraIconButton(symbol: camera.state.flash.symbol, label: .flash,
                             value: camera.state.supportedFlashModes.count > 1 ? camera.state.flash.label : .flashUnavailable,
                             enabled: camera.state.canCapture && camera.state.supportedFlashModes.count > 1,
                             action: camera.cycleFlash)
            CameraIconButton(symbol: "aspectratio", label: .aspectRatio, value: .comingSoon) {
                tools.panel = .aspectRatio
            }
            CameraIconButton(symbol: "timer", label: .timer, value: .comingSoon) { tools.panel = .timer }
            CameraIconButton(symbol: "gearshape", label: .settings) { tools.panel = .settings }
            CameraIconButton(symbol: "arrow.triangle.2.circlepath.camera", label: .switchCamera,
                             value: camera.state.position == .front ? .frontCamera : .backCamera,
                             enabled: camera.state.canCapture && camera.state.canSwitchCamera,
                             action: camera.switchCamera)
                .accessibilityIdentifier("camera.switch")
        }
        .foregroundStyle(PanPanTheme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .disabled(camera.state.isCapturing || camera.state.isSwitching)
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 4) {
                bottomTool(.album, symbol: "photo.on.rectangle", panel: .album)
                bottomTool(.skin, symbol: "sparkles", panel: .beauty)
                Button(action: camera.capture) {
                    ZStack {
                        Circle().stroke(PanPanTheme.accent, lineWidth: 3)
                        Circle().fill(PanPanTheme.accent).padding(7)
                        if camera.state.isCapturing { ProgressView().tint(.white) }
                    }
                    .frame(width: 80, height: 80)
                    .padding(4)
                }
                .buttonStyle(.plain)
                .disabled(!camera.state.canCapture)
                .opacity(camera.state.canCapture || camera.state.isCapturing ? 1 : 0.45)
                .accessibilityLabel(Text(L10n.shutter))
                .accessibilityIdentifier("camera.shutter")
                bottomTool(.filters, symbol: "camera.filters", panel: .filters)
                bottomTool(.makeup, symbol: "paintbrush.pointed", panel: .makeup)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(CameraMode.allCases) { mode in
                    Button { camera.selectMode(mode) } label: {
                        VStack(spacing: 4) {
                            Text(mode.label).font(.subheadline.weight(mode == camera.state.mode ? .bold : .regular))
                            if !mode.isAvailable { Text(L10n.comingSoon).font(.caption2) }
                            if mode == camera.state.mode {
                                Circle().fill(PanPanTheme.accent).frame(width: 5, height: 5)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!mode.isAvailable)
                    .foregroundStyle(mode == camera.state.mode ? PanPanTheme.accent : .secondary)
                    .accessibilityAddTraits(mode == camera.state.mode ? .isSelected : [])
                }
            }
        }
        .foregroundStyle(PanPanTheme.ink)
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
    }

    private func bottomTool(_ label: L10n, symbol: String, panel: CameraPanel) -> some View {
        Button { tools.panel = panel } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: PanPanTheme.iconSize, weight: .medium))
                Text(label).font(.caption).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.state.isCapturing || camera.state.isSwitching)
    }

    @ViewBuilder
    private func panelView(_ panel: CameraPanel) -> some View {
        switch panel {
        case .beauty: BeautyPanel(beauty: beauty, category: $tools.beautyCategory)
        case .filters: FilterPanel(selection: $tools.filterPreset)
        case .makeup: MakeupPanel(selection: $tools.makeupTool)
        case .settings: SettingsView()
        case .album: FeaturePlaceholderView(title: .album, detail: .albumDetail)
        case .aspectRatio: FeaturePlaceholderView(title: .aspectRatio, detail: .aspectRatioDetail, current: .nativeSensor)
        case .timer: FeaturePlaceholderView(title: .timer, detail: .timerDetail, current: .timerOff)
        }
    }
}
