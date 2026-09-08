import SwiftUI

struct CaptureResultView: View {
    let photo: CapturedPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(uiImage: photo.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(L10n.capturedImage))
                Text(L10n.memoryOnly)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button { dismiss() } label: {
                    Text(L10n.backToCamera).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding([.horizontal, .bottom])
            }
            .navigationTitle(Text(L10n.captureResult))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
