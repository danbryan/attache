import XCTest
@testable import AttacheCore

final class AgentInstructionSendPolicyTests: XCTestCase {
    func testDefaultPolicyRequiresPerMessageConfirmation() {
        XCTAssertEqual(AgentInstructionSendPolicy.defaultValue, .confirmEveryInstruction)
        XCTAssertFalse(AgentInstructionSendPolicy.defaultValue.sendsDirectlyAfterSessionEnable)
    }

    func testDirectPolicySkipsFinalConfirmationAfterSessionEnable() {
        XCTAssertTrue(AgentInstructionSendPolicy.directAfterSessionEnable.sendsDirectlyAfterSessionEnable)
    }
}
