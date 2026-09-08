import Combine

@MainActor
final class BeautyState: ObservableObject {
    @Published var parameters = BeautyParameters()
}
