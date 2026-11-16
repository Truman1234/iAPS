import SwiftUI
import Swinject

extension KetoProtection {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state: StateModel

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            return formatter
        }

        private var intFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var glucoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.minimumFractionDigits = 1
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var ketoneFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = state.ketoneUnit == .mmol ? 1 : 0
            return formatter
        }

        private var timeFormatter: DateFormatter {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }

        var body: some View {
            Form {
                modeSection
                switch state.mode {
                case .off:
                    EmptyView()
                case .simple:
                    simpleSections
                case .complex:
                    complexSections
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .onAppear { state.refreshStatus() }
            .navigationBarTitle("Ketoacidosis Protection")
            .navigationBarTitleDisplayMode(.automatic)
        }

        // MARK: - Mode

        private var modeSection: some View {
            Section {
                Picker("Variant", selection: $state.mode) {
                    ForEach(KetoProtectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Ketoacidosis Protection")
            } footer: {
                switch state.mode {
                case .off:
                    Text("No ketoacidosis protection is active.")
                case .simple:
                    Text(
                        "Simple: replaces a zero temp with a small safety temp basal rate when IOB is negative (classic iAPS keto protection)."
                    )
                case .complex:
                    Text(
                        "Complex: DKA guard from OpenAPS AIMI. Detects suspected insulin delivery failure, prolonged highs and elevated ketones, alerts with recommended actions, can pause SMBs and can keep a minimum basal rate. Experimental: it does not replace ketone testing or medical advice."
                    )
                }
            }
        }

        // MARK: - Simple variant

        @ViewBuilder private var simpleSections: some View {
            Section {
                Toggle("Variable Keto Protection", isOn: $state.variableKetoProtect)
                if state.variableKetoProtect {
                    HStack {
                        Text("Safety TBR in %")
                        Spacer()
                        DecimalTextField("20", value: $state.ketoProtectBasalPercent, formatter: intFormatter)
                    }
                }
                Toggle("Enable Keto protection with pre-defined TBR", isOn: $state.ketoProtectAbsolut)
                if state.ketoProtectAbsolut {
                    HStack {
                        Text("Absolute Safety TBR ")
                        Spacer()
                        DecimalTextField("0", value: $state.ketoProtectBasalAbsolut, formatter: formatter)
                        Text("U/h").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Simple Keto Protection")
            } footer: {
                Text(
                    "Ketoacidosis protection will apply a small configurable Temp Basal Rate always or if certain conditions arise instead of a Zero temp!\nThe feature exists because in special cases a person could get ketoacidosis from 0% TBR. The idea is derived from sport. There could be problems when a basal rate of 0% ran for several hours. Muscles in particular could shut off.\nThis feature enables a small safety TBR to reduce the ketoacidosis risk. Without the Variable Protection that safety TBR is always applied. The idea behind the variable protection strategy is that the safety TBR is only applied if sum of basal-IOB and bolus-IOB falls negatively below the value of the current basal rate."
                ) + Text("\n\n") +
                    Text(
                        "Safety TBR in % is limited to 5-50 % of the profile basal rate, the absolute safety TBR to 0-2 U/h. Applies in closed loop only."
                    )
            }
        }

        // MARK: - Complex variant

        @ViewBuilder private var complexSections: some View {
            statusSection
            ketoneSection

            Section {
                Toggle("Notify at WATCH level", isOn: $state.notifyWatch)
                Toggle("Pause SMB if insulin seems ineffective", isOn: $state.restrictSMB)
            } header: {
                Text("Alerts")
            } footer: {
                Text(
                    "WATCH: early, low-priority notification (ketones 0.6-1.4 mmol/L, or 2 h above the high threshold). Pause SMB: if BG stays high despite delivered insulin, stop SMBs to avoid hidden insulin stacking. Change the infusion set and correct by pen/syringe."
                )
            }

            Section {
                HStack {
                    Text("High BG threshold")
                    Spacer()
                    DecimalTextField("250", value: $state.highBG, formatter: glucoseFormatter)
                    Text(state.glucoseUnitText).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Very high BG threshold")
                    Spacer()
                    DecimalTextField("300", value: $state.veryHighBG, formatter: glucoseFormatter)
                    Text(state.glucoseUnitText).foregroundStyle(.secondary)
                }
            } header: {
                Text("Thresholds")
            } footer: {
                Text(
                    "WATCH when BG stays above the high threshold for 2 hours (180-350 mg/dL, default 250 mg/dL = 13.9 mmol/L). WARNING after 2 hours above the very high threshold, CRITICAL after 4 hours (200-400 mg/dL, default 300 mg/dL = 16.7 mmol/L)."
                )
            }

            Section {
                Toggle("Sick day", isOn: $state.sickDay)
                Toggle("I take an SGLT2 inhibitor", isOn: $state.sglt2)
                Toggle("I take semaglutide / a GLP-1 agonist", isOn: $state.glp1)
            } header: {
                Text("Risk factors")
            } footer: {
                Text(
                    "Sick day: illness, fever, vomiting – asks for a ketone check; switch off when recovered. SGLT2 inhibitors: ketoacidosis can occur with normal glucose (euglycemic DKA). Semaglutide / GLP-1: reduced appetite and insulin need can lead to ketosis; nausea and vomiting can mask DKA symptoms."
                )
            }

            Section {
                Toggle("Semaglutide: minimum insulin (basal floor)", isOn: $state.floorEnabled)
                if state.floorEnabled {
                    HStack {
                        Text("Minimum basal")
                        Spacer()
                        DecimalTextField("50", value: $state.floorPercent, formatter: intFormatter)
                        Text("% of scheduled basal").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Floor inactive at or below")
                        Spacer()
                        DecimalTextField("100", value: $state.floorMinBG, formatter: glucoseFormatter)
                        Text(state.glucoseUnitText).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Minimum insulin")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Never let the loop deliver less than a percentage (10-100 %) of your scheduled basal rate, unless glucose is low. At or below the threshold (70-180 mg/dL), or when the predicted eventual BG is below it, the floor is not applied. Agree the values with your diabetes team."
                    )
                    if state.floorNeedsClosedLoop {
                        Text("The basal floor only acts in closed loop.").foregroundStyle(.orange)
                    }
                }
            }
        }

        private var statusSection: some View {
            Section {
                if let status = state.status {
                    HStack {
                        Text("Risk")
                        Spacer()
                        Text(status.decision.risk.displayName)
                            .foregroundStyle(color(status.decision.risk))
                            .bold()
                    }
                    ForEach(status.decision.reasons, id: \.self) { reason in
                        Text(reason).font(.footnote)
                    }
                    ForEach(status.decision.messages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(color(status.decision.risk))
                    }
                    HStack {
                        Text("Last check")
                        Spacer()
                        Text(timeFormatter.string(from: status.date)).foregroundStyle(.secondary)
                    }
                    if status.decision.risk == .watch || status.decision.risk == .warning {
                        Button("Snooze notifications for 1 h") { state.snooze() }
                    }
                } else {
                    Text("No evaluation yet. The status is updated with every loop cycle.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }
        }

        private var ketoneSection: some View {
            Section {
                if let ketone = state.lastKetone {
                    HStack {
                        Text("Last value")
                        Spacer()
                        Text(
                            String(format: "%.1f mmol/L (%.0f mg/dL)", ketone.mmol, KetoneUnit.mgdl.fromMmol(ketone.mmol))
                        )
                        .foregroundStyle(state.ketoneIsValid ? Color.primary : Color.secondary)
                        Text(timeFormatter.string(from: ketone.date)).foregroundStyle(.secondary)
                    }
                    if state.ketoneIsValid {
                        Text(state.ketoneAdvice(ketone.mmol)).font(.footnote)
                    } else {
                        Text("Older than 4 hours – no longer used.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Picker("Unit", selection: $state.ketoneUnit) {
                    ForEach(KetoneUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Blood ketones")
                    Spacer()
                    DecimalTextField(
                        state.ketoneUnit == .mmol ? "0.8" : "8",
                        value: $state.ketoneInput,
                        formatter: ketoneFormatter,
                        liveEditing: true
                    )
                    Text(state.ketoneUnit.displayName).foregroundStyle(.secondary)
                }
                if let error = state.ketoneError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                HStack {
                    Button("Save") { state.saveKetone() }
                        .buttonStyle(.borderless)
                    Spacer()
                    if state.lastKetone != nil {
                        Button("Clear", role: .destructive) { state.clearKetone() }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Blood ketones")
            } footer: {
                Text(
                    "Enter your blood ketone measurement (BHB). Choose the unit of your meter. A value is used for 4 hours after entry."
                )
            }
        }

        private func color(_ risk: DkaRisk) -> Color {
            switch risk {
            case .noRisk: return .green
            case .watch: return .yellow
            case .warning: return .orange
            case .critical: return .red
            }
        }
    }
}
