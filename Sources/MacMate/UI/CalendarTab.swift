import SwiftUI

struct CalendarTab: View {
    @ObservedObject private var service = CalendarService.shared
    @AppStorage(Keys.calendarMenuBar) private var showInMenuBar = false
    @AppStorage(Keys.calendarAlertMinutes) private var alertMinutes = 0
    @ViewState private var showCalendars = false

    var body: some View {
        Form {
            switch service.access {
            case .granted:
                nextUpSection
                daySection("Today", service.agenda.today, date: service.now, empty: "No events today")
                daySection("Tomorrow", service.agenda.tomorrow, date: service.now.addingTimeInterval(86_400), empty: "No events tomorrow")
                optionsSection
            case .notDetermined:
                welcomeSection
            default:
                deniedSection
            }
        }
        .onAppear { service.tabAppeared() }
    }

    // MARK: Before access

    private var welcomeSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.red)
                    .padding(.bottom, 2)
                Text("Your day at a glance")
                    .font(.title3.weight(.semibold))
                Text("See today's and tomorrow's events, a countdown to your next meeting, and join video calls in one click. Your calendar stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Calendar Access") { service.requestAccess() }
                    .prominentGlassButton()
                    .controlSize(.large)
                    .padding(.top, 4)
                if let problem = service.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private var deniedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(service.access == .writeOnly ? "Full calendar access needed" : "Calendar access is off",
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.headline)
                Text(deniedReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security Settings") { CalendarService.openPrivacySettings() }
            }
            .padding(.vertical, 2)
        }
    }

    private var deniedReason: String {
        switch service.access {
        case .writeOnly: return "MacMate can add events but not read them. Choose Full Access for MacMate in Privacy & Security › Calendars to see your agenda here."
        case .restricted: return "Calendar access is restricted on this Mac, possibly by a configuration profile."
        default: return "Turn on MacMate in Privacy & Security › Calendars to see your agenda and join meetings from here."
        }
    }

    // MARK: Agenda

    @ViewBuilder private var nextUpSection: some View {
        Section {
            if let next = service.nextUp {
                CalendarNextUpCard(meeting: next, now: service.now)
            } else {
                Label("Nothing else on your calendar today or tomorrow.", systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        } header: {
            Text(service.nextUp?.isInProgress(at: service.now) == true ? "Now" : "Next Up")
        }
    }

    private func daySection(_ title: String, _ events: [CalendarMeeting], date: Date, empty: String) -> some View {
        Section {
            if events.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    CalendarEventRow(meeting: event, now: service.now)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section {
            Toggle("Show next meeting in the menu bar", isOn: $showInMenuBar)
                .onChange(of: showInMenuBar) { _, _ in service.settingsChanged() }
            Picker("Alert before meetings", selection: $alertMinutes) {
                Text("Off").tag(0)
                ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            .onChange(of: alertMinutes) { _, _ in service.settingsChanged() }
            DisclosureGroup(isExpanded: $showCalendars) {
                ForEach(service.calendars) { cal in
                    Toggle(isOn: Binding(get: { !service.excludedCalendarIDs.contains(cal.id) },
                                         set: { service.setIncluded(cal.id, $0) })) {
                        HStack(spacing: 8) {
                            Circle().fill(cal.color).frame(width: 9, height: 9)
                            Text(cal.title).lineLimit(1)
                            Spacer()
                            if !cal.source.isEmpty {
                                Text(cal.source).font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } label: {
                LabeledContent("Calendars") {
                    Text(calendarSummary).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("The menu bar shows meetings starting within the hour. Alerts include the meeting's join link.")
        }
    }

    private var calendarSummary: String {
        let total = service.calendars.count
        let shown = service.calendars.filter { !service.excludedCalendarIDs.contains($0.id) }.count
        if total == 0 || shown == total { return "All" }
        return shown == 0 ? "None" : "\(shown) of \(total)"
    }
}

// MARK: - Pieces

/// The large card for the current or next meeting.
private struct CalendarNextUpCard: View {
    let meeting: CalendarMeeting
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(meeting.color).frame(width: 8, height: 8)
                Text(relative)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(urgency)
                    .monospacedDigit()
                Spacer()
                Text(meeting.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(CalendarAgenda.timeRange(meeting))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let place = meeting.displayLocation {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let link = meeting.joinLink {
                Button { link.open() } label: {
                    Label("Join \(link.service.shortName)", systemImage: link.service.symbol)
                        .frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                .controlSize(.large)
                .help(link.url.absoluteString)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { CalendarEventMenu(meeting: meeting) }
    }

    private var relative: String {
        let text = CalendarAgenda.relative(meeting, now: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var urgency: Color {
        if meeting.isInProgress(at: now) || meeting.start.timeIntervalSince(now) < 60 { return .red }
        return meeting.start.timeIntervalSince(now) <= 15 * 60 ? .orange : .secondary
    }
}

private struct CalendarEventRow: View {
    let meeting: CalendarMeeting
    let now: Date

    var body: some View {
        let past = meeting.isPast(at: now)
        HStack(spacing: 10) {
            Capsule()
                .fill(meeting.color)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let link = meeting.joinLink, !past {
                Button("Join") { link.open() }
                    .glassButton()
                    .controlSize(.small)
                    .help("Join \(link.service.name)")
            } else if meeting.isInProgress(at: now), !meeting.isAllDay {
                Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
        }
        .opacity(past ? 0.45 : 1)
        .contentShape(Rectangle())
        .contextMenu { CalendarEventMenu(meeting: meeting) }
    }

    private var detail: String {
        var parts = [CalendarAgenda.timeRange(meeting)]
        if let place = meeting.displayLocation { parts.append(place) } else if let link = meeting.joinLink { parts.append(link.service.name) }
        return parts.joined(separator: " · ")
    }
}

private struct CalendarEventMenu: View {
    let meeting: CalendarMeeting

    var body: some View {
        Button("Open in Calendar") { meeting.open() }
        if let link = meeting.joinLink {
            Button("Join \(link.service.name)") { link.open() }
            Button("Copy Meeting Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }
}
