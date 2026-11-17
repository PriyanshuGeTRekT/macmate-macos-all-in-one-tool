import AppKit
import SwiftUI

extension SelfTest {
    /// Hardware-independent checks for the Calendar tab. Never requests access or reads the user's calendars.
    static func runCalendarChecks() {
        print("== Calendar")
        let status = CalendarAccess.current
        check("calendar authorization readable", true, "\(status)")

        // Link extraction
        func link(_ url: String? = nil, location: String? = nil, notes: String? = nil) -> CalendarJoinLink? {
            CalendarLinks.joinLink(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
        }
        func expect(_ name: String, _ found: CalendarJoinLink?, _ service: CalendarJoinService?, _ prefix: String? = nil) {
            let ok = found?.service == service && (prefix.map { found?.url.absoluteString.hasPrefix($0) == true } ?? true)
            check("link: \(name)", ok, found.map { "\($0.service.rawValue) \($0.url.absoluteString)" } ?? "none")
        }
        expect("zoom in location", link(location: "https://us02web.zoom.us/j/81234567890?pwd=abc123"), .zoom, "https://us02web.zoom.us/j/81234567890?pwd=abc123")
        expect("zoom without scheme", link(location: "Zoom: zoom.us/j/5551234567."), .zoom, "https://zoom.us/j/5551234567")
        expect("zoom vanity room", link(notes: "Room: https://acme.zoom.us/my/jane.doe"), .zoom)
        expect("zoom download page ignored", link(notes: "Get the app at https://zoom.us/download"), nil)
        expect("google meet", link(notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij\nJoin by phone: tel:+1-555-0100,,123#\nhttps://tel.meet/abc-defg-hij?pin=1234"),
               .meet, "https://meet.google.com/abc-defg-hij")
        expect("google redirect", link(notes: "<a href=\"https://www.google.com/url?q=https://meet.google.com/xyz-abcd-efg&amp;sa=D&amp;ust=1\">Join</a>"),
               .meet, "https://meet.google.com/xyz-abcd-efg")
        let teamsHTML = """
        <html><body><div>________________________________________________________________________________</div>
        <div><span style="font-size:24px">Microsoft Teams meeting</span></div>
        <div><a href="https://aka.ms/JoinTeamsMeeting" target="_blank">Learn more</a></div>
        <div><a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjE5ZTk%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22a1%22%7d&amp;btype=a&amp;role=a" target="_blank">Join the meeting now</a></div>
        <div>Meeting ID: 123 456 789 0</div>
        <a href="https://teams.microsoft.com/meetingOptions/?organizerId=a1&amp;tenantId=72f988bf">Meeting options</a>
        <a href="mailto:jane@example.com">jane@example.com</a></body></html>
        """
        expect("teams in html notes", link(notes: teamsHTML), .teams, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjE5ZTk%40thread.v2/0?context=")
        check("html entities decoded in link", link(notes: teamsHTML)?.url.absoluteString.contains("&btype=a&role=a") == true)
        expect("teams safelink", link(notes: "Join: https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_ABC%2540thread.v2%2F0%3Fcontext%3D%257b%2522Tid%2522%253a%2522x%2522%257d&data=05%7C02%7C&sdata=abc%3D&reserved=0"),
               .teams, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0")
        expect("teams new meet link", link(location: "Microsoft Teams Meeting", notes: "Join: https://teams.microsoft.com/meet/2539812345678?p=AbCdEf"), .teams)
        expect("teams help and options only", link(notes: "https://aka.ms/JoinTeamsMeeting https://teams.microsoft.com/meetingOptions/?x=1"), nil)
        expect("urldefense wrapper", link(notes: "https://urldefense.com/v3/__https://acme.zoom.us/j/9988776655__;!!abc$"), .zoom, "https://acme.zoom.us/j/9988776655")
        expect("webex personal room", link("https://acme.webex.com/meet/jdoe"), .webex)
        expect("webex j.php", link(notes: "https://acme.webex.com/acme/j.php?MTID=m1234"), .webex)
        expect("facetime", link(notes: "FaceTime: https://facetime.apple.com/join#v=1&p=AbCdEfGh&k=XyZ"), .facetime)
        expect("slack huddle", link(notes: "Huddle: https://app.slack.com/huddle/T0123ABC/C0456DEF"), .slack)
        expect("whereby", link(location: "https://whereby.com/team-sync"), .whereby)
        expect("whereby marketing page ignored", link(notes: "https://whereby.com/information/pricing"), nil)
        expect("goto meeting", link(notes: "Please join from your computer: https://global.gotomeeting.com/join/123456789"), .goto)
        expect("goto new domain", link(notes: "https://meet.goto.com/123456789"), .goto)
        expect("around", link(notes: "https://meet.around.co/r/design-crit"), .around)
        expect("meeting link preferred over others",
               link("https://docs.example.com/agenda", location: "Room 4", notes: "Slides: https://example.com/deck.pdf\nCall: https://zoom.us/j/111222333 (passcode 9)"),
               .zoom, "https://zoom.us/j/111222333")
        expect("event url wins over notes", link("https://meet.google.com/aaa-bbbb-ccc", notes: "https://zoom.us/j/1"), .meet)
        expect("mailto and tel ignored", link(notes: "mailto:host@zoom.us tel:+15550100 host@zoom.us"), nil)
        expect("markdown link", link(notes: "[Join](https://zoom.us/j/444555666)."), .zoom, "https://zoom.us/j/444555666")
        expect("zoom app scheme", link(location: "zoommtg://zoom.us/join?confno=123"), .zoom)
        expect("plain text", link(location: "Conference room B", notes: "Bring snacks"), nil)
        let zoomApp = CalendarJoinLink(url: URL(string: "https://acme.zoom.us/j/81234567890?pwd=abc")!, service: .zoom).appURL?.absoluteString
        check("zoom app link", zoomApp == "zoommtg://acme.zoom.us/join?action=join&confno=81234567890&pwd=abc", zoomApp ?? "nil")
        check("location keeps place, drops link", CalendarMeeting(title: "x", start: Date(), end: Date(), location: "Room 4 / https://zoom.us/j/1").displayLocation == "Room 4")
        check("bare service name hidden", CalendarMeeting(title: "x", start: Date(), end: Date(), location: "Microsoft Teams Meeting").displayLocation == nil)

        // Relative times and the menu bar
        let cal = Calendar.current
        let base = cal.date(bySettingHour: 10, minute: 48, second: 1, of: cal.date(from: DateComponents(year: 2026, month: 3, day: 10))!)!
        func meeting(_ title: String, _ startMin: Double, _ minutes: Double, allDay: Bool = false) -> CalendarMeeting {
            let s = base.addingTimeInterval(startMin * 60)
            return CalendarMeeting(id: title, title: title, start: s, end: s.addingTimeInterval(minutes * 60), isAllDay: allDay)
        }
        func rel(_ m: CalendarMeeting) -> String { CalendarAgenda.relative(m, now: base) }
        check("relative in 12 min", rel(meeting("a", 12, 30)) == "in 12 min", rel(meeting("a", 12, 30)))
        check("relative rounds up", rel(meeting("a", 11.5, 30)) == "in 12 min")
        check("relative hours", rel(meeting("a", 80, 30)) == "in 1 hr 20 min" && rel(meeting("a", 120, 30)) == "in 2 hr", rel(meeting("a", 80, 30)))
        check("relative now at start", rel(meeting("a", 0.5, 30)) == "now" && rel(meeting("a", -2, 30)) == "now")
        check("relative ends in", rel(meeting("a", -25, 30)) == "ends in 5 min", rel(meeting("a", -25, 30)))
        check("relative ended", rel(meeting("a", -60, 30)) == "ended")
        check("relative tomorrow", rel(meeting("a", 24 * 60, 30)) == "tomorrow")

        func bar(_ list: [CalendarMeeting], on: Bool = true) -> String? { CalendarAgenda.menuBarText(list, now: base, enabled: on) }
        check("menu bar soon", bar([meeting("Standup", 12, 15)]) == "Standup in 12m", bar([meeting("Standup", 12, 15)]) ?? "nil")
        check("menu bar off", bar([meeting("Standup", 12, 15)], on: false) == nil)
        check("menu bar nothing within the hour", bar([meeting("Later", 61, 15)]) == nil && bar([meeting("Hour", 60, 15)]) == "Hour in 60m")
        check("menu bar in progress", bar([meeting("Standup", -10, 30)]) == "Now: Standup")
        check("menu bar starting", bar([meeting("Standup", 0.5, 30)]) == "Standup now")
        check("menu bar back to back", bar([meeting("First", -50, 60), meeting("Second", 8, 30)]) == "Second in 8m")
        check("menu bar ignores all-day", bar([meeting("Holiday", -600, 1440, allDay: true)]) == nil)
        let long = bar([meeting("Quarterly business review with finance", 5, 30)]) ?? ""
        check("menu bar truncates title", long == "Quarterly busines… in 5m", long)

        // Grouping
        let startToday = cal.startOfDay(for: base)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: startToday)!
        let sample = [
            meeting("late", 300, 30), meeting("past", -90, 30), meeting("early", -200, 15),
            CalendarMeeting(id: "allday", title: "Holiday", start: startToday, end: tomorrow.addingTimeInterval(-1), isAllDay: true),
            CalendarMeeting(id: "t1", title: "Tomorrow 2", start: tomorrow.addingTimeInterval(14 * 3600), end: tomorrow.addingTimeInterval(15 * 3600)),
            CalendarMeeting(id: "t0", title: "Tomorrow 1", start: tomorrow.addingTimeInterval(9 * 3600), end: tomorrow.addingTimeInterval(10 * 3600)),
            CalendarMeeting(id: "trip", title: "Trip", start: startToday, end: cal.date(byAdding: .day, value: 2, to: startToday)!.addingTimeInterval(-1), isAllDay: true),
            CalendarMeeting(id: "yesterday", title: "Old", start: startToday.addingTimeInterval(-7200), end: startToday.addingTimeInterval(-3600)),
        ]
        let days = CalendarAgenda.days(sample, now: base)
        check("today grouped and sorted", days.today.map(\.id) == ["allday", "trip", "early", "past", "late"], days.today.map(\.id).joined(separator: ","))
        check("tomorrow grouped and sorted", days.tomorrow.map(\.id) == ["trip", "t0", "t1"], days.tomorrow.map(\.id).joined(separator: ","))
        check("past events marked", meeting("past", -90, 30).isPast(at: base) && !meeting("late", 300, 30).isPast(at: base))
        check("next up skips past and all-day", CalendarAgenda.nextUp(sample, now: base)?.id == "late")
        check("next up reaches tomorrow", CalendarAgenda.nextUp(Array(sample.filter { $0.id.hasPrefix("t") }), now: base)?.id == "t0")

        // Alerts and timer
        let due = CalendarAgenda.dueAlerts([meeting("a", 5, 30), meeting("b", 6, 30), meeting("c", -2, 30), meeting("x", 3, 30, allDay: true)],
                                           now: base, minutesBefore: 5, alreadyAlerted: [])
        check("alerts due within window", due.map(\.id) == ["a"], due.map(\.id).joined(separator: ","))
        check("alerts only once", CalendarAgenda.dueAlerts([meeting("a", 5, 30)], now: base, minutesBefore: 5, alreadyAlerted: ["a"]).isEmpty)
        check("alerts off", CalendarAgenda.dueAlerts([meeting("a", 1, 30)], now: base, minutesBefore: 0, alreadyAlerted: []).isEmpty)
        check("timer idle when nothing needs it", !CalendarAgenda.timerNeeded(access: .granted, menuBar: false, alertMinutes: 0, panelOpen: false)
              && !CalendarAgenda.timerNeeded(access: .denied, menuBar: true, alertMinutes: 5, panelOpen: true)
              && CalendarAgenda.timerNeeded(access: .granted, menuBar: false, alertMinutes: 0, panelOpen: true))

        // Sample day used for renders
        let demoNow = CalendarSample.referenceNow()
        let demo = CalendarSample.meetings(around: demoNow)
        let demoDays = CalendarAgenda.days(demo, now: demoNow)
        check("sample day shape", demoDays.today.first?.isAllDay == true && demoDays.tomorrow.count == 2
              && CalendarAgenda.nextUp(demo, now: demoNow)?.joinLink?.service == .zoom,
              "\(demoDays.today.count) today, \(demoDays.tomorrow.count) tomorrow")
        check("sample menu bar text", CalendarAgenda.menuBarText(demo, now: demoNow, enabled: true) == "Design review… in 12m",
              CalendarAgenda.menuBarText(demo, now: demoNow, enabled: true) ?? "nil")
    }
}

extension Snapshot {
    /// Renders the Calendar tab with the sample day, then the before-access and denied states.
    static func renderCalendar(directory: String) {
        active = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        CalendarService.registerDefaults()
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 400, height: 620)
        CalendarService.shared.loadDemo(access: .granted)
        render(CalendarTab().formStyle(.grouped).background(.regularMaterial), size: size, to: "\(directory)/calendar-1.png")
        CalendarService.shared.loadDemo(access: .notDetermined)
        render(CalendarTab().formStyle(.grouped).background(.regularMaterial), size: size, to: "\(directory)/calendar-2.png")
        CalendarService.shared.loadDemo(access: .denied)
        render(CalendarTab().formStyle(.grouped).background(.regularMaterial), size: size, to: "\(directory)/calendar-3.png")
    }
}
