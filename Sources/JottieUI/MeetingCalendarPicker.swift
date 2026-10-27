import SwiftUI
import EventKit
import JottieModels

@MainActor public enum MeetingCalendarEvents {
    /// The caller requests access explicitly; a background reconciliation never raises a permission prompt.
    public static func events(for meeting: Meeting, selectedIDs: [String]) async throws -> [CalendarEventContext] {
        guard !selectedIDs.isEmpty else { throw JottieError.invalid("Choose your work calendar in Settings → Integrations and save it first.") }
        let store = EKEventStore()
        let allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess || EventKitCalendars.grantedDuringProcess
            ? true : try await store.requestFullAccessToEvents()
        guard allowed else { throw JottieError.unavailable("Calendar access was denied. Manage it in Settings → Recording.") }
        EventKitCalendars.grantedDuringProcess = true
        store.reset()
        let calendars = store.calendars(for: .event).filter { selectedIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { throw JottieError.invalid("The selected calendars are no longer available. Reload and reselect them in Integrations.") }
        let last = meeting.segments.map(\.endMS).max() ?? 0
        let end = meeting.startedAt.addingTimeInterval(max(60, Double(last) / 1000))
        let predicate = store.predicateForEvents(withStart: meeting.startedAt.addingTimeInterval(-1800), end: end.addingTimeInterval(1800), calendars: calendars)
        return store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }.prefix(50).map(context)
    }
    public static func context(_ event: EKEvent) -> CalendarEventContext {
        let people = (event.attendees ?? []) + (event.organizer.map { [$0] } ?? [])
        var seen = Set<String>()
        let invitees = people.compactMap { person -> String? in
            let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = person.url.scheme?.lowercased() == "mailto"
                ? String(person.url.absoluteString.dropFirst(7)).removingPercentEncoding : nil
            let value: String?
            if let name, !name.isEmpty { value = email.map { "\(name) <\($0)>" } ?? name }
            else { value = email }
            guard let value, !value.isEmpty, seen.insert((email ?? value).lowercased()).inserted else { return nil }
            return value
        }
        return CalendarEventContext(id: (event.eventIdentifier ?? "event") + ":" + String(event.startDate.timeIntervalSince1970),
            calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.source.title + " — " + event.calendar.title,
            title: event.title ?? "Meeting", start: event.startDate, end: event.endDate, invitees: invitees)
    }
}

@MainActor struct MeetingCalendarPicker: View {
    @ObservedObject var model: LibraryViewModel
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @ViewState private var events: [CalendarEventContext] = []
    @ViewState private var loading = true
    @ViewState private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose the meeting invitation").font(JottieStyle.font(22, .semibold))
            Text("Events near this recording from your selected calendars. Choose one invitation; attendee lists from simultaneous events are never combined.")
                .font(JottieStyle.font(13)).foregroundStyle(JottieStyle.muted)
            if loading { ProgressView() }
            if let message { Text(message).foregroundStyle(JottieStyle.muted).font(JottieStyle.font(13)) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(events) { event in
                        HStack {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(event.title).font(JottieStyle.font(14, .medium))
                                Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle) · \(event.invitees.count) invitees")
                                    .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
                            }
                            Spacer()
                            Button("Use event") { Task { await model.attachCalendar(event, to: meeting); dismiss() } }
                        }.padding(14).overlay { RoundedRectangle(cornerRadius: 10).stroke(JottieStyle.border, lineWidth: 1) }
                    }
                }
            }.frame(minHeight: 100, maxHeight: 350)
            Text("This updates context for this meeting. Existing analysis revisions stay unchanged until you regenerate. It does not split or rename any voice channel.")
                .font(JottieStyle.font(11)).foregroundStyle(JottieStyle.muted)
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }.padding(24).frame(width: 660).background(JottieStyle.background).foregroundStyle(JottieStyle.foreground)
            .buttonStyle(JottieButtonStyle(kind: .outline))
            .task {
                do {
                    let saved = try await model.store.settings()
                    events = try await MeetingCalendarEvents.events(for: meeting, selectedIDs: saved.selectedCalendarIDs)
                    if events.isEmpty { message = "No matching-time events in the selected calendars. Check that Integrations selects the Exchange calendar containing your invitations." }
                } catch { message = error.localizedDescription }
                loading = false
            }
    }
}
