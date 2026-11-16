import Foundation

/**
 DkaGuard - ketoacidosis (DKA) protection, complex variant.

 Swift port of the AIMI DKA protection (OpenApsAIMI, branch dev_OAPSAIMI_DKA,
 plugins/aps/.../openAPSAIMI/dka/DkaGuard.kt and SemaglutideBasalFloor.kt).
 The thresholds and risk rules are kept identical to the Kotlin original.

 EXPERIMENTAL. Not a medical device. It does NOT replace ketone testing,
 medical advice, or manual insulin delivery by pen/syringe.

 What it detects (conservatively):
  1. Suspected insulin delivery failure: sustained high BG with no response
     despite insulin having been delivered (occlusion, bad cannula, expired
     insulin, pump failure).
  2. Prolonged severe hyperglycemia.
  3. Elevated blood ketones (manual entry), including euglycemic DKA risk
     (SGLT2 inhibitors, GLP-1 RA, illness).

 What it does:
  - Raises a risk level (none / watch / warning / critical) with actions.
  - Optionally pauses SMBs when delivery failure is suspected (default off: alerts only).

 All glucose values are mg/dL. This file is pure logic (no iOS frameworks) so it can be unit tested.
 */

enum DkaRisk: Int, Codable, Comparable {
    case noRisk = 0
    case watch = 1
    case warning = 2
    case critical = 3

    static func < (lhs: DkaRisk, rhs: DkaRisk) -> Bool { lhs.rawValue < rhs.rawValue }

    var displayName: String {
        switch self {
        case .noRisk: return NSLocalizedString("No risk detected", comment: "DKA risk level")
        case .watch: return NSLocalizedString("Watch", comment: "DKA risk level")
        case .warning: return NSLocalizedString("Warning", comment: "DKA risk level")
        case .critical: return NSLocalizedString("Critical", comment: "DKA risk level")
        }
    }

    var logName: String {
        switch self {
        case .noRisk: return "NONE"
        case .watch: return "WATCH"
        case .warning: return "WARNING"
        case .critical: return "CRITICAL"
        }
    }
}

struct DkaBgPoint: Equatable {
    let date: Date
    let mgdl: Double
}

struct DkaInput {
    let now: Date
    /// Recent CGM readings, any order. Should cover at least the last 6 h.
    let bgHistory: [DkaBgPoint]
    /// Insulin delivered by the pump (bolus + SMB + basal) in the last 3 h, in U.
    let insulinDelivered3h: Double
    /// Current insulin on board, in U.
    let iob: Double
    /// Carbs on board / recent carbs, in g.
    let carbs2h: Double
    /// Last manually entered blood ketone value in mmol/L, or nil.
    let ketoneMmol: Double?
    let ketoneDate: Date?
    /// Last infusion set / cannula change, or nil if unknown.
    let lastSiteChange: Date?
    var sickDay: Bool = false
    var onSglt2Inhibitor: Bool = false
    /// GLP-1 receptor agonist (e.g. semaglutide): reduced appetite/insulin need, vomiting can mask DKA.
    var onGlp1Ra: Bool = false
    /// Pump suspended time in the last 3 h, minutes.
    var pumpSuspendedMin3h: Int = 0
    /// Typical total daily dose, used to sanity check delivered insulin.
    let tdd: Double
}

struct DkaConfig {
    var enabled: Bool = true
    var restrictSmbOnSuspectedFailure: Bool = false // default: alerts only
    var highBg: Double = 250 // mg/dL, ~13.9 mmol/L
    var veryHighBg: Double = 300 // mg/dL, ~16.7 mmol/L
    var extremeBg: Double = 400 // mg/dL, ~22.2 mmol/L
    var minSensorCoverage: Double = 0.7 // fraction of expected readings required
    var ketoneValidity: TimeInterval = 4 * 3600
    var siteMaxAge: TimeInterval = 4 * 24 * 3600 // 4 days

    /// Builds the configuration from the user settings, with the same clamping as the AIMI original.
    init(settings: FreeAPSSettings) {
        enabled = true
        restrictSmbOnSuspectedFailure = settings.dkaRestrictSMB
        let high = min(max(NSDecimalNumber(decimal: settings.dkaHighBG).doubleValue, 180), 350)
        let veryHigh = max(min(max(NSDecimalNumber(decimal: settings.dkaVeryHighBG).doubleValue, 200), 400), high + 10)
        highBg = high
        veryHighBg = veryHigh
        extremeBg = max(400, veryHigh + 50)
    }

    init() {}
}

struct DkaDecision: Codable, Equatable {
    let risk: DkaRisk
    let allowSmb: Bool
    /// Multiply SMB size by this (1.0 = unchanged).
    let smbFactor: Double
    let messages: [String]
    let reasons: [String]

    static let noRisk = DkaDecision(risk: .noRisk, allowSmb: true, smbFactor: 1, messages: [], reasons: [])
}

struct DkaGuard {
    let cfg: DkaConfig

    init(_ cfg: DkaConfig = DkaConfig()) {
        self.cfg = cfg
    }

    func evaluate(_ i: DkaInput) -> DkaDecision {
        guard cfg.enabled else { return .noRisk }

        var reasons: [String] = []
        var actions: [String] = []
        var risk = DkaRisk.noRisk
        var suspectedFailure = false

        func raise(_ r: DkaRisk) { if r > risk { risk = r } }
        func action(_ a: String) { if !actions.contains(a) { actions.append(a) } }

        let bg = i.bgHistory.filter { $0.date <= i.now }.sorted { $0.date < $1.date }
        let current = bg.last.flatMap { i.now.timeIntervalSince($0.date) <= 15 * 60 ? $0 : nil }

        // ---- 1. Sustained hyperglycemia analysis (needs reliable CGM data) ----
        if let current = current {
            let aboveHigh = Self.minutesContinuouslyAbove(bg, now: i.now, threshold: cfg.highBg)
            let aboveVeryHigh = Self.minutesContinuouslyAbove(bg, now: i.now, threshold: cfg.veryHighBg)
            let slope1h = Self.slopePerHour(bg, now: i.now, windowMin: 60)
            let reliable = Self.coverage(bg, now: i.now, windowMin: 120) >= cfg.minSensorCoverage

            if reliable {
                if aboveHigh >= 120 {
                    reasons.append("BG > \(Int(cfg.highBg)) mg/dL for \(aboveHigh) min")
                    raise(.watch)
                }
                if aboveVeryHigh >= 120 {
                    reasons.append("BG > \(Int(cfg.veryHighBg)) mg/dL for \(aboveVeryHigh) min")
                    raise(.warning)
                }
                if aboveVeryHigh >= 240 || current.mgdl >= cfg.extremeBg {
                    reasons.append("Severe/prolonged hyperglycemia (\(Int(current.mgdl)) mg/dL)")
                    raise(.critical)
                }

                // ---- 2. Suspected delivery failure ----
                // High BG, not falling, despite meaningful insulin and no recent carbs.
                let expectedMinInsulin = max(0.5, i.tdd / 24.0 * 3 * 0.5) // >= half of normal 3 h need
                let insulinWasDelivered = i.insulinDelivered3h >= expectedMinInsulin
                let notResponding = slope1h >= -5.0 // < 5 mg/dL/h drop
                if aboveHigh >= 120, insulinWasDelivered, notResponding, i.carbs2h < 10 {
                    suspectedFailure = true
                    reasons.append("No glucose response to \(Self.fmt1(i.insulinDelivered3h)) U delivered in 3 h")
                    raise(.warning)
                }
                // Pump suspended a long time while high.
                if i.pumpSuspendedMin3h >= 60, current.mgdl > cfg.highBg {
                    reasons.append("Pump suspended \(i.pumpSuspendedMin3h) min while BG high")
                    raise(.warning)
                }
                // Old infusion site makes failure more likely.
                if suspectedFailure, let site = i.lastSiteChange, i.now.timeIntervalSince(site) > cfg.siteMaxAge {
                    reasons.append("Infusion site older than \(Int(cfg.siteMaxAge / 86400)) days")
                }
            } else {
                reasons.append("CGM data too sparse for reliable DKA assessment")
            }
        }

        // ---- 3. Ketones ----
        var ketoneFresh = false
        if let k = i.ketoneMmol, let kDate = i.ketoneDate, i.now.timeIntervalSince(kDate) <= cfg.ketoneValidity {
            ketoneFresh = true
            if k >= 3.0 {
                reasons.append("Ketones \(Self.fmt1(k)) mmol/L (>= 3.0)"); raise(.critical)
            } else if k >= 1.5 {
                reasons.append("Ketones \(Self.fmt1(k)) mmol/L (>= 1.5)"); raise(.warning)
            } else if k >= 0.6 {
                reasons.append("Ketones \(Self.fmt1(k)) mmol/L (>= 0.6)"); raise(.watch)
            }
            // Euglycemic DKA: ketones matter even when BG is normal.
            if k >= 1.5, i.onSglt2Inhibitor || i.onGlp1Ra || i.sickDay, (current?.mgdl ?? 999) < cfg.highBg {
                reasons.append("Elevated ketones with normal BG (SGLT2i/GLP-1 RA/illness): euglycemic DKA possible")
                raise(.critical)
            }
        }

        // Sick day / SGLT2i / GLP-1 RA with high BG and no ketone measurement: ask for one.
        if i.sickDay || i.onSglt2Inhibitor || i.onGlp1Ra, !ketoneFresh, (current?.mgdl ?? 0) > 180, risk < .watch {
            reasons.append("Sick day / SGLT2i / GLP-1 RA without recent ketone measurement")
            raise(.watch)
        }

        // ---- Actions per level ----
        switch risk {
        case .noRisk: break
        case .watch:
            action(NSLocalizedString("Check blood ketones.", comment: "DKA action"))
            action(NSLocalizedString("Drink water; recheck BG in 1 h.", comment: "DKA action"))
        case .warning:
            action(NSLocalizedString("Check blood ketones now.", comment: "DKA action"))
            action(NSLocalizedString("Change infusion set and insulin reservoir.", comment: "DKA action"))
            action(NSLocalizedString(
                "Take a correction dose by pen/syringe (not via pump) per your doctor's plan.",
                comment: "DKA action"
            ))
            action(NSLocalizedString("Hydrate; recheck BG and ketones in 1-2 h.", comment: "DKA action"))
        case .critical:
            action(NSLocalizedString("URGENT: check ketones immediately.", comment: "DKA action"))
            action(NSLocalizedString(
                "Follow your sick-day/DKA plan; inject insulin by pen/syringe.",
                comment: "DKA action"
            ))
            action(NSLocalizedString(
                "Contact your diabetes team or emergency services now if ketones >= 3.0 mmol/L, or if you have vomiting, abdominal pain, fast breathing or confusion.",
                comment: "DKA action"
            ))
        }

        // ---- Loop behavior ----
        var allowSmb = true
        var smbFactor = 1.0
        if cfg.restrictSmbOnSuspectedFailure, suspectedFailure {
            // If delivery is failing, more SMBs only build a hidden insulin depot
            // that may cause hypoglycemia once the new set works.
            allowSmb = false
            smbFactor = 0
            action(NSLocalizedString(
                "SMB paused: insulin delivery appears ineffective (avoid insulin stacking).",
                comment: "DKA action"
            ))
        }

        return DkaDecision(risk: risk, allowSmb: allowSmb, smbFactor: smbFactor, messages: actions, reasons: reasons)
    }

    // MARK: - Helpers

    /// Minutes the glucose has been continuously above `threshold` up to now. `bg` sorted ascending.
    static func minutesContinuouslyAbove(_ bg: [DkaBgPoint], now: Date, threshold: Double) -> Int {
        var start: Date?
        for p in bg.reversed() {
            if p.mgdl > threshold { start = p.date } else { break }
        }
        guard let start = start else { return 0 }
        return Int(now.timeIntervalSince(start) / 60)
    }

    /// Linear-regression slope in mg/dL per hour over the last `windowMin` minutes. `bg` sorted ascending.
    static func slopePerHour(_ bg: [DkaBgPoint], now: Date, windowMin: Int) -> Double {
        let pts = bg.filter { now.timeIntervalSince($0.date) <= Double(windowMin) * 60 }
        guard pts.count >= 4, let t0 = pts.first?.date else { return 0 }
        let xs = pts.map { $0.date.timeIntervalSince(t0) / 3600 }
        let ys = pts.map(\.mgdl)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let denom = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard denom != 0 else { return 0 }
        var num = 0.0
        for k in xs.indices { num += (xs[k] - mx) * (ys[k] - my) }
        return num / denom
    }

    /// Fraction of expected 5-min readings present in the last `windowMin` minutes.
    /// 1-minute CGM data is capped at 1.0.
    static func coverage(_ bg: [DkaBgPoint], now: Date, windowMin: Int) -> Double {
        let n = bg.filter { now.timeIntervalSince($0.date) <= Double(windowMin) * 60 }.count
        return min(1.0, Double(n) / (Double(windowMin) / 5.0))
    }

    static func fmt1(_ v: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}

// MARK: - Semaglutide / GLP-1 minimum insulin (basal floor)

struct DkaFloorConfig: Equatable {
    var enabled: Bool = false
    var percent: Int = 50
    var minBgMgdl: Int = 100

    init(enabled: Bool = false, percent: Int = 50, minBgMgdl: Int = 100) {
        self.enabled = enabled
        self.percent = percent
        self.minBgMgdl = minBgMgdl
    }

    init(settings: FreeAPSSettings) {
        enabled = settings.dkaFloorEnabled
        percent = min(max(Int(NSDecimalNumber(decimal: settings.dkaFloorPercent).doubleValue.rounded()), 10), 100)
        minBgMgdl = min(max(Int(NSDecimalNumber(decimal: settings.dkaFloorMinBG).doubleValue.rounded()), 70), 180)
    }
}

/// Keeps the loop's basal at or above a percentage of the scheduled basal rate, so insulin is not
/// driven to ~0 for hours (ketosis/DKA risk in type 1).
/// Hypoglycemia always wins: the floor is not applied when BG is low, predicted low, or unknown.
enum SemaglutideBasalFloor {
    struct Result: Equatable {
        let rate: Double
        let applied: Bool
        let note: String?
    }

    static func apply(
        proposedRate: Double,
        scheduledBasal: Double,
        bgMgdl: Double?,
        eventualBgMgdl: Double?,
        cfg: DkaFloorConfig,
        maxBasal: Double
    ) -> Result {
        guard cfg.enabled, scheduledBasal > 0, proposedRate.isFinite else {
            return Result(rate: proposedRate, applied: false, note: nil)
        }
        let percent = min(max(cfg.percent, 10), 100)
        let floor = min(scheduledBasal * Double(percent) / 100.0, maxBasal)
        if proposedRate >= floor { return Result(rate: proposedRate, applied: false, note: nil) }
        guard let bg = bgMgdl, bg.isFinite else {
            return Result(rate: proposedRate, applied: false, note: "Floor skipped: no current BG")
        }
        if bg <= Double(cfg.minBgMgdl) {
            return Result(
                rate: proposedRate, applied: false,
                note: "Floor skipped: BG \(Int(bg)) <= \(cfg.minBgMgdl) mg/dL"
            )
        }
        if let eventual = eventualBgMgdl, eventual.isFinite, eventual < Double(cfg.minBgMgdl) {
            return Result(
                rate: proposedRate, applied: false,
                note: "Floor skipped: eventual BG \(Int(eventual)) mg/dL is low"
            )
        }
        let note = String(
            format: "Semaglutide floor: %.2f -> %.2f U/h (%d%% of %.2f)",
            locale: Locale(identifier: "en_US_POSIX"),
            proposedRate, floor, percent, scheduledBasal
        )
        return Result(rate: floor, applied: true, note: note)
    }
}

// MARK: - Ketone unit

/// Unit for entering blood ketones (BHB). The guard always works in mmol/L.
enum KetoneUnit: String, CaseIterable, Identifiable {
    case mmol
    case mgdl

    var id: String { rawValue }

    var mgdlPerMmol: Double {
        switch self {
        case .mmol: return 1.0
        case .mgdl: return 10.41
        }
    }

    var displayName: String {
        switch self {
        case .mmol: return "mmol/L"
        case .mgdl: return "mg/dL"
        }
    }

    func toMmol(_ value: Double) -> Double { value / mgdlPerMmol }
    func fromMmol(_ mmol: Double) -> Double { mmol * mgdlPerMmol }
}
