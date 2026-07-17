import AttacheCore
import XCTest

/// INF-365: global summon hotkey. Covers the pure registration state machine
/// (set, persist-implying replace, clear) and the shortcut label formatter,
/// independent of Carbon/RegisterEventHotKey which cannot run in a unit test.
final class GlobalHotKeyTests: XCTestCase {
    private let specA = GlobalHotKeySpec(keyCode: 49, modifiers: [.command, .option]) // ⌘⌥Space
    private let specB = GlobalHotKeySpec(keyCode: 0, modifiers: [.control, .shift]) // ⌃⇧A

    // MARK: State machine

    func testDefaultIsOffAndClearingWhileOffIsANoOp() {
        let transition = GlobalHotKeyStateMachine.apply(nil, to: .unregistered)
        XCTAssertEqual(transition.next, .unregistered)
        XCTAssertFalse(transition.shouldUnregisterPrevious)
        XCTAssertNil(transition.shouldRegister)
    }

    func testSettingFromUnregisteredRegistersDirectly() {
        let transition = GlobalHotKeyStateMachine.apply(specA, to: .unregistered)
        XCTAssertEqual(transition.next, .registered(specA))
        XCTAssertFalse(transition.shouldUnregisterPrevious)
        XCTAssertEqual(transition.shouldRegister, specA)
    }

    func testReplacingARegisteredShortcutUnregistersThenRegisters() {
        let transition = GlobalHotKeyStateMachine.apply(specB, to: .registered(specA))
        XCTAssertEqual(transition.next, .registered(specB))
        XCTAssertTrue(transition.shouldUnregisterPrevious)
        XCTAssertEqual(transition.shouldRegister, specB)
    }

    func testReapplyingTheSameShortcutDoesNotThrashRegistration() {
        let transition = GlobalHotKeyStateMachine.apply(specA, to: .registered(specA))
        XCTAssertEqual(transition.next, .registered(specA))
        XCTAssertFalse(transition.shouldUnregisterPrevious)
        XCTAssertNil(transition.shouldRegister)
    }

    func testClearingARegisteredShortcutUnregistersImmediately() {
        let transition = GlobalHotKeyStateMachine.apply(nil, to: .registered(specA))
        XCTAssertEqual(transition.next, .unregistered)
        XCTAssertTrue(transition.shouldUnregisterPrevious)
        XCTAssertNil(transition.shouldRegister)
    }

    func testDoubleClearIsIdempotent() {
        let first = GlobalHotKeyStateMachine.apply(nil, to: .registered(specA))
        let second = GlobalHotKeyStateMachine.apply(nil, to: first.next)
        XCTAssertEqual(second.next, .unregistered)
        XCTAssertFalse(second.shouldUnregisterPrevious)
        XCTAssertNil(second.shouldRegister)
    }

    // MARK: Persistence round-trip (the spec itself, not UserDefaults, which

    // lives in AppModel/AttacheAppTests)
    func testSpecRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(specA)
        let decoded = try JSONDecoder().decode(GlobalHotKeySpec.self, from: data)
        XCTAssertEqual(decoded, specA)
    }

    // MARK: Label formatting

    func testLabelIncludesAllModifiersInFixedOrder() {
        XCTAssertEqual(GlobalHotKeyLabelFormatter.label(for: specA), "\u{2325}\u{2318}Space")
        XCTAssertEqual(GlobalHotKeyLabelFormatter.label(for: specB), "\u{2303}\u{21E7}A")
    }

    func testUnknownKeyCodeFallsBackToNumericLabel() {
        let spec = GlobalHotKeySpec(keyCode: 9999, modifiers: [.command])
        XCTAssertEqual(GlobalHotKeyLabelFormatter.label(for: spec), "\u{2318}Key 9999")
    }
}
