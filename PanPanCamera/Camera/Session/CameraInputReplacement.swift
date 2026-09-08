/// Executes one input transaction. The caller supplies capture-graph operations
/// and must call this on its session queue. A failed rollback leaves no input.
struct CameraInputReplacement<Input> {
    let input: Input?
    let switched: Bool
    var isConfigured: Bool { input != nil }

    static func perform(current: Input, replacement: Input,
                        begin: () -> Void, remove: (Input) -> Void,
                        canAdd: (Input) -> Bool, add: (Input) -> Void,
                        commit: () -> Void) -> Self {
        begin()
        defer { commit() }
        remove(current)
        if canAdd(replacement) {
            add(replacement)
            return Self(input: replacement, switched: true)
        }
        if canAdd(current) {
            add(current)
            return Self(input: current, switched: false)
        }
        return Self(input: nil, switched: false)
    }
}
