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
            SettingsCard(title: model.t("1. Source Health"), icon: "externaldrive.badge.checkmark") {
                VStack(alignment: .leading, spacing: 12) {
                    sourceHealthSummary

                    HStack(spacing: 8) {
                        Button(model.t("Auto-detect sources")) { Task { await model.checkAllConnections() } }
                            .buttonStyle(.borderedProminent)
                            .tint(TokenPilotDesign.calm)
                        Button(model.t("Refresh provider health")) { Task { await model.refresh() } }
                            .buttonStyle(.bordered)
                    }

                    Text(model.t("Auto-detect checks local default metadata and user-selected files only. Diagnostics hide raw paths, raw events, prompts, responses, and secrets."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.capacityRuntimeRecoveryRequired {
                        runtimeRecoveryBanner
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            providerToggle(.claude)
                            providerToggle(.codex)
                            providerToggle(.gemini)
                            providerToggle(.deepseek)
                        }
                        Text(model.t("Choose providers shown on Overview. Turning one off skips refresh without deleting stored history."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
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
                        Text(model.t("Menu bar uses the core capacity assessment. Disabled providers are skipped."))
                            .font(.caption2)
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                        Text("\(model.t("Current menu bar")): \(model.menuBarTitle)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TokenPilotDesign.textSecondary)
                            .lineLimit(1)
                            .accessibilityLabel(model.menuBarAccessibilityLabel)
                    }
                }
            }

            SettingsCard(title: model.t("Provider Diagnostics"), icon: "stethoscope") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.t("Diagnostics summarize source health without showing raw local paths, raw events, prompts, responses, cookies, credentials, or tokens."))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.capacityRefreshErrors.isEmpty {
                        capacityRefreshNotes
                    }

                    ForEach(model.providerDiagnostics) { diagnostic in
                        providerDiagnosticRow(diagnostic)
                    }

                    Button(model.t("Check all providers")) { Task { await model.checkAllConnections() } }
                        .buttonStyle(.borderedProminent)
                        .tint(TokenPilotDesign.calm)
                }
            }

            ProviderSetupCard(provider: .claude, title: "Claude Code", status: model.sourceStatusText(.claude), statusColor: model.sourceStatusColor(.claude), detail: model.sourceDetailText(.claude)) {
                Text(model.t("Claude status source"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    sourceSelectionBadge(isSelected: !model.settings.claudeStatusFilePath.isEmpty)
                    Spacer(minLength: 0)
                    Button(model.t("Choose…")) { model.chooseClaudeStatusFile() }
                }
                Text(model.t("Raw local paths stay hidden. Choose again to replace the saved source bookmark."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Button(model.t("Check Connection")) { Task { await model.checkConnection(.claude) } }
                    .buttonStyle(.bordered)
            }

            ProviderSetupCard(provider: .gemini, title: "Antigravity CLI", status: model.sourceStatusText(.gemini), statusColor: model.sourceStatusColor(.gemini), detail: model.sourceDetailText(.gemini)) {
                Text(model.t("Antigravity telemetry source"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    sourceSelectionBadge(isSelected: !model.settings.geminiTelemetryLogPath.isEmpty)
                    Spacer(minLength: 0)
                    Button(model.t("Choose…")) { model.chooseGeminiTelemetrySource() }
                }
                Text(model.t("Select statusline JSON, legacy telemetry, or a session folder. Raw local paths stay hidden after selection."))
                    .font(.caption2)
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

            ProviderSetupCard(provider: .deepseek, title: "DeepSeek", status: model.sourceStatusText(.deepseek), statusColor: model.sourceStatusColor(.deepseek), detail: model.sourceDetailText(.deepseek)) {
                HStack {
                    StatusBadge(
                        label: model.hasSavedDeepSeekAPIKey ? model.t("API key saved") : model.t("API key required"),
                        color: model.hasSavedDeepSeekAPIKey ? TokenPilotDesign.calm : TokenPilotDesign.warning
                    )
                    Spacer(minLength: 0)
                    Text(model.t("Official balance API"))
                        .font(.caption2)
                        .foregroundStyle(TokenPilotDesign.textSecondary)
                }
                SecureField(model.hasSavedDeepSeekAPIKey ? model.t("Saved API key hidden") : model.t("DeepSeek API Key"), text: $model.deepSeekAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                Text(model.t("TokenPilot stores only its own DeepSeek API key Keychain item and calls the official /user/balance endpoint."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                HStack {
                    Button(model.t("Save API Key")) { model.saveDeepSeekAPIKey() }
                        .buttonStyle(.borderedProminent)
                        .tint(TokenPilotDesign.calm)
                    Button(model.t("Delete API Key"), role: .destructive) { model.deleteDeepSeekAPIKey() }
                        .buttonStyle(.bordered)
                        .disabled(!model.hasSavedDeepSeekAPIKey)
                    Button(model.t("Check Connection")) { Task { await model.checkConnection(.deepseek) } }
                        .buttonStyle(.bordered)
                }
                Divider()
                    .opacity(0.25)
                Text(model.t("Manual DeepSeek balance fallback"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Manual DeepSeek Balance"), isOn: $model.settings.deepSeekBalance.manualFallbackEnabled)
                HStack {
                    TextField(model.t("Balance"), text: $model.settings.deepSeekBalance.manualBalanceText)
                        .textFieldStyle(.roundedBorder)
                    TextField(model.t("Currency"), text: $model.settings.deepSeekBalance.manualCurrency)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button(model.t("Mark Balance Now")) {
                        model.settings.deepSeekBalance.manualCapturedAt = Date()
                    }
                }
                Stepper(
                    String(format: model.t("Low balance alert: %.2f"), NSDecimalNumber(decimal: model.settings.deepSeekBalance.lowBalanceThreshold).doubleValue),
                    value: Binding(
                        get: { NSDecimalNumber(decimal: model.settings.deepSeekBalance.lowBalanceThreshold).doubleValue },
                        set: { model.settings.deepSeekBalance.lowBalanceThreshold = Decimal(max($0, 0)) }
                    ),
                    in: 0...10_000,
                    step: 1
                )
            }

            ProviderSetupCard(provider: .codex, title: "Codex", status: model.sourceStatusText(.codex), statusColor: model.sourceStatusColor(.codex), detail: model.sourceDetailText(.codex)) {
                Text(model.t("Experimental Codex limit hints"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use experimental Codex limit hints"), isOn: $model.settings.codexManual.webConnectorEnabled)
                Text(model.t("Experimental connector asks the local Codex CLI app-server for account/rateLimits/read. TokenPilot never reads, stores, displays, or exports Codex access tokens."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Codex limit hints are experimental and may break if the Codex CLI changes. They are not guaranteed official quota."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.warning)
                Divider()
                    .opacity(0.35)
                Text(model.t("Manual Codex limit snapshot"))
                    .font(.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Toggle(model.t("Use Manual Limit Snapshot"), isOn: $model.settings.codexManual.webSnapshotEnabled)
                Text(model.t("Enter manual values you observed. TokenPilot stores only numbers and notes, not cookies, login tokens, or raw account pages."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                Stepper(String(format: model.t("Manual today tokens: %d"), model.settings.codexManual.webTodayTokens), value: $model.settings.codexManual.webTodayTokens, in: 0...100_000_000, step: 1_000)
                HStack {
                    Button(model.t("Mark Manual Snapshot Now")) { model.markCodexWebSnapshotNow() }
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
                Text(model.t("Pasted /status output (cleared after parse)"))
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
                Text(model.t("Parsed status remains manual or estimated unless the source is provider-reported and fresh."))
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
                notificationEffectiveSummary

                Toggle(model.t("Global notifications"), isOn: $model.settings.globalNotificationsEnabled)
                Toggle(model.t("macOS notifications"), isOn: $model.settings.macOSNotificationsEnabled)
                    .disabled(!model.settings.globalNotificationsEnabled)
                Toggle(model.t("Telegram notifications"), isOn: $model.settings.telegramNotificationsEnabled)
                    .disabled(!model.settings.globalNotificationsEnabled)
                Toggle(model.t("Discord notifications"), isOn: $model.settings.discordNotificationsEnabled)
                    .disabled(!model.settings.globalNotificationsEnabled)

                Text(model.t("Global OFF disables every channel. Channel OFF disables matching alert-rule delivery controls."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(model.t("Request Notification Permission")) { Task { await model.requestNotificationPermission() } }
                        .disabled(!model.settings.globalNotificationsEnabled)
                    Button(model.t("Send Test Notification")) { Task { await model.sendTestNotification() } }
                        .disabled(!hasEffectiveNotificationChannel)
                    Spacer()
                    Text("\(model.t("Permission")): \(model.settings.notificationPermissionStatus.localizedLabel(language: model.settings.localization.language))")
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
                        AlertRuleRow(
                            rule: $rule,
                            globalEnabled: model.settings.globalNotificationsEnabled,
                            macOSChannelEnabled: model.settings.macOSNotificationsEnabled,
                            telegramChannelEnabled: telegramRouteAvailable,
                            discordChannelEnabled: discordRouteAvailable
                        )
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
                    StatusBadge(
                        label: telegramEffectiveNotificationsEnabled ? model.t("Effective ON") : model.t("Effective OFF"),
                        color: telegramEffectiveNotificationsEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
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
                        .disabled(!telegramEffectiveNotificationsEnabled)
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
                Text(model.t("Effective Telegram delivery requires Global notifications, Telegram notifications, Telegram alerts, a saved bot token, and a chat ID."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                    StatusBadge(
                        label: discordEffectiveNotificationsEnabled ? model.t("Effective ON") : model.t("Effective OFF"),
                        color: discordEffectiveNotificationsEnabled ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
                    )
                }

                SecureField(model.hasSavedDiscordWebhook ? model.t("Saved webhook hidden") : model.t("Discord Webhook URL"), text: $model.discordWebhookInput)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(model.hasSavedDiscordWebhook ? model.t("Replace Webhook") : model.t("Save Webhook")) { model.saveDiscordWebhook() }
                    Button(model.t("Delete Webhook"), role: .destructive) { model.deleteDiscordWebhook() }
                        .disabled(!model.hasSavedDiscordWebhook)
                    Button(model.t("Send Test Message")) { Task { await model.sendDiscordTest() } }
                        .disabled(!discordEffectiveNotificationsEnabled)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.t("Connection status")): \(model.localizedStatus(model.settings.discord.connectionStatus))")
                    Text("\(model.t("Last test sent at")): \(TokenPilotFormatters.clock(model.settings.discord.lastTestSentAt))")
                }
                .font(.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                Text(model.t("Effective Discord delivery requires Global notifications, Discord notifications, Discord alerts, and a saved webhook."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                    explanation: model.t("Scans only local default paths and user-selected files."),
                    primaryAction: model.t("Choose…"),
                    copyText: nil,
                    onPrimary: { model.chooseClaudeStatusFile() },
                    onCopy: nil
                )
                GuideCard(
                    title: model.t("Connect Antigravity CLI"),
                    status: model.sourceStatusText(.gemini),
                    statusColor: model.sourceStatusColor(.gemini),
                    detail: model.sourceDetailText(.gemini),
                    explanation: model.t("Install the local statusLine bridge, then run Check Connection."),
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
                privacyLine(model.t("Codex experimental connector is opt-in, local-only, and never reads, displays, stores, or exports Codex access tokens."))
                privacyLine(model.t("Telegram and Discord send only alert messages when enabled."))
            }
        }
    }

    private var sourceHealthSummary: some View {
        HStack(spacing: 6) {
            StatusBadge(
                label: "\(readyProviderCount)/\(Provider.allCases.count) \(model.t("sources ready"))",
                color: readyProviderCount > 0 ? TokenPilotDesign.calm : TokenPilotDesign.warning
            )
            StatusBadge(
                label: model.capacityRuntimeRecoveryRequired ? model.t("Recovery needed") : model.t("Runtime ready"),
                color: model.capacityRuntimeRecoveryRequired ? TokenPilotDesign.warning : TokenPilotDesign.calm
            )
            StatusBadge(
                label: "\(attentionProviderCount) \(model.t("needs attention"))",
                color: attentionProviderCount == 0 ? TokenPilotDesign.textSecondary : TokenPilotDesign.warning
            )
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("Source health"))
    }

    private var runtimeRecoveryBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(TokenPilotDesign.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("Capacity runtime recovery required"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text(model.t("Capacity alerts use safe defaults until local runtime state is readable again."))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.t("Refresh provider health")) { Task { await model.refresh() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(TokenPilotDesign.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var capacityRefreshNotes: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.t("Capacity refresh notes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            ForEach(Array(model.capacityRefreshErrors.prefix(3))) { error in
                Text("\(model.t(error.provider.displayName)): \(model.localizedStatus(error.redactedMessage))")
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(TokenPilotDesign.cardMuted.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var notificationEffectiveSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hasEffectiveNotificationChannel ? "bell.badge" : "bell.slash")
                .foregroundStyle(hasEffectiveNotificationChannel ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.t("Effective notification delivery"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TokenPilotDesign.textPrimary)
                Text(notificationEffectiveDetail)
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            StatusBadge(
                label: hasEffectiveNotificationChannel ? model.t("Effective ON") : model.t("Effective OFF"),
                color: hasEffectiveNotificationChannel ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t("Effective notification delivery"))
        .accessibilityValue(notificationEffectiveDetail)
    }

    private var readyProviderCount: Int {
        model.providerDiagnostics.filter { diagnostic in
            diagnostic.status == .connected || diagnostic.status == .manual || diagnostic.status == .estimated
        }.count
    }

    private var attentionProviderCount: Int {
        model.providerDiagnostics.filter { diagnostic in
            diagnostic.status != .connected && diagnostic.status != .disabled
        }.count
    }

    private var macOSRouteAvailable: Bool {
        model.settings.macOSNotificationsEnabled && model.settings.notificationPermissionStatus == .granted
    }

    private var telegramRouteAvailable: Bool {
        model.settings.telegramNotificationsEnabled &&
        model.settings.telegram.isEnabled &&
        model.hasSavedTelegramToken &&
        !model.settings.telegram.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var discordRouteAvailable: Bool {
        model.settings.discordNotificationsEnabled &&
        model.settings.discord.isEnabled &&
        model.hasSavedDiscordWebhook
    }

    private var telegramEffectiveNotificationsEnabled: Bool {
        model.settings.globalNotificationsEnabled && telegramRouteAvailable
    }

    private var discordEffectiveNotificationsEnabled: Bool {
        model.settings.globalNotificationsEnabled && discordRouteAvailable
    }

    private var hasEffectiveNotificationChannel: Bool {
        model.settings.globalNotificationsEnabled &&
        (macOSRouteAvailable || telegramRouteAvailable || discordRouteAvailable)
    }

    private var notificationEffectiveDetail: String {
        guard model.settings.globalNotificationsEnabled else {
            return model.t("Global notifications are off.")
        }
        let enabled = [
            macOSRouteAvailable ? "macOS" : nil,
            telegramRouteAvailable ? "Telegram" : nil,
            discordRouteAvailable ? "Discord" : nil
        ].compactMap { $0 }
        guard !enabled.isEmpty else {
            return model.t("No effective notification channels.")
        }
        return String(format: model.t("Effective channels: %@"), enabled.joined(separator: " · "))
    }

    private func sourceSelectionBadge(isSelected: Bool) -> some View {
        StatusBadge(
            label: isSelected ? model.t("Source selected") : model.t("Auto-detect only"),
            color: isSelected ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary
        )
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
        .frame(maxWidth: .infinity)
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


    private var geminiSettingsSnippet: String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        TOKENPILOT_DIR="$HOME/Library/Application Support/TokenPilot"
        ANTIGRAVITY_DIR="$HOME/.gemini/antigravity-cli"
        WRITER="$TOKENPILOT_DIR/antigravity-statusline-writer.py"
        COMMAND="$TOKENPILOT_DIR/antigravity-statusline.sh"
        SETTINGS="$ANTIGRAVITY_DIR/settings.json"

        mkdir -p "$TOKENPILOT_DIR" "$ANTIGRAVITY_DIR"

        cat > "$WRITER" <<'PY'
        #!/usr/bin/env python3
        import json
        import os
        import sys
        import tempfile

        def safe_int(value):
            if isinstance(value, bool):
                return 0
            try:
                return max(int(value), 0)
            except (TypeError, ValueError):
                return 0

        def safe_float(value):
            if isinstance(value, bool):
                return None
            try:
                return float(value)
            except (TypeError, ValueError):
                return None

        def safe_text(value, limit=120):
            if isinstance(value, str):
                text = value
            elif isinstance(value, (int, float, bool)):
                text = str(value)
            else:
                return None
            text = " ".join(text.split())
            if not text:
                return None
            return text[:limit]

        raw = sys.stdin.read()
        try:
            data = json.loads(raw) if raw.strip() else {}
        except Exception:
            data = {}

        context = data.get("context_window") if isinstance(data.get("context_window"), dict) else {}
        usage = context.get("current_usage") if isinstance(context.get("current_usage"), dict) else {}
        model = data.get("model") if isinstance(data.get("model"), dict) else {}
        safe = {
            "product": safe_text(data.get("product"), 64),
            "model": {
                "id": safe_text(model.get("id"), 120),
                "display_name": safe_text(model.get("display_name"), 120)
            },
            "context_window": {
                "total_input_tokens": safe_int(context.get("total_input_tokens")),
                "total_output_tokens": safe_int(context.get("total_output_tokens")),
                "context_window_size": safe_int(context.get("context_window_size")),
                "used_percentage": safe_float(context.get("used_percentage")),
                "remaining_percentage": safe_float(context.get("remaining_percentage")),
                "current_usage": {
                    "input_tokens": safe_int(usage.get("input_tokens")),
                    "output_tokens": safe_int(usage.get("output_tokens")),
                    "cache_creation_input_tokens": safe_int(usage.get("cache_creation_input_tokens")),
                    "cache_read_input_tokens": safe_int(usage.get("cache_read_input_tokens"))
                }
            }
        }

        target = os.path.expanduser("~/Library/Application Support/TokenPilot/antigravity-statusline.json")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".antigravity-statusline-", suffix=".json", dir=os.path.dirname(target))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(safe, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write(chr(10))
        os.replace(tmp, target)

        current = safe["context_window"]["current_usage"]
        tokens = sum(safe_int(current.get(key)) for key in current)
        label = safe["model"]["display_name"] or safe["model"]["id"] or "Antigravity CLI"
        print(f"{label} · {tokens} tok")
        PY

        cat > "$COMMAND" <<'SH'
        #!/usr/bin/env bash
        python3 "$HOME/Library/Application Support/TokenPilot/antigravity-statusline-writer.py"
        SH
        chmod 700 "$WRITER" "$COMMAND"

        python3 - "$SETTINGS" "$COMMAND" <<'PY'
        import json
        import os
        import sys
        import tempfile

        settings_path, command_path = sys.argv[1], sys.argv[2]
        try:
            with open(settings_path, "r", encoding="utf-8") as handle:
                settings = json.load(handle)
        except FileNotFoundError:
            settings = {}
        except Exception as error:
            raise SystemExit(f"TokenPilot could not parse {settings_path}. Fix or back it up before installing: {error}")
        if not isinstance(settings, dict):
            raise SystemExit(f"TokenPilot expected {settings_path} to contain a JSON object.")

        settings["statusLine"] = {
            "type": "command",
            "command": command_path
        }

        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".settings-", suffix=".json", dir=os.path.dirname(settings_path))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(settings, handle, ensure_ascii=False, indent=2)
            handle.write(chr(10))
        os.replace(tmp, settings_path)
        PY

        echo "TokenPilot Antigravity statusLine bridge installed."
        """
    }
}

struct AlertRuleRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    @Binding var rule: AlertRule
    let globalEnabled: Bool
    let macOSChannelEnabled: Bool
    let telegramChannelEnabled: Bool
    let discordChannelEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(localized(rule.provider.displayName, language: language)) · \(rule.window.localizedLabel(language: language))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)

            HStack(spacing: 4) {
                AlertTogglePill(label: "macOS", isOn: $rule.macOSEnabled, isEnabled: globalEnabled && macOSChannelEnabled)
                AlertTogglePill(label: "TG", isOn: $rule.telegramEnabled, isEnabled: globalEnabled && telegramChannelEnabled)
                AlertTogglePill(label: "DC", isOn: $rule.discordEnabled, isEnabled: globalEnabled && discordChannelEnabled)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                AlertTogglePill(label: localized("Reset", language: language), isOn: $rule.resetEnabled, isEnabled: globalEnabled)
                AlertTogglePill(label: "50%", isOn: $rule.fiftyEnabled, isEnabled: globalEnabled)
                AlertTogglePill(label: "80%", isOn: $rule.eightyEnabled, isEnabled: globalEnabled)
                AlertTogglePill(label: "100%", isOn: $rule.hundredEnabled, isEnabled: globalEnabled)
                Spacer(minLength: 0)
            }

            if !globalEnabled {
                Text(localized("Parent notifications are off.", language: language))
                    .font(.caption2)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
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
    var isEnabled = true

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            Text("\(label) \(isOn ? localized("ON", language: language) : localized("OFF", language: language))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isOn && isEnabled ? TokenPilotDesign.calm.opacity(0.16) : TokenPilotDesign.cardMuted)
                .overlay(
                    Capsule().stroke(isOn && isEnabled ? TokenPilotDesign.calm.opacity(0.22) : TokenPilotDesign.border, lineWidth: 1)
                )
                .foregroundStyle(isEnabled ? (isOn ? TokenPilotDesign.calm : TokenPilotDesign.textSecondary) : TokenPilotDesign.textSecondary.opacity(0.55))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : localized("Disabled by notification hierarchy.", language: language))
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
