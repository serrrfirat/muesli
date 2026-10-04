import AppKit
import SwiftUI

struct HushSettingsView: View {
    @ObservedObject var model: AppModel
    let controller: MuesliController
    @State private var apiKey = ""
    @State private var recoveryPhrase = ""
    @State private var account = ""
    @State private var stakeAmount = "1000000000000000000000000"
    @State private var showsNativeSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                PageTitle("Settings")
                section("Appearance", icon: "circle.lefthalf.filled") {
                    Picker("Appearance", selection: Binding(get: { controller.appState.hushAppearance }, set: { controller.setHushAppearance($0) })) {
                        ForEach(HushAppearance.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 320)
                }
                section("Privacy and inference", icon: "lock.shield") {
                    TextField("NEAR AI or proxy endpoint", text: $model.settings.endpointURL)
                    SecureField("API key (not logged)", text: $apiKey)
                    TextField("TEE model", text: Binding(get: { model.settings.model }, set: { value in
                        model.settings.model = value
                        controller.updateConfig { $0.nearAIModel = value }
                    }))
                    Text("Trust: \(model.trust.state) — \(model.trust.detail)")
                        .font(MuesliTheme.caption()).textSelection(.enabled)
                    Button("Connect and verify") {
                        model.run { try await model.configure(endpoint: model.settings.endpointURL, key: apiKey) }
                    }.buttonStyle(.borderedProminent).tint(MuesliTheme.accent)
                    Text("Hush supports local models or verified NEAR AI. Other external inference providers are unavailable under Hush's trust policy. Telemetry is disabled.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
                section("Meeting notes", icon: "doc.text") {
                    Picker("Template", selection: Binding(get: { controller.hushTemplateSnapshot.id }, set: { controller.setHushTemplate(id: $0) })) {
                        ForEach(controller.availableMeetingTemplates()) { template in
                            Text(template.title).tag(template.id)
                        }
                        if !controller.config.customMeetingTemplates.contains(where: { $0.id == "hush-custom" }) {
                            Text("Custom").tag("hush-custom")
                        }
                    }
                    if controller.hushTemplateSnapshot.kind == .custom {
                        TextField("Custom template instructions", text: Binding(
                            get: { controller.config.customMeetingTemplates.first(where: { $0.id == controller.hushTemplateSnapshot.id })?.prompt ?? controller.hushTemplateSnapshot.prompt },
                            set: { controller.setHushCustomTemplate(prompt: $0) }), axis: .vertical)
                    }
                    Text("Uses the native summary template for the open meeting and as the default for new meetings.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                }
                section("Wallet and staking", icon: "creditcard") {
                    HStack {
                        TextField("NEAR account ID", text: $account)
                        Button("Sign in") { model.run { try await model.login(account) } }
                    }
                    HStack {
                        TextField("Stake amount (yoctoNEAR)", text: $stakeAmount)
                        Button(model.testMode ? "Simulate stake" : "Prepare stake transaction") {
                            model.run { try await model.stake(stakeAmount) }
                        }
                    }
                    Text("No spending or on-chain transaction is authorized by this screen.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    if let quota = model.quotaValue {
                        Text("Credits: $\(quota.creditsUsd, specifier: "%.2f") · Used: $\(quota.usedUsd, specifier: "%.2f")")
                        Text("Staked: \(quota.stakedYocto) yoctoNEAR").font(MuesliTheme.caption())
                    }
                }
                section("Encrypted meeting backups", icon: "externaldrive") {
                    HStack {
                        SecureField("Recovery phrase", text: $recoveryPhrase)
                        Button("Generate") {
                            do { recoveryPhrase = try Vault.generateRecoveryPhrase() }
                            catch { model.error = error.localizedDescription }
                        }
                    }
                    Text("Keep the recovery phrase separately. Losing it prevents backup recovery.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    Text("Includes Hush meetings and queued encrypted audio. Native dictation history, folders, templates, and app settings are not included.")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    HStack {
                        Button("Export encrypted backup", action: exportBackup)
                        Button("Restore backup", action: restoreBackup)
                    }
                }
                section("Native app", icon: "gearshape.2") {
                    Button(showsNativeSettings ? "Hide native preferences" : "Dictation and native preferences") { showsNativeSettings.toggle() }
                    if showsNativeSettings { SettingsView(appState: controller.appState, controller: controller) }
                }
                if model.busy { ProgressView(model.status) }
                if let error = model.error { Text(error).foregroundStyle(MuesliTheme.recording).textSelection(.enabled) }
            }
            .textFieldStyle(.roundedBorder)
            .buttonStyle(.bordered)
            .padding(MuesliTheme.spacing24)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
        }
        .background(MuesliTheme.backgroundBase)
        .foregroundStyle(MuesliTheme.textPrimary)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Label(title, systemImage: icon).font(MuesliTheme.headline())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hush.backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.run { try model.backup(to: url, phrase: recoveryPhrase) }
    }
    private func restoreBackup() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.run { try model.restore(from: url, phrase: recoveryPhrase) }
    }
}

struct HushUpcomingView: View {
    @ObservedObject var calendar: CalendarFeed
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                Label("Coming up", systemImage: "calendar").font(MuesliTheme.headline())
                Spacer()
                Button("New note") {
                    model.run {
                        try model.save(Meeting(title: "Untitled note"))
                        model.screen = .meeting
                    }
                }
                .disabled(model.busy || model.recording)
                Button { calendar.turnPage(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(calendar.page == 0).help("Previous days")
                Button { calendar.turnPage(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next days")
            }
            switch calendar.access {
            case .disabledForE2E:
                Text("Calendar is disabled for verification runs.").font(MuesliTheme.caption())
            case .notConnected:
                Button("Connect calendar") { Task { await calendar.connect() } }
            case .denied:
                Button("Open Calendar privacy settings") { CalendarFeed.openPrivacySettings() }
            case .connected:
                ForEach(calendar.days) { day in
                    Text(day.date.formatted(date: .abbreviated, time: .omitted))
                        .font(MuesliTheme.captionMedium()).foregroundStyle(MuesliTheme.textSecondary)
                    ForEach(day.events) { event in
                        HStack {
                            Circle().fill(event.color).frame(width: 6, height: 6)
                            Text(event.title).lineLimit(1)
                            Spacer()
                            Text(event.start.formatted(date: .omitted, time: .shortened)).font(MuesliTheme.caption())
                            if event.isStartable(at: Date()) {
                                Button("Start now") { model.toggleRecording(title: event.title) }
                                    .disabled(model.recording || model.busy)
                            }
                        }
                    }
                }
                if calendar.days.allSatisfy({ $0.events.isEmpty }) {
                    Text("No upcoming events on these days.").font(MuesliTheme.caption())
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.top, MuesliTheme.spacing12)
    }
}
