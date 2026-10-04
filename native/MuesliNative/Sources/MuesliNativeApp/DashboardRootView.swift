import SwiftUI
import MuesliCore

enum DashboardWindowLayout {
    /// Narrow enough to sit beside a call window while preserving a useful
    /// notes editor when the sidebar is collapsed or hidden.
    static let minimumContentWidth: CGFloat = 520
    static let minimumContentHeight: CGFloat = 600
    static let compactQuickNotesThreshold: CGFloat = 600

    static func usesCompactQuickNotes(width: CGFloat, hasOpenMeeting: Bool) -> Bool {
        hasOpenMeeting && width < compactQuickNotesThreshold
    }
}

private struct CompactQuickNotesEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesCompactQuickNotes: Bool {
        get { self[CompactQuickNotesEnvironmentKey.self] }
        set { self[CompactQuickNotesEnvironmentKey.self] = newValue }
    }
}

@Observable
final class DashboardSidebarPresentation {
    var isCollapsed = false

    func toggle() {
        isCollapsed.toggle()
    }
}

struct DashboardContentLayout<SidebarContent: View, DetailContent: View>: View {
    let usesCompactQuickNotes: Bool
    @ViewBuilder let sidebar: () -> SidebarContent
    @ViewBuilder let detail: () -> DetailContent

    var body: some View {
        HSplitView {
            if !usesCompactQuickNotes {
                sidebar()
            }

            detail()
                .environment(\.usesCompactQuickNotes, usesCompactQuickNotes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MuesliTheme.backgroundBase)
        }
    }
}

private struct HushSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var featureTourTargetFrames: [FeatureTourTarget: CGRect] = [:]
    @State private var sidebarPresentation: DashboardSidebarPresentation

    init(
        appState: AppState,
        controller: MuesliController,
        sidebarPresentation: DashboardSidebarPresentation = DashboardSidebarPresentation()
    ) {
        self.appState = appState
        self.controller = controller
        _sidebarPresentation = State(initialValue: sidebarPresentation)
    }

    private var sidebarCollapsed: Bool {
        controller.hushModel == nil ? sidebarPresentation.isCollapsed : appState.hushSidebarCollapsed
    }
    var sidebarView: SidebarView {
        SidebarView(
            appState: appState,
            controller: controller,
            isCollapsed: sidebarCollapsed,
            onToggleCollapsed: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if controller.hushModel == nil { sidebarPresentation.toggle() }
                    else { appState.hushSidebarCollapsed.toggle() }
                }
            }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactQuickNotes = DashboardWindowLayout.usesCompactQuickNotes(
                width: proxy.size.width,
                hasOpenMeeting: hasOpenMeeting
            )

            DashboardContentLayout(usesCompactQuickNotes: usesCompactQuickNotes) {
                sidebarView
                .frame(
                    minWidth: sidebarCollapsed ? 68 : 240,
                    idealWidth: sidebarCollapsed ? 68 : 260,
                    maxWidth: sidebarCollapsed ? 68 : 300
                )
                .background {
                    GeometryReader { sidebarGeometry in
                        Color.clear.preference(key: HushSidebarWidthKey.self, value: sidebarGeometry.size.width)
                    }
                }
                .onPreferenceChange(HushSidebarWidthKey.self) { width in
                    if abs(appState.hushSidebarWidth - width) > 0.5 { appState.hushSidebarWidth = width }
                }
            } detail: {
                detailContent
            }
        }
        .frame(
            minWidth: DashboardWindowLayout.minimumContentWidth,
            minHeight: DashboardWindowLayout.minimumContentHeight
        )
        .preferredColorScheme(controller.hushModel == nil ? (appState.config.darkMode ? .dark : .light) : appState.hushAppearance.colorScheme)
        .overlay(alignment: .bottom) {
            if let model = controller.hushModel { HushStatusView(model: model) }
        }
        .onPreferenceChange(FeatureTourTargetPreferenceKey.self) { frames in
            guard FeatureTourFrameTracking.hasMeaningfulChange(
                from: featureTourTargetFrames,
                to: frames
            ) else { return }
            featureTourTargetFrames = frames
        }
        .overlay {
            GeometryReader { proxy in
                if let invitation = appState.pendingFeatureTourInvitation {
                    FeatureTourInvitationView(
                        tour: invitation,
                        onAccept: { controller.acceptFeatureTourInvitation() },
                        onSkip: { controller.skipFeatureTourInvitation() }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(101)
                } else if let tour = appState.activeFeatureTour,
                          tour.steps.indices.contains(appState.featureTourStepIndex) {
                    let step = tour.steps[appState.featureTourStepIndex]
                    let globalRootFrame = proxy.frame(in: .global)
                    let targetFrame = step.target
                        .flatMap { featureTourTargetFrames[$0] }
                        .map {
                            $0.offsetBy(
                                dx: -globalRootFrame.minX,
                                dy: -globalRootFrame.minY
                            )
                        }
                    if step.target == nil || targetFrame != nil {
                        FeatureTourOverlay(
                            tour: tour,
                            stepIndex: appState.featureTourStepIndex,
                            spotlightRect: targetFrame,
                            containerSize: proxy.size,
                            onBack: { controller.showPreviousFeatureTourStep() },
                            onNext: { controller.showNextFeatureTourStep() },
                            onDismiss: { controller.dismissFeatureTour() }
                        )
                        .zIndex(100)
                    }
                }
            }
        }
        .alert(
            appState.contributionMilestonePrompt?.title ?? "Muesli milestone",
            isPresented: Binding(
                get: { appState.contributionMilestonePrompt != nil },
                set: { if !$0 { controller.dismissContributionMilestonePrompt() } }
            )
        ) {
            if appState.contributionMilestonePrompt?.showGitHubStar == true {
                Button("Star on GitHub") {
                    controller.openContributionMilestoneAction(.githubStar)
                }
            }
            if appState.contributionMilestonePrompt?.showBuyMeCoffee == true {
                Button("Buy Me a Coffee") {
                    controller.openContributionMilestoneAction(.buyMeCoffee)
                }
            }
            if appState.contributionMilestonePrompt?.showTweetAboutMuesli == true {
                Button("Tweet about Muesli") {
                    controller.openContributionMilestoneAction(.tweetAboutMuesli)
                }
            }
            if appState.contributionMilestonePrompt?.showPostOnLinkedIn == true {
                Button("Post about Muesli on LinkedIn") {
                    controller.openContributionMilestoneAction(.postOnLinkedIn)
                }
            }
            Button("Later", role: .cancel) {
                controller.dismissContributionMilestonePrompt()
            }
        } message: {
            Text(appState.contributionMilestonePrompt?.message ?? "")
        }
        .onAppear {
            controller.recordContributionMilestonePromptSeen()
        }
        .onChange(of: appState.contributionMilestonePrompt?.id) { _, _ in
            controller.recordContributionMilestonePromptSeen()
        }
        .sheet(
            item: Binding<DiagnosticIncident?>(
                get: { appState.pendingDiagnosticIncident },
                set: { if $0 == nil { controller.dismissDiagnosticIncidentPrompt() } }
            )
        ) { incident in
            DiagnosticIncidentReportView(
                incident: incident,
                onOpenIssue: { controller.openDiagnosticIncidentIssue(incident) },
                onDismiss: { controller.dismissDiagnosticIncidentPrompt() }
            )
        }
    }

    private var hasOpenMeeting: Bool {
        if case .document = appState.meetingsNavigationState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.isSearchActive,
           case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: {
                    appState.meetingsNavigationState = .browser
                    appState.selectedMeetingID = nil
                    appState.selectedMeetingRecord = nil
                },
                backLabel: "Back to Search"
            )
            .id(id)
        } else if appState.selectedTab == .timeline,
                  appState.meetingDetailReturnDestination == .timeline,
                  case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: { controller.showTimelineHome() },
                backLabel: "Back to Timeline"
            )
            .id(id)
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .timeline:
                VStack(spacing: 0) {
                    if let bridge = controller.hushBridge {
                        HushUpcomingView(calendar: bridge.calendar, model: bridge.model)
                    }
                    TimelineView(appState: appState, controller: controller)
                }
            case .chat:
                if let model = controller.hushModel { HushChatView(model: model) }
            case .dictations:
                DictationsView(appState: appState, controller: controller)
            case .insights:
                InsightsView(
                    initialSection: appState.insightsInitialSection,
                    loadSnapshot: { range in try await controller.insightsSnapshot(range: range) },
                    onBack: { controller.closeInsights() },
                    backLabel: appState.insightsBackLabel
                )
            case .meetings:
                MeetingsView(appState: appState, controller: controller)
            case .dictionary:
                DictionaryView(appState: appState, controller: controller)
            case .models:
                ModelsView(appState: appState, controller: controller)
            case .shortcuts:
                ShortcutsView(appState: appState, controller: controller)
            case .settings:
                if let model = controller.hushModel {
                    HushSettingsView(model: model, controller: controller)
                } else {
                    SettingsView(appState: appState, controller: controller)
                }
            case .about:
                AboutView(
                    appState: appState,
                    onOpenManualDiagnosticReport: { controller.openManualDiagnosticReport() },
                    onSetAutomaticDiagnosticIssuePrompts: { controller.setAutomaticDiagnosticIssuePrompts($0) }
                )
            }
        }
    }
}
