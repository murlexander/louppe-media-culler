import XCTest
@testable import Louppe

final class QualityCueWorkPolicyTests: XCTestCase {
    func testQuickBackgroundWorkHasARealMinimumRest() {
        let normal = QualityCueWorkPolicy.Resources(lowPower: false, thermal: .nominal)
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .zero, resources: normal), .milliseconds(100))
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(20), resources: normal), .milliseconds(100))
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(-20), resources: normal), .milliseconds(100))
    }

    func testNormalBackgroundRestTracksSlowDecodeWork() {
        let normal = QualityCueWorkPolicy.Resources(lowPower: false, thermal: .nominal)
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(400), resources: normal), .milliseconds(400))
    }

    func testLowPowerAndThermalStatesIncreaseRest() {
        for state in [QualityCueWorkPolicy.Resources(lowPower: true, thermal: .nominal),
                      .init(lowPower: false, thermal: .serious)] {
            XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(400), resources: state), .milliseconds(1_200))
        }
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(400), resources:
            .init(lowPower: false, thermal: .critical)), .milliseconds(2_800))
        XCTAssertEqual(QualityCueWorkPolicy.rest(after: .milliseconds(400), resources:
            .init(lowPower: true, thermal: .critical)), .milliseconds(2_800))
    }
}
