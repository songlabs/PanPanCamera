import SwiftUI

struct CameraStatusView: View {
    let state: CameraState
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "camera").font(.system(size: 36, weight: .light))
                switch state.access {
                case .denied:
                    Text(L10n.permissionTitle).font(.headline)
                    Text(L10n.permissionDetail)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: { Text(L10n.openSettings) }
                    .buttonStyle(.borderedProminent)
                case .restricted:
                    Text(L10n.permissionTitle).font(.headline)
                    Text(L10n.permissionRestricted)
                case .unknown, .requesting:
                    ProgressView().tint(.white)
                    Text(L10n.requestingPermission)
                case .authorized:
                    authorizedStatus
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }

    @ViewBuilder
    private var authorizedStatus: some View {
        switch state.status {
        case .idle, .configuring:
            ProgressView().tint(.white)
            Text(L10n.startingCamera)
        case .unavailable:
            Text(L10n.cameraUnavailable).font(.headline)
            Text(L10n.cameraUnavailableDetail)
        case .interrupted:
            Text(L10n.cameraInterrupted)
            Button(action: retry) { Text(L10n.retry) }.buttonStyle(.borderedProminent)
        case .failed:
            Text(L10n.cameraFailed)
            Button(action: retry) { Text(L10n.retry) }.buttonStyle(.borderedProminent)
        case .running: EmptyView()
        }
    }
}
