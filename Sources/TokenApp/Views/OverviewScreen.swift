import SwiftUI
import TokenCore

struct TokenPilotRootView: View {
    @ObservedObject var model: TokenPilotViewModel

    @State private var isRefreshHovered = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.tokenPilotReduceMotionOverride) private var reduceMotionOverride

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        VStack(spacing: TokenPilotDesign.Spacing.section) {
            header
            navigation

            if let message = model.bannerMessage {
                banner(message)
            }

            Group {
                switch model.selectedScreen {
                case .overview:
                    OverviewScreen(model: model)
                case .history:
                    HistoryScreen(model: model)
                case .settings:
                    SettingsScreen(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay { screenShortcutButtons }
        .environment(\.tokenPilotLanguage, model.settings.localization.language)
        .environment(\.locale, Locale(identifier: model.settings.localization.language.localeIdentifier ?? Locale.current.identifier))
        .padding(TokenPilotDesign.Spacing.xl)
        .frame(width: 420, height: 620)
        .foregroundStyle(TokenPilotDesign.text(.primary))
        .background(
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
                .overlay(TokenPilotDesign.glassTint)
        )
    }

    /// Invisible keyboard shortcuts for screen switching (⌘1 Overview, ⌘2 History, ⌘3 Settings).
    /// Mirrors TokenBar's ⌘N tab navigation while keeping the segmented picker as the visual control.
    private var screenShortcutButtons: some View {
        ZStack {
            Button(action: { model.selectedScreen = .overview }) { EmptyView() }
                .keyboardShortcut("1", modifiers: .command)
                .accessibilityHidden(true)
            Button(action: { model.selectedScreen = .history }) { EmptyView() }
                .keyboardShortcut("2", modifiers: .command)
                .accessibilityHidden(true)
            Button(action: { model.selectedScreen = .settings }) { EmptyView() }
                .keyboardShortcut("3", modifiers: .command)
                .accessibilityHidden(true)
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    private var header: some View {
        HStack(spacing: TokenPilotDesign.Spacing.md) {
            TokenPilotBrandMark()
                .scaleEffect(1.0)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xxs) {
                Text(model.t("TokenPilot"))
                    .font(TokenPilotDesign.Typography.appTitle)
                    .foregroundStyle(TokenPilotDesign.text(.primary))
                    .lineLimit(1)

                Text(model.menuBarTitle)
                    .font(TokenPilotDesign.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .help(model.menuBarAccessibilityLabel)
                    .accessibilityLabel(model.menuBarAccessibilityLabel)

                if let lastUpdated = model.lastUpdatedText {
                    Text(lastUpdated)
                        .font(TokenPilotDesign.Typography.micro)
                        .monospacedDigit()
                        .foregroundStyle(TokenPilotDesign.text(.tertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                        .help(model.t("Last updated"))
                        .accessibilityLabel("\(model.t("Last updated")): \(lastUpdated)")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            headerModeIndicator

            refreshButton
        }
        .frame(height: 40)
    }

    private var headerModeIndicator: some View {
        HStack(spacing: TokenPilotDesign.Spacing.xs) {
            Circle()
                .fill(TokenPilotDesign.status(model.dataSourceMode.headerStatusRole))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)

            Text(model.t(model.dataSourceMode.displayLabel))
                .font(TokenPilotDesign.Typography.micro)
                .foregroundStyle(TokenPilotDesign.text(.secondary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.t(model.dataSourceMode.displayLabel))
        .help(model.t(model.dataSourceMode.displayLabel))
    }

    private var navigation: some View {
        Picker(model.t("Screen"), selection: $model.selectedScreen) {
            ForEach(TokenPilotViewModel.Screen.allCases) { screen in
                Text(model.t(screen.rawValue)).tag(screen)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(height: 30)
        .accessibilityLabel(model.t("Screen"))
        .help(model.t("Switch screens with ⌘1, ⌘2, ⌘3"))
        .focusable()
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Group {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(TokenPilotDesign.Typography.glyph)
                        .rotationEffect(.degrees(refreshArrowRotation))
                }
            }
            .frame(width: 30, height: 30)
            .background {
                LiquidGlassBackground(
                    cornerRadius: TokenPilotDesign.Radius.sm,
                    intensity: 0.70,
                    surface: .chip
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TokenPilotDesign.text(.secondary))
        .onHover { hovering in
            if reduceMotion {
                isRefreshHovered = hovering
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                    isRefreshHovered = hovering
                }
            }
        }
        .disabled(model.isRefreshing)
        .keyboardShortcut("r", modifiers: [.command])
        .accessibilityLabel(model.t("Refresh"))
        .accessibilityValue(model.isRefreshing ? model.t("Refreshing") : model.t("Ready"))
        .help(model.t("Refresh"))
        .focusable()
    }

    private var refreshArrowRotation: Double {
        isRefreshHovered ? 50 : 0
    }

    private func banner(_ message: String) -> some View {
        GlassCard(
            padding: TokenPilotDesign.Spacing.lg,
            surface: .cardMuted,
            cornerRadius: TokenPilotDesign.Radius.md,
            intensity: 0.70
        ) {
            HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .accessibilityHidden(true)

                Text(message)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(model.t("Dismiss")) { model.bannerMessage = nil }
                    .buttonStyle(.plain)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .focusable()
            }
        }
    }
}

private extension TokenPilotViewModel.DataSourceMode {
    var headerStatusRole: TokenPilotDesign.StatusRole {
        switch self {
        case .live:
            return .trust
        case .experimental, .compatibilityBridge:
            return .warning
        case .local, .manual, .stale, .mock, .disconnected:
            return .neutral
        }
    }
}

struct OverviewScreen: View {
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.section) {
                UsageSummaryCard(model: model)
                DailyGoalCard(goal: model.dailyGoal, model: model)
                if model.usageStreak.hasActivity {
                    UsageStreakCard(streak: model.usageStreak, model: model)
                }
                if !model.activityMilestones.isEmpty {
                    ActivityMilestonesCard(milestones: model.activityMilestones, model: model)
                }
                if model.budgetGuardrails.hasAnyBudget {
                    BudgetGuardrailCard(budget: model.budgetGuardrails, model: model)
                }
                if !model.contextHealthAssessments.isEmpty {
                    ContextHealthCard(assessments: model.contextHealthAssessments, model: model)
                }

                if hasNoOverviewData {
                    emptyOverviewState
                } else {
                    ProviderOverviewList(
                        snapshots: model.overviewSnapshots,
                        assessments: model.capacityAssessments,
                        presentations: model.capacityPresentations,
                        errors: model.capacityRefreshErrors,
                        runtimeRecoveryRequired: model.capacityRuntimeRecoveryRequired
                    )
                }

                AlertsStatusRow(text: model.alertStatusText)
            }
            .padding(.bottom, TokenPilotDesign.Spacing.section)
        }
    }

    private var hasNoOverviewData: Bool {
        model.overviewSnapshots.isEmpty &&
            model.capacityPresentations.isEmpty &&
            model.capacityRefreshErrors.isEmpty &&
            !model.capacityRuntimeRecoveryRequired
    }

    private var emptyOverviewState: some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
            EmptyStateCard(
                icon: "tray",
                title: model.t("No data"),
                message: model.t("Run Auto-detect or Provider Diagnostics to recover source health.")
            )
            Button(model.t("Open Settings")) {
                model.selectedScreen = .settings
            }
            .buttonStyle(.borderedProminent)
            .tint(TokenPilotDesign.status(.goal))
            .focusable()
        }
    }
}

struct DailyGoalCard: View {
    let goal: DailyGoalProgress
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Daily goal"), systemImage: "flag.fill")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(
                        "\(TokenPilotFormatters.compactNumber(goal.tokens)) / " +
                        "\(TokenPilotFormatters.compactNumber(goal.targetTokens)) " +
                        model.t("tok")
                    )
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                }

                ProgressLine(
                    percent: goal.percent,
                    color: TokenPilotDesign.trust,
                    accessibilityLabel: model.t("Daily goal"),
                    accessibilityValue: "\(TokenPilotFormatters.compactNumber(goal.tokens)) / \(TokenPilotFormatters.compactNumber(goal.targetTokens))"
                )

                Text(model.t("Local activity, not provider quota"))
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.t("Daily goal")): " +
            "\(TokenPilotFormatters.compactNumber(goal.tokens)) / " +
            "\(TokenPilotFormatters.compactNumber(goal.targetTokens))"
        )
    }
}

struct ContextHealthCard: View {
    let assessments: [ContextHealthAssessment]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Context health"), systemImage: "rectangle.compress.vertical")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(model.t("Local signals, not provider quota"))
                        .font(TokenPilotDesign.Typography.micro)
                        .foregroundStyle(TokenPilotDesign.textTertiary)
                        .lineLimit(1)
                }

                ForEach(assessments) { assessment in
                    contextHealthRow(assessment)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("Context health"))
    }

    private func contextHealthRow(_ assessment: ContextHealthAssessment) -> some View {
        HStack(alignment: .center, spacing: TokenPilotDesign.Spacing.sm) {
            Text(model.providerDisplayName(assessment.provider))
                .font(TokenPilotDesign.Typography.caption.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let usedPercent = assessment.usedPercent {
                Text("\(usedPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(levelColor(assessment.level))
                    .lineLimit(1)
            }

            Text(levelText(assessment.level))
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(levelColor(assessment.level))
                .lineLimit(1)

            if assessment.isFillingFast {
                Text(model.t("Filling fast"))
                    .font(TokenPilotDesign.Typography.micro)
                    .foregroundStyle(TokenPilotDesign.status(.warning))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.providerDisplayName(assessment.provider)), \(levelText(assessment.level)), \(usedPercentText(assessment))")
    }

    private func levelText(_ level: ContextHealthLevel) -> String {
        switch level {
        case .healthy: return model.t("Healthy")
        case .elevated: return model.t("Elevated")
        case .bloat: return model.t("Bloat")
        }
    }

    private func levelColor(_ level: ContextHealthLevel) -> Color {
        switch level {
        case .healthy: return TokenPilotDesign.calm
        case .elevated: return TokenPilotDesign.status(.warning)
        case .bloat: return TokenPilotDesign.status(.danger)
        }
    }

    private func usedPercentText(_ assessment: ContextHealthAssessment) -> String {
        guard let usedPercent = assessment.usedPercent else { return model.t("No data") }
        return "\(usedPercent)%"
    }
}

struct UsageStreakCard: View {
    let streak: UsageStreak
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Activity streak"), systemImage: "flame.fill")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("\(TokenPilotFormatters.compactNumber(streak.currentDays)) \(model.t("days"))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TokenPilotDesign.calm)
                        .lineLimit(1)
                }

                Text(streakSummaryText)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)

                Text(model.t("Local activity, not provider quota"))
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.t("Activity streak")): " +
            "\(TokenPilotFormatters.compactNumber(streak.currentDays)) \(model.t("days"))"
        )
    }

    private var streakSummaryText: String {
        String(
            format: model.t("Longest: %@ days"),
            TokenPilotFormatters.compactNumber(streak.longestDays)
        )
    }
}

struct ActivityMilestonesCard: View {
    let milestones: [ActivityMilestone]
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Milestones"), systemImage: "trophy.fill")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(model.t("Local activity, not provider quota"))
                        .font(TokenPilotDesign.Typography.micro)
                        .foregroundStyle(TokenPilotDesign.textTertiary)
                        .lineLimit(1)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 92), spacing: 6)
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(milestones) { milestone in
                        milestoneChip(milestone)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(model.t("Milestones")): \(milestones.map { milestoneLabel($0) }.joined(separator: ", "))"
        )
    }

    private func milestoneChip(_ milestone: ActivityMilestone) -> some View {
        Text(milestoneLabel(milestone))
            .font(TokenPilotDesign.Typography.micro.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(TokenPilotDesign.calm)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(TokenPilotDesign.calm.opacity(0.12)))
    }

    private func milestoneLabel(_ milestone: ActivityMilestone) -> String {
        switch milestone.dimension {
        case .lifetimeTokens:
            return "\(TokenPilotFormatters.compactNumber(milestone.threshold)) \(model.t("tok"))"
        case .activeDays:
            return "\(milestone.threshold) \(model.t("active days"))"
        case .totalRequests:
            return "\(TokenPilotFormatters.compactNumber(milestone.threshold)) \(model.t("requests"))"
        case .longestStreak:
            return "\(milestone.threshold) \(model.t("day streak"))"
        }
    }
}

struct BudgetGuardrailCard: View {
    let budget: BudgetGuardrailSnapshot
    @ObservedObject var model: TokenPilotViewModel

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.md) {
                    Label(model.t("Budget guardrails"), systemImage: "creditcard.fill")
                        .font(TokenPilotDesign.Typography.cardTitle)
                        .foregroundStyle(TokenPilotDesign.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(model.t("Local activity, not provider quota"))
                        .font(TokenPilotDesign.Typography.micro)
                        .foregroundStyle(TokenPilotDesign.textTertiary)
                        .lineLimit(1)
                }

                budgetLine(budget.daily, title: model.t("Today"), language: model.settings.localization.language)
                if let projection = model.budgetPaceProjection {
                    Text(
                        String(
                            format: model.t("At this pace, daily budget exhausts in ~%@ (est.)"),
                            TokenPilotFormatters.compactRemainingTime(until: projection.estimatedExhaustionAt)
                        )
                    )
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(projectionColor(projection))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                if budget.weekly.budgetTokens > 0 {
                    budgetLine(budget.weekly, title: model.t("This week"), language: model.settings.localization.language)
                }
                if budget.monthly.budgetTokens > 0 {
                    budgetLine(budget.monthly, title: model.t("This month"), language: model.settings.localization.language)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(model.t("Budget guardrails")): " +
            "\(TokenPilotFormatters.compactNumber(budget.daily.tokens)) / " +
            "\(TokenPilotFormatters.compactNumber(budget.daily.budgetTokens))"
        )
    }

    @ViewBuilder
    private func budgetLine(_ progress: BudgetGuardrailProgress, title: String, language: TokenPilotLanguage) -> some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: TokenPilotDesign.Spacing.sm) {
                Text(title)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(
                    "\(TokenPilotFormatters.compactNumber(progress.tokens)) / " +
                    "\(TokenPilotFormatters.compactNumber(progress.budgetTokens)) " +
                    model.t("tok")
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(budgetColor(progress))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            }

            ProgressLine(
                percent: progress.percent,
                color: budgetColor(progress),
                accessibilityLabel: title,
                accessibilityValue: "\(progress.percent)%"
            )
        }
    }

    private func budgetColor(_ progress: BudgetGuardrailProgress) -> Color {
        if progress.budgetTokens == 0 { return TokenPilotDesign.text(.tertiary) }
        if progress.crossedThreshold {
            return TokenPilotDesign.status(.danger)
        }
        if progress.percent >= 80 {
            return TokenPilotDesign.status(.warning)
        }
        return TokenPilotDesign.trust
    }

    private func projectionColor(_ projection: BudgetPaceProjection) -> Color {
        if projection.hoursUntilExhaustion < 2 {
            return TokenPilotDesign.status(.danger)
        }
        if projection.hoursUntilExhaustion < 6 {
            return TokenPilotDesign.status(.warning)
        }
        return TokenPilotDesign.text(.secondary)
    }
}

struct CapacityDisplayItem: Identifiable {
    let assessment: CapacityAssessment
    let presentation: CapacityPresentation

    var id: String { assessment.transitionKey }
    var provider: Provider { assessment.observation.seriesID.provider }
    var valueKind: CapacityUnit { assessment.observation.value.kind }
    var remainingPercent: Int? { Int(presentation.data["remainingPercent"] ?? "") }
    var usedPercent: Int? { Int(presentation.data["usedPercent"] ?? "") }
    var count: Int? { Int(presentation.data["count"] ?? "") }
    var tokens: Int? { Int(presentation.data["tokens"] ?? "") }
    var resetAt: Date? { assessment.observation.resetAt }
    var observedAt: Date { assessment.observation.observedAt }

    var progressPercent: Int? {
        valueKind == .percent ? remainingPercent : nil
    }

    var paceProjection: CapacityPaceProjection? {
        CapacityPaceService().projection(observation: assessment.observation)
    }

    var paceZone: CapacityPacingZoneAssessment? {
        CapacityPaceService().pacingZone(observation: assessment.observation)
    }

    func paceText(language: TokenPilotLanguage) -> String {
        guard let projection = paceProjection else { return "" }
        let zonePrefix: String
        if let zone = paceZone?.zone {
            zonePrefix = localized(zoneLabel(zone), language: language) + " · "
        } else {
            zonePrefix = ""
        }
        return zonePrefix + String(
            format: localized("At this pace, exhausts in ~%@ (est.)", language: language),
            TokenPilotFormatters.compactRemainingTime(until: projection.estimatedExhaustionAt)
        )
    }

    var paceZoneColor: Color {
        switch paceZone?.zone {
        case .hot:
            return TokenPilotDesign.status(.danger)
        case .steady:
            return TokenPilotDesign.status(.warning)
        case .safe, nil:
            return TokenPilotDesign.status(.calm)
        }
    }

    private func zoneLabel(_ zone: CapacityPacingZone) -> String {
        switch zone {
        case .safe: return "Safe pace"
        case .steady: return "Steady pace"
        case .hot: return "Hot pace"
        }
    }

    var progressColor: Color {
        TokenPilotDesign.quotaRiskColor(assessment.risk, eligibility: assessment.alertEligibility)
    }
    var statusColor: Color {
        switch assessment.risk {
        case .critical:
            return TokenPilotDesign.status(.danger)
        case .warning:
            return TokenPilotDesign.status(.warning)
        case .normal:
            return assessment.alertEligibility == .percent ? TokenPilotDesign.status(.calm) : TokenPilotDesign.text(.secondary)
        case .informational:
            return TokenPilotDesign.text(.secondary)
        case .stale:
            return TokenPilotDesign.status(.warning)
        case .unavailable:
            return TokenPilotDesign.text(.tertiary)
        }
    }

    var valueColor: Color {
        valueKind == .percent ? progressColor : TokenPilotDesign.text(.primary)
    }



    func title(language: TokenPilotLanguage) -> String {
        "\(localized(provider.displayName, language: language)) · \(seriesLabel(language: language))"
    }

    func seriesLabel(language: TokenPilotLanguage) -> String {
        let series = assessment.observation.seriesID
        switch series.unit {
        case .percent:
            if let duration = series.durationMinutes {
                return durationLabel(duration, language: language)
            }
            switch series.providerWindowID {
            case "five-hour": return localized("5h", language: language)
            case "seven-day": return localized("Week", language: language)
            default: return localized("Limit", language: language)
            }
        case .currency:
            return localized("Balance", language: language)
        case .requestCount:
            return localized("Requests", language: language)
        case .tokens:
            return localized("Context", language: language)
        case .credits:
            return localized("Credits", language: language)
        }
    }

    func primaryValue(language: TokenPilotLanguage) -> String {
        switch valueKind {
        case .percent:
            guard let remainingPercent else { return "—" }
            return "\(remainingPercent)%"
        case .currency:
            guard let amount = presentation.data["amount"],
                  let currency = presentation.data["currency"] else {
                return "—"
            }
            return formattedMoney(amount: amount, currency: currency)
        case .requestCount:
            guard let count else { return "—" }
            return "\(TokenPilotFormatters.compactNumber(count)) \(localized("Requests", language: language))"
        case .tokens:
            guard let tokens else { return "—" }
            return "\(TokenPilotFormatters.compactNumber(tokens)) \(localized("tok", language: language))"
        case .credits:
            guard let credits = presentation.data["credits"] else { return "—" }
            return "\(TokenPilotFormatters.creditAmount(credits)) \(localized("credits", language: language))"
        }
    }

    func statusLabel(language: TokenPilotLanguage) -> String {
        if assessment.alertEligibility == .percent {
            switch assessment.risk {
            case .critical: return localized("Critical", language: language)
            case .warning: return localized("Warning", language: language)
            case .normal: return localized("Stable", language: language)
            case .informational: return localized("Informational", language: language)
            case .stale: return localized("Stale", language: language)
            case .unavailable: return localized("Unavailable", language: language)
            }
        }
        return provenanceLabel(language: language)
    }

    func freshnessLabel(language: TokenPilotLanguage) -> String {
        switch assessment.freshness {
        case .fresh: return localized("Fresh", language: language)
        case .stale: return localized("Stale", language: language)
        case .unavailable: return localized("Unavailable", language: language)
        }
    }

    func provenanceLabel(language: TokenPilotLanguage) -> String {
        switch assessment.eligibilityReason {
        case .eligible:
            return localized("Provider reported", language: language)
        case .unsupportedSource:
            switch assessment.observation.stability {
            case .compatibilityBridge:
                return localized("Bridge", language: language)
            case .experimentalTransport:
                return localized("Experimental", language: language)
            case .manual:
                return localized("Manual source", language: language)
            case .unavailable:
                return localized("Unavailable", language: language)
            case .supported:
                return localized("Unsupported source", language: language)
            }
        case .manualSource:
            return localized("Manual source", language: language)
        case .staleEvidence:
            return localized("Stale evidence", language: language)
        case .activityOnly:
            return localized("Activity only", language: language)
        case .invalidEvidence:
            return localized("Unavailable", language: language)
        case .pendingBalanceBinding:
            return localized("Pending balance", language: language)
        }
    }


    func authorityLabel(language: TokenPilotLanguage) -> String {
        switch presentation.data["authority"] {
        case "providerReported": return localized("Provider reported", language: language)
        case "localDerived": return localized("Local derived", language: language)
        case "userEntered": return localized("User entered", language: language)
        case "synthetic": return localized("Synthetic", language: language)
        default: return localized("Unavailable", language: language)
        }
    }

    func stabilityLabel(language: TokenPilotLanguage) -> String {
        switch presentation.data["stability"] {
        case "supported": return localized("Supported", language: language)
        case "compatibilityBridge": return localized("Compatibility bridge", language: language)
        case "experimentalTransport": return localized("Experimental connector", language: language)
        case "manual": return localized("Manual entry", language: language)
        default: return localized("Unavailable", language: language)
        }
    }

    func actionLabel(language: TokenPilotLanguage) -> String {
        switch assessment.actionKey {
        case .waitForReset: return localized("Wait for reset", language: language)
        case .refreshProvider: return localized("Refresh provider", language: language)
        case .reviewSource: return localized("Review source", language: language)
        case .reviewExperimentalConnector: return localized("Review experimental connector", language: language)
        case .enterManualValue: return localized("Enter manual value", language: language)
        case .reviewBalance: return localized("Review balance", language: language)
        case .openProviderDiagnostics: return localized("Open Provider Diagnostics", language: language)
        }
    }

    func guidanceLabel(language: TokenPilotLanguage) -> String {
        "\(localized("Next action", language: language)): \(actionLabel(language: language))"
    }


    func resetText(language: TokenPilotLanguage) -> String {
        guard let resetAt else { return localized("No reset", language: language) }
        return "\(localized("Reset", language: language)) \(TokenPilotFormatters.remainingTime(until: resetAt, language: language, now: assessment.observation.observedAt))"
    }

    func observedText(language: TokenPilotLanguage) -> String {
        "\(localized("Last updated", language: language)) \(TokenPilotFormatters.clock(assessment.observation.observedAt, language: language))"
    }

    func truthSummary(language: TokenPilotLanguage) -> String {
        [
            authorityLabel(language: language),
            stabilityLabel(language: language),
            freshnessLabel(language: language)
        ].joined(separator: " · ")
    }

    func metadataSummary(language: TokenPilotLanguage) -> String {
        [
            resetText(language: language),
            observedText(language: language)
        ].joined(separator: " · ")
    }

    var showsRiskStatusBadge: Bool {
        assessment.alertEligibility == .percent
    }

    func progressAccessibilityValue(language: TokenPilotLanguage) -> String {
        if let remainingPercent, let usedPercent {
            return "\(localized("Remaining", language: language)) \(remainingPercent)%, \(localized("Used", language: language)) \(usedPercent)%"
        }
        if let remainingPercent {
            return "\(localized("Remaining", language: language)) \(remainingPercent)%"
        }
        return localized("Unavailable", language: language)
    }

    private func durationLabel(_ minutes: Int, language: TokenPilotLanguage) -> String {
        if minutes == 300 { return localized("5h", language: language) }
        if minutes == 10_080 { return localized("Week", language: language) }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1_440, minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        return "\(minutes)min"
    }

    private func formattedMoney(amount: String, currency: String) -> String {
        guard let decimal = Decimal(string: amount) else {
            return "\(currency.uppercased()) \(amount)"
        }
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        if currency.uppercased() == "USD" {
            return String(format: "$%.2f", value)
        }
        return "\(currency.uppercased()) \(String(format: "%.2f", value))"
    }
}

private func capacityDisplayItems(
    assessments: [CapacityAssessment],
    presentations: [CapacityPresentation]
) -> [CapacityDisplayItem] {
    Array(zip(assessments, presentations)).map {
        CapacityDisplayItem(assessment: $0.0, presentation: $0.1)
    }
}

private func capacityDisplayRank(_ item: CapacityDisplayItem) -> Int {
    let eligibilityRank: Int
    switch item.assessment.alertEligibility {
    case .percent: eligibilityRank = 100
    case .balance: eligibilityRank = 70
    case .ineligible: eligibilityRank = 20
    }

    let riskRank: Int
    switch item.assessment.risk {
    case .critical: riskRank = 60
    case .warning: riskRank = 50
    case .normal: riskRank = 40
    case .informational: riskRank = 30
    case .stale: riskRank = 10
    case .unavailable: riskRank = 0
    }

    return eligibilityRank + riskRank
}

struct UsageSummaryCard: View {
    @Environment(\.tokenPilotLanguage) private var language
    @ObservedObject var model: TokenPilotViewModel
    var body: some View {
        if let primaryItem {
            primaryContent(for: primaryItem)
        } else {
            unavailableContent
        }
    }

    private var items: [CapacityDisplayItem] {
        capacityDisplayItems(
            assessments: model.capacityAssessments,
            presentations: model.capacityPresentations
        )
    }

    private var primaryItem: CapacityDisplayItem? {
        items.sorted { capacityDisplayRank($0) > capacityDisplayRank($1) }.first
    }

    private func primaryContent(for item: CapacityDisplayItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                capacityHeader(
                    value: item.primaryValue(language: language),
                    detail: item.title(language: language),
                    valueColor: item.valueColor,
                    statusLabel: item.showsRiskStatusBadge ? item.statusLabel(language: language) : nil,
                    statusColor: item.statusColor
                )

                if let progressPercent = item.progressPercent {
                    ProgressLine(
                        percent: progressPercent,
                        color: item.progressColor,
                        accessibilityLabel: localized("Remaining capacity", language: language),
                        accessibilityValue: item.progressAccessibilityValue(language: language)
                    )
                }

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                    compactSummaryLine(item.truthSummary(language: language), color: TokenPilotDesign.text(.secondary))
                    compactSummaryLine(item.guidanceLabel(language: language), color: TokenPilotDesign.text(.secondary))
                    let paceText = item.paceText(language: language)
                    if !paceText.isEmpty {
                        compactSummaryLine(paceText, color: item.paceZoneColor)
                    }
                }

                liveMetadata(for: item)

                if let error = model.capacityRefreshErrors.first {
                    CapacityErrorInline(error: error)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    private func liveMetadata(for item: CapacityDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
            if let resetAt = item.resetAt, resetAt > Date() {
                HStack(spacing: TokenPilotDesign.Spacing.xs) {
                    Text(localized("Reset in", language: language))
                    LiveResetCountdown(resetAt: resetAt)
                }
                .font(TokenPilotDesign.Typography.micro)
                .foregroundStyle(TokenPilotDesign.text(.tertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            } else {
                metadataLine(item.resetText(language: language))
            }
            metadataLine(item.observedText(language: language))
        }
    }

    private var unavailableContent: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                capacityHeader(
                    value: "—",
                    detail: localized("Capacity unavailable", language: language),
                    valueColor: TokenPilotDesign.text(.secondary),
                    statusLabel: unavailableStatus,
                    statusColor: unavailableStatusColor
                )

                VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                    compactSummaryLine(unavailableDetail, color: TokenPilotDesign.text(.secondary))
                    compactSummaryLine(unavailableGuidance, color: TokenPilotDesign.text(.secondary))
                }

                metadataLine(unavailableMetadataSummary)

                if let error = model.capacityRefreshErrors.first {
                    CapacityErrorInline(error: error)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(localized("Capacity unavailable", language: language)), \(unavailableStatus), \(unavailableDetail), \(unavailableGuidance)")
    }

    private func capacityHeader(value: String, detail: String, valueColor: Color, statusLabel: String?, statusColor: Color) -> some View {
        HStack(alignment: .top, spacing: TokenPilotDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
                Text(value)
                    .font(TokenPilotDesign.Typography.metricLarge)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(detail)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if let statusLabel, !statusLabel.isEmpty {
                StatusBadge(label: statusLabel, color: statusColor)
            }
        }
    }

    @ViewBuilder
    private func compactSummaryLine(_ text: String, color: Color) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
    }

    private func metadataLine(_ text: String) -> some View {
        Text(text)
            .font(TokenPilotDesign.Typography.micro)
            .foregroundStyle(TokenPilotDesign.text(.tertiary))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var unavailableMetadataSummary: String {
        [
            localized("No reset", language: language),
            "\(localized("Last updated", language: language)) —"
        ].joined(separator: " · ")
    }

    private func accessibilityLabel(for item: CapacityDisplayItem) -> String {
        [
            item.title(language: language),
            item.primaryValue(language: language),
            "\(localized("Provenance", language: language)): \(item.authorityLabel(language: language))",
            "\(localized("Status", language: language)): \(item.stabilityLabel(language: language))",
            "\(localized("Freshness", language: language)): \(item.freshnessLabel(language: language))",
            item.resetText(language: language),
            item.observedText(language: language),
            item.guidanceLabel(language: language)
        ].joined(separator: ", ")
    }

    private var unavailableStatus: String {
        if model.capacityRuntimeRecoveryRequired {
            return localized("Runtime recovery required", language: language)
        }
        if let error = model.capacityRefreshErrors.first {
            return error.category.localizedLabel(language: language)
        }
        return localized("No trusted capacity", language: language)
    }

    private var unavailableStatusColor: Color {
        if model.capacityRuntimeRecoveryRequired || !model.capacityRefreshErrors.isEmpty {
            return TokenPilotDesign.status(.warning)
        }
        return TokenPilotDesign.text(.secondary)
    }


    private var unavailableDetail: String {
        if model.capacityRuntimeRecoveryRequired {
            return localized("Capacity runtime recovery required", language: language)
        }
        if let error = model.capacityRefreshErrors.first {
            return localized(error.redactedMessage, language: language)
        }
        return localized("Connect providers in Settings", language: language)
    }

    private var unavailableGuidance: String {
        "\(localized("Next action", language: language)): \(localized("Open Provider Diagnostics", language: language))"
    }
}

struct ProviderOverviewList: View {
    @Environment(\.tokenPilotLanguage) private var language
    let snapshots: [ProviderSnapshot]
    let assessments: [CapacityAssessment]
    let presentations: [CapacityPresentation]
    let errors: [CapacityRefreshError]
    let runtimeRecoveryRequired: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.lg) {
                TokenPilotSectionHeader(
                    title: localized("Providers", language: language),
                    systemImage: "list.bullet.rectangle"
                ) {
                    StatusBadge(label: "\(providerOrder.count)", color: TokenPilotDesign.text(.secondary))
                }

                if providerOrder.isEmpty {
                    EmptyInlineState(text: localized("No trusted capacity", language: language))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(providerOrder.enumerated()), id: \.element) { index, provider in
                            providerRow(provider)
                            if index < providerOrder.count - 1 {
                                TokenPilotSeparator()
                                    .padding(.vertical, TokenPilotDesign.Spacing.lg)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized("Providers", language: language))
        .accessibilityValue(providerOrder.map { localized($0.displayName, language: language) }.joined(separator: ", "))
    }

    private var items: [CapacityDisplayItem] {
        capacityDisplayItems(assessments: assessments, presentations: presentations)
    }

    private var providerOrder: [Provider] {
        var ordered: [Provider] = []
        func append(_ provider: Provider) {
            if !ordered.contains(provider) {
                ordered.append(provider)
            }
        }

        for provider in snapshots.map(\.provider) {
            append(provider)
        }
        for provider in items.map(\.provider) {
            append(provider)
        }
        for provider in errors.map(\.provider) {
            append(provider)
        }
        return ordered
    }

    @ViewBuilder
    private func providerRow(_ provider: Provider) -> some View {
        let providerItems = items
            .filter { $0.provider == provider }
            .sorted { capacityDisplayRank($0) > capacityDisplayRank($1) }
        let providerErrors = errors.filter { $0.provider == provider }
        let snapshot = snapshots.first { $0.provider == provider }

        if providerItems.isEmpty {
            ProviderCapacityUnavailableRow(
                provider: provider,
                snapshot: snapshot,
                errors: providerErrors,
                runtimeRecoveryRequired: runtimeRecoveryRequired
            )
        } else {
            ProviderCapacityRow(
                provider: provider,
                items: providerItems,
                errors: providerErrors
            )
        }
    }
}

struct ProviderCapacityRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let provider: Provider
    let items: [CapacityDisplayItem]
    let errors: [CapacityRefreshError]

    var body: some View {
        let primary = items[0]

        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
            CompactProviderStatusRow(
                provider: provider,
                title: localized(provider.displayName, language: language),
                subtitle: primary.seriesLabel(language: language),
                value: primary.primaryValue(language: language),
                valueColor: primary.valueColor,
                providerMarkSize: 26
            ) {
                if primary.showsRiskStatusBadge {
                    StatusBadge(label: primary.statusLabel(language: language), color: primary.statusColor)
                }
            }

            if let progressPercent = primary.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: primary.progressColor,
                    accessibilityLabel: "\(localized(provider.displayName, language: language)) \(localized("Remaining capacity", language: language))",
                    accessibilityValue: primary.progressAccessibilityValue(language: language)
                )
            }

            providerEvidenceSummary(for: primary)

            ForEach(Array(items.dropFirst())) { item in
                CapacitySignalLine(item: item, referenceItem: primary)
            }

            if let error = errors.first {
                CapacityErrorInline(error: error)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(primary: primary))
    }

    private func providerEvidenceSummary(for item: CapacityDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.xs) {
            compactProviderLine(item.truthSummary(language: language), color: TokenPilotDesign.text(.secondary))
            compactProviderLine(item.guidanceLabel(language: language), color: TokenPilotDesign.text(.secondary))
            let paceText = item.paceText(language: language)
            if !paceText.isEmpty {
                compactProviderLine(paceText, color: item.paceZoneColor)
            }
            providerMetadataLine(item.metadataSummary(language: language))
        }
    }

    @ViewBuilder
    private func compactProviderLine(_ text: String, color: Color) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
    }

    private func providerMetadataLine(_ text: String) -> some View {
        Text(text)
            .font(TokenPilotDesign.Typography.micro)
            .foregroundStyle(TokenPilotDesign.text(.tertiary))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private func accessibilityLabel(primary: CapacityDisplayItem) -> String {
        [
            localized(provider.displayName, language: language),
            primary.seriesLabel(language: language),
            primary.primaryValue(language: language),
            primary.truthSummary(language: language),
            primary.guidanceLabel(language: language),
            primary.metadataSummary(language: language)
        ].joined(separator: ", ")
    }
}

struct CapacitySignalLine: View {
    @Environment(\.tokenPilotLanguage) private var language
    let item: CapacityDisplayItem
    let referenceItem: CapacityDisplayItem?

    init(item: CapacityDisplayItem, referenceItem: CapacityDisplayItem? = nil) {
        self.item = item
        self.referenceItem = referenceItem
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.seriesLabel(language: language))
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textSecondary)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)

                Text(item.primaryValue(language: language))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(item.valueColor)
                    .lineLimit(1)

                Spacer(minLength: 6)
            }

            Text(item.metadataSummary(language: language))
                .font(TokenPilotDesign.Typography.micro)
                .foregroundStyle(TokenPilotDesign.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            if shouldShowEvidenceSummary {
                Text(evidenceSummary)
                    .font(TokenPilotDesign.Typography.caption)
                    .foregroundStyle(TokenPilotDesign.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            if let progressPercent = item.progressPercent {
                ProgressLine(
                    percent: progressPercent,
                    color: item.progressColor,
                    accessibilityLabel: item.title(language: language),
                    accessibilityValue: item.progressAccessibilityValue(language: language)
                )
            }
        }
    }

    private var shouldShowEvidenceSummary: Bool {
        guard let referenceItem else { return true }
        return item.truthSummary(language: language) != referenceItem.truthSummary(language: language) ||
            item.guidanceLabel(language: language) != referenceItem.guidanceLabel(language: language)
    }

    private var evidenceSummary: String {
        [
            item.truthSummary(language: language),
            item.guidanceLabel(language: language)
        ].joined(separator: " · ")
    }
}

struct ProviderCapacityUnavailableRow: View {
    @Environment(\.tokenPilotLanguage) private var language
    let provider: Provider
    let snapshot: ProviderSnapshot?
    let errors: [CapacityRefreshError]
    let runtimeRecoveryRequired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TokenPilotDesign.Spacing.md) {
            CompactProviderStatusRow(
                provider: provider,
                title: localized(provider.displayName, language: language),
                subtitle: detailText,
                value: localized("Unavailable", language: language),
                valueColor: TokenPilotDesign.text(.secondary),
                providerMarkSize: 26
            ) {
                StatusBadge(label: statusLabel, color: statusColor)
            }

            Text(guidanceText)
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(TokenPilotDesign.text(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            if let error = errors.first {
                CapacityErrorInline(error: error)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(localized(provider.displayName, language: language)), \(statusLabel), \(detailText), \(guidanceText)")
    }


    private var statusLabel: String {
        if runtimeRecoveryRequired {
            return localized("Runtime recovery required", language: language)
        }
        if let error = errors.first {
            return error.category.localizedLabel(language: language)
        }
        if snapshot?.dataSource == .mock {
            return localized("Mock preview", language: language)
        }
        if snapshot?.dataSource == .manual || snapshot?.confidence == .manual {
            return localized("Manual source", language: language)
        }
        if snapshot?.isStale == true {
            return localized("Stale", language: language)
        }
        return localized("No trusted capacity", language: language)
    }

    private var statusColor: Color {
        if runtimeRecoveryRequired || !errors.isEmpty {
            return TokenPilotDesign.status(.warning)
        }
        if snapshot?.isStale == true {
            return TokenPilotDesign.status(.warning)
        }
        return TokenPilotDesign.text(.secondary)
    }


    private var actionLabel: String {
        if runtimeRecoveryRequired {
            return localized("Open Provider Diagnostics", language: language)
        }
        if errors.isEmpty == false {
            return localized("Refresh provider", language: language)
        }
        return localized("Open Provider Diagnostics", language: language)
    }

    private var guidanceText: String {
        "\(localized("Next action", language: language)): \(actionLabel)"
    }

    private var detailText: String {
        if runtimeRecoveryRequired {
            return localized("Capacity runtime recovery required", language: language)
        }
        if let error = errors.first {
            return localized(error.redactedMessage, language: language)
        }
        if snapshot?.dataSource == .mock {
            return localized("Sample data is not live capacity", language: language)
        }
        if snapshot?.dataSource == .manual || snapshot?.confidence == .manual {
            return localized("Manual values are not live quota", language: language)
        }
        return localized("No trusted capacity presentation", language: language)
    }
}

struct CapacityErrorInline: View {
    @Environment(\.tokenPilotLanguage) private var language
    let error: CapacityRefreshError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TokenPilotDesign.textSecondary)
            Text(localized(error.redactedMessage, language: language))
                .font(TokenPilotDesign.Typography.caption)
                .foregroundStyle(TokenPilotDesign.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            SemanticChip(
                label: error.category.localizedLabel(language: language),
                systemImage: "info.circle",
                color: TokenPilotDesign.textSecondary
            )
        }
    }
}


private extension CapacityRefreshErrorCategory {
    func localizedLabel(language: TokenPilotLanguage) -> String {
        switch self {
        case .disabled: return localized("Disabled", language: language)
        case .sourceUnavailable: return localized("Source unavailable", language: language)
        case .authenticationRequired: return localized("Authentication required", language: language)
        case .processFailure: return localized("Process failure", language: language)
        case .timeout: return localized("Timeout", language: language)
        case .cancelled: return localized("Cancelled", language: language)
        case .malformedResponse: return localized("Malformed response", language: language)
        case .unsupportedSeries: return localized("Unsupported source", language: language)
        case .outputLimitExceeded: return localized("Output limit exceeded", language: language)
        }
    }
}

struct AlertsStatusRow: View {
    let text: String

    var body: some View {
        GlassCard(
            padding: TokenPilotDesign.Spacing.md,
            surface: .cardMuted,
            cornerRadius: TokenPilotDesign.Radius.md,
            intensity: 0.55
        ) {
            HStack(spacing: TokenPilotDesign.Spacing.md) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .accessibilityHidden(true)

                Text(text)
                    .font(TokenPilotDesign.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(TokenPilotDesign.text(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
