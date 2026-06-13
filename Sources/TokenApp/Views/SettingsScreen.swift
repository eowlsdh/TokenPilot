import SwiftUI
import TokenCore

struct SettingsScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 10) {
                dataSources
                notificationSettings
                telegramSettings
                discordSettings
                languageSettings
                setupGuide
                privacySettings
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            model.refreshStoredCredentialPresence()
        }
    }

    private var dataSources: some View {
        VStack(spacing: 10) {
            SettingsCard(title: model.t("1. Data Sources"), icon: "externaldrive") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        providerToggle(.claude)
                        providerToggle(.codex)
                        providerToggle(.gemini)
                    }
                    Text(model.t("Toggle providers shown on Overview. Disabled providers are hidden and not refreshed."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    HStack(spacing: 8) {
                        Button(model.t("Auto-detect & apply sources")) { Task { await model.checkAllConnections() } }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Text(model.t("Scans only local default paths and user-selected files."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(model.t("Menu bar status"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TokenPilotDesign.textSecondary)
                            Spacer(minLength: 0)
                            Picker(model.t("Menu bar status"), selection: menuBarTargetBinding) {
                                Text(model.t("Highest risk")).tag(Optional<Provider>.none)
                                ForEach(Provider.allCases) { provider in
                                    Text(model.t(provider.displayName))
                                        .tag(Optional(provider))
                                        .disabled(!model.isProviderEnabled(provider))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 170)
                        }
                        Text(model.t("Show selected provider in the menu bar. Disabled providers are skipped."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text("\(model.t("Current menu bar")): \(model.menuBarTitle)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            SettingsCard(title: model.t("Provider Diagnostics"), icon: "stethoscope") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.t("Before diagnostics, TokenPilot checks local usage metadata and selected files only. It excludes prompts, responses, secrets, credentials, browser cookies, raw events, and raw paths from summaries and exports."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)

                    ForEach(model.providerDiagnostics) { diagnostic in
                        providerDiagnosticRow(diagnostic)
                    }

                    Button(model.t("Check all providers")) { Task { await model.checkAllConnections() } }
                        .buttonStyle(.borderedProminent)
                        .tint(TokenPilotDesign.calm)
                }
            }

            ProviderSetupCard(provider: .claude, title: "Claude Code", status: model.sourceStatusText(.claude), statusColor: model.sourceStatusColor(.claude), detail: model.sourceDetailText(.claude)) {
                Text(model.t("Status file path"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    TextField(model.t("Claude status path"), text: $model.settings.claudeStatusFilePath)
                        .textFieldStyle(.roundedBorder)
                    Button(model.t("Choose…")) { model.chooseClaudeStatusFile() }
                }
                Text(model.t("defaultClaudePath"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.claude) } }
                    .buttonStyle(.bordered)
            }

            ProviderSetupCard(provider: .gemini, title: "Gemini CLI", status: model.sourceStatusText(.gemini), statusColor: model.sourceStatusColor(.gemini), detail: model.sourceDetailText(.gemini)) {
                Text(model.t("Telemetry source"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    TextField(model.t("defaultGeminiPath1"), text: $model.settings.geminiTelemetryLogPath)
                        .textFieldStyle(.roundedBorder)
                    Button(model.t("Choose…")) { model.chooseGeminiTelemetrySource() }
                }
                Text(model.t("You can select telemetry.log or a .gemini session folder."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("Default suggestions:"))
                    Text(model.t("defaultGeminiPath1"))
                    Text(model.t("defaultGeminiPath2"))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    ForEach([1000, 1500, 2000], id: \.self) { cap in
                        Button("\(cap)") { model.settings.geminiDailyRequestCap = cap }
                            .buttonStyle(.bordered)
                            .tint(model.settings.geminiDailyRequestCap == cap ? TokenPilotDesign.calm : .secondary)
                    }
                    Stepper(String(format: model.t("Custom: %d"), model.settings.geminiDailyRequestCap), value: $model.settings.geminiDailyRequestCap, in: 1...20_000, step: 100)
                }
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.gemini) } }
                    .buttonStyle(.bordered)
            }

            ProviderSetupCard(provider: .codex, title: "Codex", status: model.sourceStatusText(.codex), statusColor: model.sourceStatusColor(.codex), detail: model.sourceDetailText(.codex)) {
                Text(model.t("Limit Hints Connector"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Codex Limit Hints Connector"), isOn: $model.settings.codexManual.webConnectorEnabled)
                Text(model.t("Asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot does not read, store, display, or export Codex access tokens."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Codex app-server limit hints are unofficial and may break if the Codex CLI changes. Disable to fall back to local activity/manual values."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.warning)
                Divider()
                    .opacity(0.35)
                Text(model.t("Manual / personal calibration fallback"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Codex Web Snapshot"), isOn: $model.settings.codexManual.webSnapshotEnabled)
                Text(model.t("Enter values you see on Codex web. TokenPilot stores only these numbers, not cookies or login tokens."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Stepper(String(format: model.t("Web today tokens: %d"), model.settings.codexManual.webTodayTokens), value: $model.settings.codexManual.webTodayTokens, in: 0...100_000_000, step: 1_000)
                HStack {
                    Button(model.t("Mark Web Snapshot Now")) { model.markCodexWebSnapshotNow() }
                    if let capturedAt = model.settings.codexManual.webSnapshotCapturedAt {
                        Text("\(model.t("Captured")): \(TokenPilotFormatters.clock(capturedAt))")
                            .font(.caption)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                    }
                }
                Divider()
                    .opacity(0.25)
                TextField(model.t("Plan label"), text: $model.settings.codexManual.planLabel)
                    .textFieldStyle(.roundedBorder)
                Stepper(String(format: model.t("5h usage: %d%%"), model.settings.codexManual.fiveHourUsagePercentage), value: $model.settings.codexManual.fiveHourUsagePercentage, in: 0...100)
                Stepper(String(format: model.t("Weekly usage: %d%%"), model.settings.codexManual.weeklyUsagePercentage), value: $model.settings.codexManual.weeklyUsagePercentage, in: 0...100)
                TextField(model.t("Reset time"), text: $model.settings.codexManual.resetTimeText)
                    .textFieldStyle(.roundedBorder)
                TextField(model.t("Notes"), text: $model.settings.codexManual.notes)
                    .textFieldStyle(.roundedBorder)
                Text(model.t("Pasted /status output"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                TextEditor(text: $model.settings.codexManual.pastedStatusOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Button(model.t("Paste Status")) { model.pasteCodexStatusFromClipboard() }
                    Button(model.t("Parse Status")) { model.parseCodexStatus() }
                    Text("\(model.t("Confidence")): \(model.settings.codexManual.confidence.localizedLabel(language: model.settings.localization.language))")
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                Text(model.t("Parsed status is marked medium or low confidence unless clearly reliable."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.codex) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var notificationSettings: some View {
        SettingsCard(title: model.t("2. Notifications"), icon: "bell") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(model.t("Global notifications"), isOn: $model.settings.globalNotificationsEnabled)
                Toggle(model.t("macOS notifications"), isOn: $model.settings.macOSNotificationsEnabled)
                Toggle(model.t("Telegram notifications"), isOn: $model.settings.telegramNotificationsEnabled)
                Toggle(model.t("Discord notifications"), isOn: $model.settings.discordNotificationsEnabled)
                HStack {
                    Button(model.t("Request Notification Permission")) { Task { await model.requestNotificationPermission() } }
                    Button(model.t("Send Test Notification")) { Task { await model.sendTestNotification() } }
                    Spacer()
                    Text("\(model.t("Status")): \(model.settings.notificationPermissionStatus.localizedLabel(language: model.settings.localization.language))")
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                if model.settings.notificationPermissionStatus == .denied {
                    Text(model.t("Permission denied. Enable notifications in macOS Settings > Notifications."))
                        .font(.caption)
                        .foregroundStyle(TokenPilotDesign.warning)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Provider/window alert rules"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                    ForEach($model.settings.alertRules) { $rule in
                        AlertRuleRow(rule: $rule)
                    }
                }
            }
        }
    }

    private var telegramSettings: some View {
        SettingsCard(title: model.t("3. Telegram"), icon: "paperplane") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Toggle(model.t("Enable Telegram Alerts"), isOn: $model.settings.telegram.isEnabled)
                    Spacer()
                    StatusBadge(
                        label: model.settings.telegram.isEnabled ? model.t("ON") : model.t("OFF"),
                        color: model.settings.telegram.isEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
                    )
                    StatusBadge(
                        label: model.hasSavedTelegramToken ? model.t("Token saved") : model.t("No token"),
                        color: model.hasSavedTelegramToken ? TokenPilotDesign.calm : TokenPilotDesign.warning
                    )
                }

                SecureField(model.hasSavedTelegramToken ? model.t("Saved token hidden") : model.t("Bot Token"), text: $model.telegramTokenInput)
                    .textFieldStyle(.roundedBorder)
                TextField(model.t("Chat ID"), text: $model.settings.telegram.chatID)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(model.hasSavedTelegramToken ? model.t("Replace Token") : model.t("Save Token")) { model.saveTelegramToken() }
                    Button(model.t("Delete Token"), role: .destructive) { model.deleteTelegramToken() }
                        .disabled(!model.hasSavedTelegramToken)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(model.t("Find Chat ID")) { Task { await model.findTelegramChatID() } }
                    Button(model.t("Send Test Message")) { Task { await model.sendTelegramTest() } }
                    Spacer()
                    StatusBadge(
                        label: model.settings.telegram.chatID.isEmpty ? model.t("No chat ID") : model.t("Chat ID set"),
                        color: model.settings.telegram.chatID.isEmpty ? TokenPilotDesign.warning : TokenPilotDesign.calm
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.t("Connection status")): \(model.localizedStatus(model.settings.telegram.connectionStatus))")
                    Text("\(model.t("Last test sent at")): \(TokenPilotFormatters.clock(model.settings.telegram.lastTestSentAt))")
                }
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)

                Text(model.t("Telegram OFF by default. Enable only after saving TokenPilot's own bot token."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Telegram alerts are optional. TokenPilot stores only its own bot token Keychain item and sends only alert messages when enabled."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var discordSettings: some View {
        SettingsCard(title: model.t("4. Discord"), icon: "bubble.left.and.bubble.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Toggle(model.t("Enable Discord Alerts"), isOn: $model.settings.discord.isEnabled)
                    Spacer()
                    StatusBadge(
                        label: model.settings.discord.isEnabled ? model.t("ON") : model.t("OFF"),
                        color: model.settings.discord.isEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
                    )
                    StatusBadge(
                        label: model.hasSavedDiscordWebhook ? model.t("Webhook saved") : model.t("No webhook"),
                        color: model.hasSavedDiscordWebhook ? TokenPilotDesign.calm : TokenPilotDesign.warning
                    )
                }

                SecureField(model.hasSavedDiscordWebhook ? model.t("Saved webhook hidden") : model.t("Discord Webhook URL"), text: $model.discordWebhookInput)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(model.hasSavedDiscordWebhook ? model.t("Replace Webhook") : model.t("Save Webhook")) { model.saveDiscordWebhook() }
                    Button(model.t("Delete Webhook"), role: .destructive) { model.deleteDiscordWebhook() }
                        .disabled(!model.hasSavedDiscordWebhook)
                    Button(model.t("Send Test Message")) { Task { await model.sendDiscordTest() } }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.t("Connection status")): \(model.localizedStatus(model.settings.discord.connectionStatus))")
                    Text("\(model.t("Last test sent at")): \(TokenPilotFormatters.clock(model.settings.discord.lastTestSentAt))")
                }
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)

                Text(model.t("Discord OFF by default. Paste only a Discord channel webhook created for TokenPilot."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Webhook URL is stored in TokenPilot's own Keychain item and is never shown in plain text after saving."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var languageSettings: some View {
        SettingsCard(title: model.t("5. Language"), icon: "globe") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(model.t("Language"), selection: $model.settings.localization.language) {
                    ForEach(TokenPilotLanguage.allCases) { language in
                        // Display names intentionally NOT localized — each language
                        // shows in its own script (한국어, English, 简体中文, 日本語)
                        // which is the standard UX pattern for language selectors.
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Text(model.t("Language changes may require restarting TokenPilot."))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
            }
        }
    }

    private var setupGuide: some View {
        SettingsCard(title: model.t("6. Setup Guide"), icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                GuideCard(
                    title: model.t("Connect Claude Code"),
                    status: model.sourceStatusText(.claude),
                    statusColor: model.sourceStatusColor(.claude),
                    detail: model.sourceDetailText(.claude),
                    explanation: model.t("TokenPilot reads the Claude statusline snapshot below."),
                    primaryAction: model.t("Check Connection"),
                    copyText: claudeStatuslineScript,
                    onPrimary: { Task { await model.checkConnection(.claude) } },
                    onCopy: { model.copyToClipboard(claudeStatuslineScript) }
                )
                GuideCard(
                    title: model.t("Connect Gemini CLI"),
                    status: model.sourceStatusText(.gemini),
                    statusColor: model.sourceStatusColor(.gemini),
                    detail: model.sourceDetailText(.gemini),
                    explanation: model.t("Enable local telemetry and choose telemetry.log."),
                    primaryAction: model.t("Check Connection"),
                    copyText: geminiSettingsSnippet,
                    onPrimary: { Task { await model.checkConnection(.gemini) } },
                    onCopy: { model.copyToClipboard(geminiSettingsSnippet) }
                )
                GuideCard(
                    title: model.t("Add Codex status"),
                    status: model.sourceStatusText(.codex),
                    statusColor: model.sourceStatusColor(.codex),
                    detail: model.sourceDetailText(.codex),
                    explanation: model.t("Run /status in Codex CLI and paste the result."),
                    primaryAction: model.t("Paste Status"),
                    copyText: nil,
                    onPrimary: { model.pasteCodexStatusFromClipboard() },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Enable Notifications"),
                    status: model.settings.notificationPermissionStatus.localizedLabel(language: model.settings.localization.language),
                    explanation: model.t("Request macOS permission, then send a test alert."),
                    primaryAction: model.t("Request Permission"),
                    copyText: nil,
                    onPrimary: { Task { await model.requestNotificationPermission() } },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Optional Telegram Alerts"),
                    status: model.localizedStatus(model.settings.telegram.connectionStatus),
                    explanation: model.t("Create a bot with BotFather, send it a message, paste token and chat ID, then test."),
                    primaryAction: model.t("Send Test Message"),
                    copyText: nil,
                    onPrimary: { Task { await model.sendTelegramTest() } },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Optional Discord Alerts"),
                    status: model.localizedStatus(model.settings.discord.connectionStatus),
                    explanation: model.t("Create a Discord channel webhook, paste it once, then send a test message."),
                    primaryAction: model.t("Send Test Message"),
                    copyText: nil,
                    onPrimary: { Task { await model.sendDiscordTest() } },
                    onCopy: nil
                )
            }
        }
    }

    private var privacySettings: some View {
        SettingsCard(title: model.t("7. Privacy"), icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.t("Preview sample data when no source is connected"), isOn: $model.settings.showMockDataWhenDisconnected)
                privacyLine(model.t("Sample preview is optional and off by default so release builds never look connected before setup."))
                privacyLine(model.t("Reads local usage metadata and selected files only."))
                privacyLine(model.t("Does not read browser cookies or other Keychain items."))
                privacyLine(model.t("Codex Limit Hints Connector is opt-in and asks the local Codex CLI app-server for account/rateLimits/read; TokenPilot never reads, displays, or stores Codex access tokens."))
                privacyLine(model.t("Telegram and Discord send only alert messages when enabled."))
            }
        }
    }

    private var menuBarTargetBinding: Binding<Provider?> {
        Binding(
            get: { model.settings.menuBarDisplayTarget },
            set: { model.setMenuBarDisplayTarget($0) }
        )
    }

    private func providerDiagnosticRow(_ diagnostic: ProviderConnectionDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t(diagnostic.provider.displayName))
                        .font(.caption.weight(.bold))
                    Text("\(model.t("Last checked")): \(model.diagnosticLastCheckedText(diagnostic))")
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.diagnosticStatusText(diagnostic))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(model.diagnosticStatusColor(diagnostic))
                    Text("\(model.t("Confidence")): \(diagnostic.confidence.localizedLabel(language: model.settings.localization.language))")
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
            }

            Text(model.diagnosticNextActionText(diagnostic))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TokenPilotDesign.textPrimary)
            Text(model.diagnosticDetailText(diagnostic))
                .font(.caption2)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)
        }
        .padding(9)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func providerToggle(_ provider: Provider) -> some View {
        Toggle(
            model.t(provider.displayName),
            isOn: Binding(
                get: { model.isProviderEnabled(provider) },
                set: { model.setProvider(provider, isEnabled: $0) }
            )
        )
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .tint(model.isProviderEnabled(provider) ? TokenPilotDesign.accent(for: provider) : .secondary)
    }

    private func sourceBlock<Content: View>(title: String, icon: String, provider: Provider, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.sourceStatusText(provider))
                    .font(.caption)
                    .foregroundStyle(model.sourceStatusColor(provider))
            }
            content()
            Text(model.sourceDetailText(provider))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func privacyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TokenPilotDesign.calm)
            Text(text)
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
        }
    }

    private var claudeStatuslineScript: String {
        """
        #!/usr/bin/env bash
        mkdir -p "$HOME/Library/Application Support/TokenPilot"
        cat > "$HOME/Library/Application Support/TokenPilot/claude-statusline.json" <<'JSON'
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 0, "resets_at": null },
            "seven_day": { "used_percentage": 0, "resets_at": null }
          },
          "context_window": {
            "current_usage": {
              "input_tokens": 0,
              "output_tokens": 0,
              "cache_creation_input_tokens": 0,
              "cache_read_input_tokens": 0
            }
          },
          "cost": { "total_cost_usd": 0 },
          "model": { "display_name": "Claude Code" }
        }
        JSON
        """
    }

    private var geminiSettingsSnippet: String {
        """
        {
          "telemetry": {
            "enabled": true,
            "target": "local",
            "log_file": "~/.gemini/telemetry.log"
          }
        }
        """
    }
}

struct AlertRuleRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    @Binding var rule: AlertRule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(localized(rule.provider.displayName, language: language)) · \(rule.window.localizedLabel(language: language))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            HStack(spacing: 4) {
                AlertTogglePill(label: "macOS", isOn: $rule.macOSEnabled)
                AlertTogglePill(label: "TG", isOn: $rule.telegramEnabled)
                AlertTogglePill(label: "DC", isOn: $rule.discordEnabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                AlertTogglePill(label: localized("Reset", language: language), isOn: $rule.resetEnabled)
                AlertTogglePill(label: "50%", isOn: $rule.fiftyEnabled)
                AlertTogglePill(label: "80%", isOn: $rule.eightyEnabled)
                AlertTogglePill(label: "100%", isOn: $rule.hundredEnabled)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct AlertTogglePill: View {
    @Environment(\.tokenPilotLanguage) private var language
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text("\(label) \(isOn ? localized("ON", language: language) : localized("OFF", language: language))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isOn ? TokenPilotDesign.calm.opacity(0.16) : TokenPilotDesign.cardMuted)
                .overlay(
                    Capsule().stroke(isOn ? TokenPilotDesign.calm.opacity(0.22) : TokenPilotDesign.border, lineWidth: 1)
                )
                .foregroundStyle(isOn ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GuideCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    let title: String
    let status: String
    var statusColor: Color = TokenPilotDesign.textSecondary
    var detail: String? = nil
    let explanation: String
    let primaryAction: String
    let copyText: String?
    let onPrimary: () -> Void
    let onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                Spacer()
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(TokenPilotDesign.textSecondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack {
                Button(primaryAction, action: onPrimary)
                    .buttonStyle(.bordered)
                if copyText != nil, let onCopy {
                    Button(localized("Copy", language: language), action: onCopy)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                content
            }
        }
    }
}
