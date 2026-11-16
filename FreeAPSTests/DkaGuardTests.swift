@testable import FreeAPS
import XCTest

/// Port of DkaGuardTest.kt / SemaglutideBasalFloorTest.kt (OpenApsAIMI) plus the iAPS specific parts.
final class DkaGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// One reading every 5 minutes, newest at `now`; `value` maps minutes-ago to mg/dL.
    private func series(_ minutes: Int, _ value: (Int) -> Double) -> [DkaBgPoint] {
        stride(from: 0, through: minutes, by: 5).map { ago in
            DkaBgPoint(date: now.addingTimeInterval(-Double(ago) * 60), mgdl: value(ago))
        }
    }

    private func input(
        _ bg: [DkaBgPoint],
        delivered3h: Double = 3,
        carbs: Double = 0,
        ketone: Double? = nil,
        ketoneAgoMin: Int = 10,
        sick: Bool = false,
        sglt2: Bool = false,
        glp1: Bool = false,
        tdd: Double = 40
    ) -> DkaInput {
        DkaInput(
            now: now, bgHistory: bg, insulinDelivered3h: delivered3h, iob: 1, carbs2h: carbs,
            ketoneMmol: ketone, ketoneDate: ketone.map { _ in now.addingTimeInterval(-Double(ketoneAgoMin) * 60) },
            lastSiteChange: nil, sickDay: sick, onSglt2Inhibitor: sglt2, onGlp1Ra: glp1,
            pumpSuspendedMin3h: 0, tdd: tdd
        )
    }

    private func config(restrictSmb: Bool = false, enabled: Bool = true) -> DkaConfig {
        var c = DkaConfig()
        c.restrictSmbOnSuspectedFailure = restrictSmb
        c.enabled = enabled
        return c
    }

    // MARK: DkaGuard

    func testFlat280For6hDespiteInsulinWarnsAndFlagsDeliveryFailure() {
        let d = DkaGuard().evaluate(input(series(360) { _ in 280 }))
        XCTAssertEqual(d.risk, .warning)
        XCTAssertTrue(d.reasons.joined().contains("No glucose response"))
        XCTAssertTrue(d.allowSmb) // alerts only by default
    }

    func testSmbPauseOnlyWhenEnabledAndDeliveryFailureSuspected() {
        let bg = series(360) { _ in 280 }
        let on = DkaGuard(config(restrictSmb: true)).evaluate(input(bg))
        XCTAssertFalse(on.allowSmb)
        XCTAssertEqual(on.smbFactor, 0)
        let off = DkaGuard(config(restrictSmb: false)).evaluate(input(bg))
        XCTAssertTrue(off.allowSmb)
    }

    func testHighBgThatIsFallingIsNotADeliveryFailure() {
        // 400 mg/dL six hours ago, falling 40 mg/dL per hour to 160 now
        let bg = series(360) { ago in 160 + Double(ago) / 60 * 40 }
        let d = DkaGuard(config(restrictSmb: true)).evaluate(input(bg))
        XCTAssertEqual(d.risk, .noRisk)
        XCTAssertTrue(d.allowSmb)
    }

    func testNoFailureSuspectedWhenLittleInsulinWasDelivered() {
        let d = DkaGuard().evaluate(input(series(360) { _ in 280 }, delivered3h: 0.1))
        XCTAssertFalse(d.reasons.joined().contains("No glucose response"))
    }

    func testKetones3point2AreCriticalEvenWithNormalGlucose() {
        XCTAssertEqual(DkaGuard().evaluate(input(series(360) { _ in 110 }, ketone: 3.2)).risk, .critical)
    }

    func testKetoneBands() {
        func risk(_ k: Double) -> DkaRisk { DkaGuard().evaluate(input(series(360) { _ in 110 }, ketone: k)).risk }
        XCTAssertEqual(risk(0.4), .noRisk)
        XCTAssertEqual(risk(0.8), .watch)
        XCTAssertEqual(risk(1.6), .warning)
        XCTAssertEqual(risk(3.0), .critical)
    }

    func testEuglycemicDkaPatternWithSglt2InhibitorIsCritical() {
        let d = DkaGuard().evaluate(input(series(360) { _ in 110 }, ketone: 1.6, sglt2: true))
        XCTAssertEqual(d.risk, .critical)
        XCTAssertTrue(d.reasons.joined().contains("euglycemic"))
    }

    func testStaleKetoneValueIsIgnored() {
        let d = DkaGuard().evaluate(input(series(360) { _ in 110 }, ketone: 3.5, ketoneAgoMin: 5 * 60))
        XCTAssertEqual(d.risk, .noRisk)
    }

    func testGlp1UserWithRaisedGlucoseAndNoKetoneValueIsAskedToMeasure() {
        let d = DkaGuard().evaluate(input(series(360) { _ in 200 }, glp1: true))
        XCTAssertEqual(d.risk, .watch)
        XCTAssertTrue(d.reasons.joined().contains("GLP-1"))
    }

    func testSparseCgmDataIsNotJudged() {
        let sparse = [
            DkaBgPoint(date: now, mgdl: 300),
            DkaBgPoint(date: now.addingTimeInterval(-60 * 60), mgdl: 300),
            DkaBgPoint(date: now.addingTimeInterval(-110 * 60), mgdl: 300)
        ]
        let d = DkaGuard().evaluate(input(sparse))
        XCTAssertEqual(d.risk, .noRisk)
        XCTAssertTrue(d.reasons.joined().contains("sparse"))
    }

    func test400mgdlIsCritical() {
        XCTAssertEqual(DkaGuard().evaluate(input(series(360) { _ in 410 })).risk, .critical)
    }

    func testDisabledGuardStaysSilent() {
        let d = DkaGuard(config(enabled: false)).evaluate(input(series(360) { _ in 410 }, ketone: 4))
        XCTAssertEqual(d.risk, .noRisk)
        XCTAssertTrue(d.allowSmb)
        XCTAssertTrue(d.messages.isEmpty)
    }

    func testConfigFromSettingsClampsThresholds() {
        var s = FreeAPSSettings()
        s.dkaHighBG = 100 // below 180
        s.dkaVeryHighBG = 150 // below high + 10
        let c = DkaConfig(settings: s)
        XCTAssertEqual(c.highBg, 180)
        XCTAssertEqual(c.veryHighBg, 200)
        XCTAssertEqual(c.extremeBg, 400)
    }

    // MARK: Semaglutide basal floor

    private let floorCfg = DkaFloorConfig(enabled: true, percent: 50, minBgMgdl: 100)

    private func applyFloor(
        proposed: Double = 0, scheduled: Double = 1, bg: Double? = 180, eventual: Double? = 150,
        cfg: DkaFloorConfig? = nil, max: Double = 3
    ) -> SemaglutideBasalFloor.Result {
        SemaglutideBasalFloor.apply(
            proposedRate: proposed, scheduledBasal: scheduled, bgMgdl: bg, eventualBgMgdl: eventual,
            cfg: cfg ?? floorCfg, maxBasal: max
        )
    }

    func testZeroTempIsRaisedToThePercentageOfScheduledBasal() {
        let r = applyFloor()
        XCTAssertTrue(r.applied)
        XCTAssertEqual(r.rate, 0.5, accuracy: 1e-9)
        XCTAssertTrue(r.note?.contains("50%") ?? false)
    }

    func testRateAboveTheFloorIsUntouched() {
        let r = applyFloor(proposed: 0.8)
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.rate, 0.8)
        XCTAssertNil(r.note)
    }

    func testLowGlucoseAlwaysWinsOverTheFloor() {
        let r = applyFloor(bg: 95)
        XCTAssertFalse(r.applied)
        XCTAssertEqual(r.rate, 0)
        XCTAssertTrue(r.note?.contains("skipped") ?? false)
        XCTAssertFalse(applyFloor(bg: 100).applied)
        XCTAssertTrue(applyFloor(bg: 101).applied)
    }

    func testPredictedLowOrMissingGlucoseSkipsTheFloor() {
        XCTAssertFalse(applyFloor(eventual: 80).applied)
        XCTAssertFalse(applyFloor(bg: nil).applied)
        XCTAssertTrue(applyFloor(eventual: nil).applied)
    }

    func testFloorLimitsAndClamping() {
        XCTAssertEqual(applyFloor(scheduled: 4, cfg: DkaFloorConfig(enabled: true, percent: 100), max: 3).rate, 3, accuracy: 1e-9)
        XCTAssertEqual(applyFloor(cfg: DkaFloorConfig(enabled: true, percent: 5)).rate, 0.1, accuracy: 1e-9)
        XCTAssertFalse(applyFloor(cfg: DkaFloorConfig(enabled: false)).applied)
        XCTAssertFalse(applyFloor(scheduled: 0).applied)
        XCTAssertFalse(applyFloor(proposed: .nan).applied)
    }

    // MARK: Insulin delivered from pump history

    func testInsulinDeliveredCountsBolusesTempsScheduledBasalAndSuspend() {
        let start = now.addingTimeInterval(-3 * 3600)
        let events = [
            PumpHistoryEvent(id: "b1", type: .bolus, timestamp: start.addingTimeInterval(600), amount: 1),
            PumpHistoryEvent(id: "x1", type: .bolus, timestamp: start.addingTimeInterval(700), amount: 5, isExternal: true),
            // 60 min temp at 2 U/h starting at +60 min
            PumpHistoryEvent(id: "t1", type: .tempBasal, timestamp: start.addingTimeInterval(3600), rate: 2, temp: .absolute),
            PumpHistoryEvent(id: "d1", type: .tempBasalDuration, timestamp: start.addingTimeInterval(3600), durationMin: 60),
            // suspended for the last 30 min
            PumpHistoryEvent(id: "s1", type: .pumpSuspend, timestamp: now.addingTimeInterval(-1800))
        ]
        let r = DkaProtection.insulinDelivered(events: events, from: start, to: now, scheduledBasal: 1)
        // bolus 1 + scheduled 60 min × 1 + temp 60 min × 2 + scheduled 30 min × 1 + suspended 30 min × 0
        XCTAssertEqual(r.units, 1 + 1 + 2 + 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.suspendedMinutes, 30)
    }

    // MARK: Settings: mode selection

    func testKetoProtectionModeIsExclusive() {
        var s = FreeAPSSettings()
        XCTAssertEqual(s.ketoProtectionMode, .off)
        s.ketoProtectionMode = .simple
        XCTAssertTrue(s.ketoProtect)
        XCTAssertFalse(s.ketoProtectComplex)
        s.ketoProtectionMode = .complex
        XCTAssertFalse(s.ketoProtect)
        XCTAssertTrue(s.ketoProtectComplex)
        s.ketoProtectionMode = .off
        XCTAssertFalse(s.ketoProtect)
        XCTAssertFalse(s.ketoProtectComplex)
        // Both flags stored (e.g. hand edited file): complex wins
        s.ketoProtect = true
        s.ketoProtectComplex = true
        XCTAssertEqual(s.ketoProtectionMode, .complex)
    }

    func testExistingSimpleSettingIsKeptAfterUpdate() throws {
        // A settings file from before this change only knows ketoProtect.
        let old = #"{"ketoProtect": true, "ketoProtectBasalPercent": 30}"#
        let decoded = try JSONCoding.decoder.decode(FreeAPSSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.ketoProtectionMode, .simple)
        XCTAssertEqual(decoded.ketoProtectBasalPercent, 30)
    }
}
