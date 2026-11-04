import XCTest

@testable import CleanerCore

final class QuickMemoryCleanupTests: XCTestCase {
  func testThresholdSustainedCooldownAndSwitch() {
    var policy = AutoCleanPolicy(threshold: 85, cooldown: 900)
    let t = Date(timeIntervalSince1970: 1000)
    XCTAssertFalse(policy.shouldAttempt(percent: 90, enabled: false, now: t))
    XCTAssertFalse(policy.shouldAttempt(percent: 90, enabled: true, now: t))
    XCTAssertFalse(policy.shouldAttempt(percent: 90, enabled: true, now: t.addingTimeInterval(29)))
    XCTAssertTrue(policy.shouldAttempt(percent: 90, enabled: true, now: t.addingTimeInterval(30)))
    XCTAssertFalse(policy.shouldAttempt(percent: 90, enabled: true, now: t.addingTimeInterval(100)))
    XCTAssertTrue(policy.shouldAttempt(percent: 90, enabled: true, now: t.addingTimeInterval(931)))
  }
  func testRecoveryAndInvalidReadResetTrigger() {
    var p = AutoCleanPolicy()
    let t = Date()
    _ = p.shouldAttempt(percent: 90, enabled: true, now: t)
    XCTAssertFalse(p.shouldAttempt(percent: 84, enabled: true, now: t.addingTimeInterval(20)))
    XCTAssertFalse(p.shouldAttempt(percent: 90, enabled: true, now: t.addingTimeInterval(31)))
    XCTAssertFalse(p.shouldAttempt(percent: .nan, enabled: true, now: t.addingTimeInterval(80)))
  }
  func testSudoersScriptRejectsUnsafeUserNamesAndValidatesBeforeInstall() throws {
    XCTAssertThrowsError(try QuickMemoryCleanup.sudoersInstallScript(user: "bob'; rm -rf /"))
    XCTAssertThrowsError(try QuickMemoryCleanup.sudoersInstallScript(user: ""))
    let script = try QuickMemoryCleanup.sudoersInstallScript(user: "marcus.bey")
    XCTAssertTrue(script.contains("'marcus.bey'"))
    XCTAssertTrue(script.contains("NOPASSWD: /usr/sbin/purge\\n"))
    let validate = try XCTUnwrap(script.range(of: "visudo -cf"))
    let install = try XCTUnwrap(script.range(of: "/usr/bin/install"))
    XCTAssertLessThan(validate.lowerBound, install.lowerBound)
  }
  func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
    XCTAssertEqual(QuickMemoryCleanup.appleScriptLiteral(#"a "b" \c"#), #""a \"b\" \\c""#)
  }
  func testHelperProcessesResolveToOutermostRunningApp() {
    let bundles = ["/Applications/Brave Browser.app", "/Applications/Brave.app"]
    XCTAssertEqual(
      MemoryMonitor.owningBundle(
        of: "/Applications/Brave Browser.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/x",
        in: bundles + ["/Applications/Brave Browser.app/Contents/Frameworks/Helper (Renderer).app"]),
      "/Applications/Brave Browser.app")
    XCTAssertNil(MemoryMonitor.owningBundle(of: "/Applications/Brave.apple/x", in: bundles))
    XCTAssertEqual(MemoryMonitor.owningBundle(of: "/Applications/Brave.app/x", in: bundles), "/Applications/Brave.app")
  }
}
