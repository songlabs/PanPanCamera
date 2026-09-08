import XCTest
@testable import PanPanCamera

final class CameraSessionControlTests: XCTestCase {
    private func replace(allowed: Set<CameraPosition>) -> (CameraInputReplacement<CameraPosition>, [String]) {
        var operations: [String] = []
        let result = CameraInputReplacement<CameraPosition>.perform(
            current: .back, replacement: .front,
            begin: { operations.append("begin") },
            remove: { operations.append("remove.\($0.rawValue)") },
            canAdd: { operations.append("canAdd.\($0.rawValue)"); return allowed.contains($0) },
            add: { operations.append("add.\($0.rawValue)") },
            commit: { operations.append("commit") }
        )
        return (result, operations)
    }

    func testInputReplacementCommitsFrontInput() {
        let (result, operations) = replace(allowed: [.front, .back])
        XCTAssertEqual(result.input, .front)
        XCTAssertTrue(result.switched)
        XCTAssertTrue(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "add.front", "commit"])
    }

    func testRejectedFrontInputRestoresRearWithinSameTransaction() {
        let (result, operations) = replace(allowed: [.back])
        XCTAssertEqual(result.input, .back)
        XCTAssertFalse(result.switched)
        XCTAssertTrue(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "canAdd.back", "add.back", "commit"])
    }

    func testFailedRollbackCommitsUnconfiguredResult() {
        let (result, operations) = replace(allowed: [])
        XCTAssertNil(result.input)
        XCTAssertFalse(result.switched)
        XCTAssertFalse(result.isConfigured)
        XCTAssertEqual(operations, ["begin", "remove.back", "canAdd.front", "canAdd.back", "commit"])
    }

    func testMediaResetRestartsOnlyWhileRunningIsWanted() {
        var lifecycle = CameraSessionLifecycle()
        var commands: [String] = []
        lifecycle.wantsRunning = true
        lifecycle.recover(wasReset: true, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["restart"])
        lifecycle.wantsRunning = false
        lifecycle.recover(wasReset: true, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["restart"])
    }

    func testOtherRuntimeErrorReportsFailureOnlyWhileActive() {
        var lifecycle = CameraSessionLifecycle()
        var commands: [String] = []
        lifecycle.wantsRunning = true
        lifecycle.recover(wasReset: false, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["failed"])
        lifecycle.wantsRunning = false
        lifecycle.recover(wasReset: false, restart: { commands.append("restart") },
                          reportFailure: { commands.append("failed") })
        XCTAssertEqual(commands, ["failed"])
    }
}
