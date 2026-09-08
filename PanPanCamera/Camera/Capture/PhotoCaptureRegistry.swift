/// Queue-confined ownership. Invalidation releases the active slot, but retains
/// its delegate until the final callback; that callback cannot complete a newer ID.
struct PhotoCaptureRegistry<Processor> {
    private var processors: [Int64: Processor] = [:]
    private(set) var activeID: Int64?
    var count: Int { processors.count }

    mutating func register(_ processor: Processor, id: Int64) {
        precondition(activeID == nil && processors[id] == nil)
        processors[id] = processor
        activeID = id
    }

    /// Always releases this ID. Only the active capture may publish a result.
    mutating func finish(id: Int64) -> Bool {
        guard processors.removeValue(forKey: id) != nil, activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func invalidateActive() -> Bool {
        guard activeID != nil else { return false }
        activeID = nil
        return true
    }
}
