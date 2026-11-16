import SwiftUI

extension KetoProtection {
    final class StateModel: BaseStateModel<Provider> {
        /// Off / Simple / Complex. Only one variant can be active.
        @Published var mode: KetoProtectionMode = .off

        // Simple variant (iAPS safety TBR)
        @Published var variableKetoProtect: Bool = false
        @Published var ketoProtectBasalPercent: Decimal = 20
        @Published var ketoProtectAbsolut: Bool = false
        @Published var ketoProtectBasalAbsolut: Decimal = 0

        // Complex variant (AIMI DKA guard). Glucose values are shown in the user's units, stored in mg/dL.
        @Published var notifyWatch: Bool = true
        @Published var restrictSMB: Bool = false
        @Published var highBG: Decimal = 250
        @Published var veryHighBG: Decimal = 300
        @Published var sickDay: Bool = false
        @Published var sglt2: Bool = false
        @Published var glp1: Bool = false
        @Published var floorEnabled: Bool = false
        @Published var floorPercent: Decimal = 50
        @Published var floorMinBG: Decimal = 100

        // Ketone entry and status
        @Published var ketoneInput: Decimal = 0
        @Published var ketoneUnit: KetoneUnit = .mmol
        @Published var lastKetone: DkaStateStore.KetoneReading?
        @Published var ketoneError: String?
        @Published var status: (decision: DkaDecision, date: Date)?

        @Published var units: GlucoseUnits = .mmolL
        private var closedLoop = false

        override func subscribe() {
            units = settingsManager.settings.units
            closedLoop = settingsManager.settings.closedLoop
            let mmol = units == .mmolL

            subscribeSetting(\.ketoProtectionMode, on: $mode, initial: { mode = $0 }, didSet: { [weak self] newMode in
                if newMode != .complex { DkaProtection.reset() }
                self?.refreshStatus()
            })

            subscribeSetting(\.variableKetoProtect, on: $variableKetoProtect) { variableKetoProtect = $0 }
            subscribeSetting(\.ketoProtectAbsolut, on: $ketoProtectAbsolut) { ketoProtectAbsolut = $0 }
            subscribeSetting(\.ketoProtectBasalPercent, on: $ketoProtectBasalPercent) { ketoProtectBasalPercent = $0 }
            subscribeSetting(\.ketoProtectBasalAbsolut, on: $ketoProtectBasalAbsolut) { ketoProtectBasalAbsolut = $0 }

            subscribeSetting(\.dkaNotifyWatch, on: $notifyWatch) { notifyWatch = $0 }
            subscribeSetting(\.dkaRestrictSMB, on: $restrictSMB) { restrictSMB = $0 }
            subscribeSetting(\.dkaSickDay, on: $sickDay) { sickDay = $0 }
            subscribeSetting(\.dkaSGLT2, on: $sglt2) { sglt2 = $0 }
            subscribeSetting(\.dkaGLP1, on: $glp1) { glp1 = $0 }
            subscribeSetting(\.dkaFloorEnabled, on: $floorEnabled) { floorEnabled = $0 }

            subscribeSetting(\.dkaHighBG, on: $highBG.map { Self.toMgdl($0, mmol: mmol, range: 180 ... 350) }) {
                highBG = Self.fromMgdl($0, mmol: mmol)
            }
            subscribeSetting(\.dkaVeryHighBG, on: $veryHighBG.map { Self.toMgdl($0, mmol: mmol, range: 200 ... 400) }) {
                veryHighBG = Self.fromMgdl($0, mmol: mmol)
            }
            subscribeSetting(\.dkaFloorMinBG, on: $floorMinBG.map { Self.toMgdl($0, mmol: mmol, range: 70 ... 180) }) {
                floorMinBG = Self.fromMgdl($0, mmol: mmol)
            }
            subscribeSetting(\.dkaFloorPercent, on: $floorPercent.map { min(max($0.rounded(to: 0), 10), 100) }) {
                floorPercent = $0
            }

            ketoneUnit = DkaStateStore.ketoneUnit
            $ketoneUnit
                .removeDuplicates()
                .sink { DkaStateStore.ketoneUnit = $0 }
                .store(in: &lifetime)

            refreshStatus()
        }

        var glucoseUnitText: String { units.rawValue }

        /// The basal floor only acts in closed loop.
        var floorNeedsClosedLoop: Bool { !closedLoop }

        func refreshStatus() {
            lastKetone = DkaStateStore.ketone()
            status = DkaStateStore.lastDecision()
        }

        /// Saves the entered blood ketone value (BHB). Valid range 0...8 mmol/L.
        func saveKetone() {
            let value = NSDecimalNumber(decimal: ketoneInput).doubleValue
            let mmol = ketoneUnit.toMmol(value)
            guard mmol >= 0, mmol <= 8 else {
                ketoneError = NSLocalizedString(
                    "Please enter a value between 0 and 8 mmol/L (0 and 83 mg/dL).",
                    comment: "Ketone entry"
                )
                return
            }
            ketoneError = nil
            DkaStateStore.saveKetone(mmol: mmol)
            ketoneInput = 0
            refreshStatus()
        }

        func clearKetone() {
            DkaStateStore.clearKetone()
            ketoneError = nil
            refreshStatus()
        }

        func snooze() {
            DkaNotifier.snooze()
        }

        var ketoneIsValid: Bool {
            guard let k = lastKetone else { return false }
            return Date().timeIntervalSince(k.date) <= DkaStateStore.ketoneValidity
        }

        /// What the last ketone value means (same bands as the AIMI original).
        func ketoneAdvice(_ mmol: Double) -> String {
            switch mmol {
            case 3.0...:
                return NSLocalizedString(
                    "Very high (3.0 or more). Risk of DKA. Follow your DKA plan and seek medical help now. Call emergency services if you vomit, have abdominal pain, fast breathing or confusion.",
                    comment: "Ketone advice"
                )
            case 1.5...:
                return NSLocalizedString(
                    "High (1.5-2.9). Change the infusion set, inject a correction by pen/syringe according to your plan, hydrate and contact your diabetes team.",
                    comment: "Ketone advice"
                )
            case 0.6...:
                return NSLocalizedString(
                    "Mildly elevated (0.6-1.4). Drink water, check the infusion set, recheck in 1-2 hours.",
                    comment: "Ketone advice"
                )
            default:
                return NSLocalizedString(
                    "Normal (below 0.6). Keep monitoring if BG stays high or you feel unwell.",
                    comment: "Ketone advice"
                )
            }
        }

        /// Converts a displayed glucose value to mg/dL and clamps it to the allowed range.
        private static func toMgdl(_ value: Decimal, mmol: Bool, range: ClosedRange<Decimal>) -> Decimal {
            let mgdl = mmol ? value.asMgdL.rounded(to: 0) : value.rounded(to: 0)
            return min(max(mgdl, range.lowerBound), range.upperBound)
        }

        private static func fromMgdl(_ value: Decimal, mmol: Bool) -> Decimal {
            mmol ? value.asMmolL.rounded(to: 1) : value
        }
    }
}
