import Foundation
import UserNotifications

// Ketoacidosis protection, complex variant (AIMI DKA guard): state, notifications and loop integration.
// Port of AimiDkaSettings.kt / AimiDkaUi.kt / AimiDkaCoordinator.kt (OpenApsAIMI, dev_OAPSAIMI_DKA).

// MARK: - Ketone value (manual entry) and last decision

/// Manually entered ketone value, snooze and last evaluation. Transient state, not a user preference.
enum DkaStateStore {
    private static let defaults = UserDefaults.standard
    private static let kKetoneMmol = "dka.ketone.mmol"
    private static let kKetoneDate = "dka.ketone.date"
    private static let kKetoneUnit = "dka.ketone.unit"
    private static let kLastDecision = "dka.lastDecision"
    private static let kLastDecisionDate = "dka.lastDecisionDate"
    private static let kLastRisk = "dka.notify.lastRisk"
    private static let kLastAlert = "dka.notify.lastAlert"
    private static let kSnoozeUntil = "dka.notify.snoozeUntil"

    /// Ketone values are used for 4 hours after entry.
    static let ketoneValidity: TimeInterval = 4 * 3600

    struct KetoneReading: Equatable {
        let mmol: Double
        let date: Date
    }

    static func saveKetone(mmol: Double, date: Date = Date()) {
        defaults.set(mmol, forKey: kKetoneMmol)
        defaults.set(date.timeIntervalSince1970, forKey: kKetoneDate)
    }

    static func clearKetone() {
        defaults.removeObject(forKey: kKetoneMmol)
        defaults.removeObject(forKey: kKetoneDate)
    }

    static func ketone() -> KetoneReading? {
        let ts = defaults.double(forKey: kKetoneDate)
        guard ts > 0 else { return nil }
        return KetoneReading(mmol: defaults.double(forKey: kKetoneMmol), date: Date(timeIntervalSince1970: ts))
    }

    static var ketoneUnit: KetoneUnit {
        get { KetoneUnit(rawValue: defaults.string(forKey: kKetoneUnit) ?? "") ?? .mmol }
        set { defaults.set(newValue.rawValue, forKey: kKetoneUnit) }
    }

    static func saveDecision(_ decision: DkaDecision, date: Date) {
        if let data = try? JSONEncoder().encode(decision) {
            defaults.set(data, forKey: kLastDecision)
            defaults.set(date.timeIntervalSince1970, forKey: kLastDecisionDate)
        }
    }

    static func lastDecision() -> (decision: DkaDecision, date: Date)? {
        guard let data = defaults.data(forKey: kLastDecision),
              let decision = try? JSONDecoder().decode(DkaDecision.self, from: data) else { return nil }
        return (decision, Date(timeIntervalSince1970: defaults.double(forKey: kLastDecisionDate)))
    }

    static func clearDecision() {
        defaults.removeObject(forKey: kLastDecision)
        defaults.removeObject(forKey: kLastDecisionDate)
    }

    // Notification state
    static var lastNotifiedRisk: DkaRisk {
        get { DkaRisk(rawValue: defaults.integer(forKey: kLastRisk)) ?? .noRisk }
        set { defaults.set(newValue.rawValue, forKey: kLastRisk) }
    }

    static var lastAlert: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: kLastAlert)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: kLastAlert) }
    }

    static var snoozeUntil: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: kSnoozeUntil)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: kSnoozeUntil) }
    }
}

// MARK: - Notifications

/// Posts/updates the DKA notification once per loop cycle. Re-alerts are rate limited.
///  watch    - passive, repeats every 2 h, snoozable
///  warning  - time sensitive with sound, repeats every 60 min, snoozable for 1 h
///  critical - time sensitive with critical sound, repeats every 15 min, NOT snoozable
enum DkaNotifier {
    static let identifier = "iAPS.dkaProtection"
    static let snoozeDuration: TimeInterval = 3600

    static func update(_ d: DkaDecision, notifyOnWatch: Bool, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        if d.risk == .noRisk || (d.risk == .watch && !notifyOnWatch) {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            DkaStateStore.lastNotifiedRisk = .noRisk
            return
        }

        let lastRisk = DkaStateStore.lastNotifiedRisk
        let escalated = d.risk > lastRisk
        let snoozed = d.risk != .critical && now < DkaStateStore.snoozeUntil && !escalated
        if snoozed { return }

        let due = now.timeIntervalSince(DkaStateStore.lastAlert) >= repeatInterval(d.risk)
        guard escalated || due else { return }

        let content = UNMutableNotificationContent()
        switch d.risk {
        case .critical:
            content.title = NSLocalizedString("DKA risk: CRITICAL - act now", comment: "DKA notification title")
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
        case .warning:
            content.title = NSLocalizedString("DKA risk: WARNING - check ketones", comment: "DKA notification title")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        default:
            content.title = NSLocalizedString("DKA risk: watch", comment: "DKA notification title")
            content.interruptionLevel = .passive
        }
        content.body = (d.messages + d.reasons).joined(separator: "\n")

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(request) { error in
            if let error = error {
                warning(.openAPS, "DKA protection: unable to post notification", error: error)
            }
        }
        DkaStateStore.lastNotifiedRisk = d.risk
        DkaStateStore.lastAlert = now
    }

    /// Snoozes watch/warning notifications for one hour. Critical alerts are never snoozed.
    static func snooze(now: Date = Date()) {
        DkaStateStore.snoozeUntil = now.addingTimeInterval(snoozeDuration)
    }

    private static func repeatInterval(_ risk: DkaRisk) -> TimeInterval {
        switch risk {
        case .critical: return 15 * 60
        case .warning: return 60 * 60
        default: return 2 * 3600
        }
    }
}

// MARK: - Loop integration

/// Post-processes the oref suggestion once per loop cycle (complex keto protection):
///  1. evaluates DKA risk and posts/updates the notification,
///  2. optionally pauses the SMB when insulin delivery looks ineffective,
///  3. enforces the semaglutide minimum basal (percentage of the scheduled basal).
enum DkaProtection {
    struct Inputs {
        let now: Date
        let glucose: [BloodGlucose]
        let pumpHistory: [PumpHistoryEvent]
        /// 24 h insulin (bolus + basal), U. 0 when unknown.
        let tdd: Double
        /// Scheduled basal rate right now (U/h).
        let scheduledBasal: Double
        /// Upper limit for the floor (U/h).
        let maxBasal: Double
        /// Currently running temp basal: rate (U/h) and minutes left; 0 when none.
        let runningTempRate: Double
        let runningTempMinutes: Int
    }

    static func process(_ suggestion: Suggestion, settings: FreeAPSSettings, inputs i: Inputs) -> Suggestion {
        var suggestion = suggestion
        var notes: [String] = []

        // 1) DKA risk + notification
        let bgHistory: [DkaBgPoint] = i.glucose.compactMap { g in
            guard i.now.timeIntervalSince(g.dateString) <= 6 * 3600, let value = g.glucose ?? g.sgv, value > 0 else { return nil }
            return DkaBgPoint(date: g.dateString, mgdl: Double(value))
        }
        let delivery = insulinDelivered(
            events: i.pumpHistory,
            from: i.now.addingTimeInterval(-3 * 3600),
            to: i.now,
            scheduledBasal: i.scheduledBasal
        )
        let siteChanges = i.pumpHistory.filter { $0.type == .prime || $0.type == .nsSiteChange }
        let ketone = DkaStateStore.ketone()

        let input = DkaInput(
            now: i.now,
            bgHistory: bgHistory,
            insulinDelivered3h: delivery.units,
            iob: double(suggestion.iob),
            carbs2h: double(suggestion.cob),
            ketoneMmol: ketone?.mmol,
            ketoneDate: ketone?.date,
            lastSiteChange: siteChanges.map(\.timestamp).max(),
            sickDay: settings.dkaSickDay,
            onSglt2Inhibitor: settings.dkaSGLT2,
            onGlp1Ra: settings.dkaGLP1,
            pumpSuspendedMin3h: delivery.suspendedMinutes,
            tdd: i.tdd
        )
        let decision = DkaGuard(DkaConfig(settings: settings)).evaluate(input)
        DkaStateStore.saveDecision(decision, date: i.now)
        DkaNotifier.update(decision, notifyOnWatch: settings.dkaNotifyWatch, now: i.now)
        if decision.risk != .noRisk {
            let line = "DKA \(decision.risk.logName): \(decision.reasons.joined(separator: "; "))"
            debug(.openAPS, "Keto Protection (complex): \(line)")
            notes.append(line)
        }

        // 2) SMB pause (opt-in)
        if !decision.allowSmb {
            if (suggestion.units ?? 0) > 0 {
                notes.append("DKA guard: SMB paused (insulin seems ineffective)")
            }
            suggestion.units = 0
        }

        // 3) Semaglutide minimum basal
        let floorCfg = DkaFloorConfig(settings: settings)
        if floorCfg.enabled, settings.closedLoop {
            // rate == nil means "keep the running temp". A running zero/low temp must still be
            // raised to the floor, otherwise the loop could leave insulin at zero for hours.
            let proposed: Double? = suggestion.rate.map { double($0) } ??
                (i.runningTempMinutes > 0 ? i.runningTempRate : nil)
            if let proposed = proposed {
                let bg: Double? = suggestion.bg.map { double($0) } ?? bgHistory
                    .max(by: { $0.date < $1.date })
                    .flatMap { i.now.timeIntervalSince($0.date) <= 15 * 60 ? $0.mgdl : nil }
                let f = SemaglutideBasalFloor.apply(
                    proposedRate: proposed,
                    scheduledBasal: i.scheduledBasal,
                    bgMgdl: bg,
                    eventualBgMgdl: suggestion.eventualBG.map(Double.init),
                    cfg: floorCfg,
                    maxBasal: i.maxBasal
                )
                if f.applied {
                    suggestion.rate = Decimal(f.rate).rounded(to: 2, roundingMode: .up)
                    if (suggestion.duration ?? 0) <= 0 { suggestion.duration = 30 }
                }
                if let note = f.note {
                    notes.append(note)
                    debug(.openAPS, "Keto Protection (complex): \(note)")
                }
            }
        }

        if !notes.isEmpty {
            suggestion.reason += "\n\n" + notes.joined(separator: "\n")
        }
        return suggestion
    }

    /// Clears notification and stored evaluation, e.g. when the complex variant is switched off.
    static func reset() {
        DkaNotifier.update(.noRisk, notifyOnWatch: true)
        DkaStateStore.clearDecision()
    }

    // MARK: Insulin delivered

    /// Insulin delivered by the pump in [start, end]: boluses/SMBs (external insulin excluded) plus basal.
    /// Basal is integrated minute by minute: running temp basal rate, otherwise the scheduled basal,
    /// and 0 while the pump is suspended.
    static func insulinDelivered(
        events: [PumpHistoryEvent],
        from start: Date,
        to end: Date,
        scheduledBasal: Double
    ) -> (units: Double, suspendedMinutes: Int) {
        let boluses = events.filter {
            ($0.type == .bolus || $0.type == .smb) && $0.isExternal != true &&
                $0.timestamp >= start && $0.timestamp <= end
        }.reduce(0.0) { $0 + double($1.amount) }

        // Temp basals: "TempBasal" (rate) + "TempBasalDuration" (minutes) share the timestamp.
        let durations = Dictionary(
            events.filter { $0.type == .tempBasalDuration }.map { ($0.timestamp, $0.durationMin ?? $0.duration ?? 0) },
            uniquingKeysWith: { a, _ in a }
        )
        let temps: [(start: Date, end: Date, rate: Double)] = events
            .filter { $0.type == .tempBasal && $0.temp != .percent }
            .compactMap { e -> (start: Date, end: Date, rate: Double)? in
                guard let minutes = durations[e.timestamp] else { return nil }
                return (e.timestamp, e.timestamp.addingTimeInterval(Double(minutes) * 60), double(e.rate))
            }
            .sorted { $0.start < $1.start }

        let suspendEvents = events
            .filter { $0.type == .pumpSuspend || $0.type == .pumpResume }
            .sorted { $0.timestamp < $1.timestamp }

        var basal = 0.0
        var suspendedMinutes = 0
        let totalMinutes = max(0, Int(end.timeIntervalSince(start) / 60))
        for m in 0 ..< totalMinutes {
            let t = start.addingTimeInterval(Double(m) * 60 + 30) // middle of the minute
            if let last = suspendEvents.last(where: { $0.timestamp <= t }), last.type == .pumpSuspend {
                suspendedMinutes += 1
                continue
            }
            // The newest temp started before t that is still running wins (a new temp cancels the old one).
            if let temp = temps.last(where: { $0.start <= t }), t < temp.end {
                basal += temp.rate / 60
            } else {
                basal += scheduledBasal / 60
            }
        }
        return (boluses + basal, suspendedMinutes)
    }

    private static func double(_ d: Decimal?) -> Double {
        guard let d = d else { return 0 }
        return NSDecimalNumber(decimal: d).doubleValue
    }
}
