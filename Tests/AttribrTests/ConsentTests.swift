import XCTest
@testable import Attribr

final class ConsentTests: XCTestCase {
    private let key = "com.mrvltechnologies.attribr.consent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultStateIsUnknown() {
        let mgr = ConsentManager()
        XCTAssertEqual(mgr.state, .unknown)
    }

    func testIsGrantedFalseWhenUnknown() {
        let mgr = ConsentManager()
        XCTAssertFalse(mgr.isGranted)
    }

    func testSetGranted() {
        let mgr = ConsentManager()
        mgr.set(.granted)
        XCTAssertEqual(mgr.state, .granted)
        XCTAssertTrue(mgr.isGranted)
    }

    func testSetRevoked() {
        let mgr = ConsentManager()
        mgr.set(.granted)
        mgr.set(.revoked)
        XCTAssertEqual(mgr.state, .revoked)
        XCTAssertFalse(mgr.isGranted)
    }

    func testStatePersistsAcrossInstances() {
        let mgr1 = ConsentManager()
        mgr1.set(.granted)

        let mgr2 = ConsentManager()
        XCTAssertEqual(mgr2.state, .granted, "State must survive re-initialisation")
    }

    func testRawValuesMatchExpected() {
        XCTAssertEqual(ConsentState.unknown.rawValue, "unknown")
        XCTAssertEqual(ConsentState.granted.rawValue, "granted")
        XCTAssertEqual(ConsentState.revoked.rawValue, "revoked")
    }

    func testTransitionUnknownToGrantedToRevoked() {
        let mgr = ConsentManager()
        XCTAssertEqual(mgr.state, .unknown)
        mgr.set(.granted)
        XCTAssertEqual(mgr.state, .granted)
        mgr.set(.revoked)
        XCTAssertEqual(mgr.state, .revoked)
    }
}
