import AppKit
import EventKit
import SwiftUI

/// Read-only local calendar for the "Coming up" card. Events come from EventKit on this Mac,
/// stay in memory, and are never logged, persisted, or sent to inference.
@MainActor
final class CalendarFeed: ObservableObject {
    enum Access { case disabledForE2E, notConnected, connected, denied }
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: Color
        /// Ongoing, or starting within five minutes: offer "Start now".
        func isStartable(at now: Date) -> Bool { start.addingTimeInterval(-300) <= now && now < end }
    }
    struct Day: Identifiable {
        let date: Date
        let events: [Event]
        var id: Date { date }
    }

    /// Days per page; the arrows next to "Coming up" move by this many days.
    static let span = 3
    @Published private(set) var access: Access
    @Published private(set) var days: [Day] = []
    @Published private(set) var page = 0
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    /// E2E runs never read the calendar, so screenshots and results cannot capture real events.
    init(enabled: Bool) {
        guard enabled else { access = .disabledForE2E; return }
        access = Self.authorization()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private static func authorization() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .connected
        case .notDetermined: .notConnected
        default: .denied
        }
    }

    /// Shows the macOS calendar permission prompt; the user decides.
    func connect() async {
        guard access == .notConnected else { return }
        do { access = try await store.requestFullAccessToEvents() ? .connected : .denied }
        catch { access = .denied }
        reload()
    }

    func turnPage(_ delta: Int) {
        page = max(0, page + delta)
        reload()
    }

    func reload() {
        guard access == .connected else { days = []; return }
        let calendar = Calendar.current
        let now = Date()
        guard let start = calendar.date(byAdding: .day, value: page * Self.span, to: calendar.startOfDay(for: now)),
              let end = calendar.date(byAdding: .day, value: Self.span, to: start) else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        var grouped: [Date: [Event]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: max(event.startDate, start))
            grouped[day, default: []].append(Event(
                id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event",
                start: event.startDate, end: event.endDate,
                color: Color(nsColor: event.calendar?.color ?? .systemRed)))
        }
        // Today stays visible on the first page so the quick-note entry has a home.
        if page == 0 { grouped[calendar.startOfDay(for: now), default: []] += [] }
        days = grouped.keys.sorted().map { Day(date: $0, events: grouped[$0] ?? []) }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
