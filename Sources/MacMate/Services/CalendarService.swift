import AppKit
import Combine
import EventKit
import SwiftUI

extension Keys {
    static let calendarMenuBar = "calendar.menuBar"
    static let calendarAlertMinutes = "calendar.alertMinutes"
    static let calendarExcluded = "calendar.excludedCalendars"
    static let calendarAlerted = "calendar.alertedEvents"
}

// MARK: - Model

/// Where calendar access stands. Read with `EKEventStore.authorizationStatus` only, which never prompts.
enum CalendarAccess: Equatable {
    case notDetermined, granted, denied, restricted, writeOnly

    static var current: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

/// The video-call services a join link can belong to.
enum CalendarJoinService: String, CaseIterable {
    case zoom, meet, teams, webex, facetime, slack, whereby, goto, around

    var name: String {
        switch self {
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .facetime: return "FaceTime"
        case .slack: return "Slack Huddle"
        case .whereby: return "Whereby"
        case .goto: return "GoTo Meeting"
        case .around: return "Around"
        }
    }

    /// Used on buttons: "Join Teams", "Join Zoom".
    var shortName: String {
        switch self {
        case .teams: return "Teams"
        case .slack: return "Huddle"
        default: return name
        }
    }

    var symbol: String { self == .slack ? "headphones" : "video.fill" }

    /// Recognises a meeting link by host and path, so help pages and options links on the same domains don't count.
    static func match(_ url: URL) -> CalendarJoinService? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "zoommtg" || scheme == "zoomus" { return .zoom }
        if scheme == "msteams" { return .teams }
        if scheme == "facetime" { return .facetime }
        guard scheme == "https" || scheme == "http",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased() else { return nil }
        let urlPath = comps.percentEncodedPath
        func on(_ domains: String...) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        func path(_ pattern: String) -> Bool { urlPath.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }

        if on("zoom.us", "zoom.com", "zoomgov.com") { return path("^/(j|s|w|my)/[^/]+|^/wc/(join/)?[0-9]+") ? .zoom : nil }
        if host == "meet.google.com" { return path("^/([a-z]{3,4}-[a-z]{4}-[a-z]{3}|lookup/[^/]+|_meet/[^/]+)") ? .meet : nil }
        if on("teams.microsoft.com", "teams.live.com", "teams.microsoft.us", "teams.cloud.microsoft") {
            if path("^/(l/meetup-join|l/meet|meet)/") { return .teams }
            if path("^/v2/?$"), comps.query?.lowercased().contains("meetingjoin=true") == true { return .teams }
            return nil
        }
        if on("webex.com") { return path("/(meet|join)/|/j\\.php|/wbxmjs/joinservice|/webappng/sites/.+/meeting/") ? .webex : nil }
        if host == "facetime.apple.com" { return path("^/join") ? .facetime : nil }
        if on("slack.com") { return path("^/huddle/") ? .slack : nil }
        if on("whereby.com") {
            let reserved = ["information", "user", "org", "blog", "pricing", "login", "signup", "support", "legal", "embed", "api"]
            guard path("^/[a-z0-9_-]+/?$") else { return nil }
            let room = urlPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            return reserved.contains(room) ? nil : .whereby
        }
        if on("gotomeeting.com") { return path("^/join/[0-9]+") ? .goto : nil }
        if host == "meet.goto.com" || host == "gotomeet.me" { return path("^/[a-z0-9_-]+") ? .goto : nil }
        if host == "app.goto.com" { return path("^/meeting/[0-9]+") ? .goto : nil }
        if on("around.co") { return path("^/r/[^/]+") ? .around : nil }
        return nil
    }
}

struct CalendarJoinLink: Equatable {
    let url: URL
    let service: CalendarJoinService

    /// The same meeting as an app link (Zoom, Teams), so it skips the browser hop when the app is installed.
    var appURL: URL? {
        switch service {
        case .zoom:
            guard url.scheme?.hasPrefix("http") == true, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = comps.host,
                  let match = comps.path.range(of: "^/(j|w|s)/[0-9]+", options: .regularExpression) else { return nil }
            let confno = comps.path[match].split(separator: "/").last.map(String.init) ?? ""
            var out = URLComponents()
            out.scheme = "zoommtg"
            out.host = host
            out.path = "/join"
            out.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: confno)]
                + (comps.queryItems?.filter { $0.name == "pwd" } ?? [])
            return out.url
        case .teams:
            guard url.scheme?.hasPrefix("http") == true, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            comps.scheme = "msteams"
            return comps.url
        default:
            return nil
        }
    }

    func open() {
        if let app = appURL, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One event, independent of EventKit, so the interface and the checks can run on sample data.
struct CalendarMeeting: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarID: String
    var calendarTitle: String
    var color: Color
    var joinLink: CalendarJoinLink?
    /// Shows the event in Calendar.
    var calendarURL: URL?

    init(id: String = UUID().uuidString, title: String, start: Date, end: Date, isAllDay: Bool = false,
         location: String? = nil, url: URL? = nil, notes: String? = nil,
         calendarID: String = "", calendarTitle: String = "", color: Color = .accentColor, calendarURL: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.isAllDay = isAllDay
        self.location = location
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.color = color
        self.calendarURL = calendarURL
        joinLink = CalendarLinks.joinLink(url: url, location: location, notes: notes)
    }

    func isPast(at now: Date) -> Bool { end <= now }
    func isInProgress(at now: Date) -> Bool { start <= now && now < end }

    /// The location as people wrote it, minus any links (those become the Join button).
    var displayLocation: String? {
        guard let location else { return nil }
        let text = CalendarLinks.removingLinks(from: location)
        return text.isEmpty ? nil : text
    }

    func open() {
        if let calendarURL, NSWorkspace.shared.open(calendarURL) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

extension CalendarMeeting {
    /// Copies what the panel needs out of an EventKit event. Cancelled and declined events are left out.
    init?(event: EKEvent) {
        guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return nil }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let calendar = event.calendar
        self.init(id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
                  title: title.isEmpty ? "Untitled" : title,
                  start: start, end: end, isAllDay: event.isAllDay,
                  location: event.location, url: event.url, notes: event.notes.map { String($0.prefix(60_000)) },
                  calendarID: calendar?.calendarIdentifier ?? "",
                  calendarTitle: calendar?.title ?? "",
                  color: calendar.map { Color(nsColor: $0.color) } ?? .accentColor,
                  calendarURL: CalendarLinks.calendarAppURL(eventID: event.eventIdentifier, start: start,
                                                            recurring: event.hasRecurrenceRules))
    }
}

struct CalendarChoice: Identifiable, Equatable {
    let id: String
    var title: String
    var source: String
    var color: Color
}

// MARK: - Link extraction

enum CalendarLinks {
    /// The first video-call link in the event URL, then the location, then the notes. Other links are skipped.
    static func joinLink(url: URL?, location: String?, notes: String?) -> CalendarJoinLink? {
        for text in [url?.absoluteString, location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let link = firstMeetingLink(in: text) { return link }
        }
        return nil
    }

    static func firstMeetingLink(in text: String) -> CalendarJoinLink? {
        for candidate in candidates(in: text) {
            if let service = CalendarJoinService.match(candidate) { return CalendarJoinLink(url: candidate, service: service) }
        }
        return nil
    }

    private static let schemeLink = try! NSRegularExpression(
        pattern: "\\b(?:https?|zoommtg|zoomus|msteams)://[^\\s<>\"'`{}|\\\\^\\[\\]]+", options: [.caseInsensitive])
    /// Links typed without a scheme, e.g. "zoom.us/j/123" in a location field. Not after "@" (e-mail) or "/" (already matched).
    private static let bareLink = try! NSRegularExpression(
        pattern: "(?<![\\w./@:-])(?:[a-z0-9-]+\\.)*(?:zoom\\.us|zoomgov\\.com|meet\\.google\\.com|teams\\.microsoft\\.com|teams\\.live\\.com|webex\\.com|facetime\\.apple\\.com|whereby\\.com|gotomeeting\\.com|meet\\.goto\\.com|around\\.co)/[^\\s<>\"'`{}|\\\\^\\[\\]]+",
        options: [.caseInsensitive])
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#x[0-9a-f]+|amp|quot|apos|lt|gt|nbsp);", options: [.caseInsensitive])

    /// Every link in the text, in order, with redirect wrappers (Outlook safelinks, Google, urldefense) removed.
    static func candidates(in raw: String) -> [URL] {
        let text = decodeEntities(raw)
        let range = NSRange(text.startIndex..., in: text)
        var found: [(Int, String)] = []
        for m in schemeLink.matches(in: text, range: range) {
            if let r = Range(m.range, in: text) { found.append((m.range.location, String(text[r]))) }
        }
        for m in bareLink.matches(in: text, range: range) {
            if let r = Range(m.range, in: text) { found.append((m.range.location, "https://" + text[r])) }
        }
        var seen = Set<String>()
        return found.sorted { $0.0 < $1.0 }.compactMap { _, string in
            guard let url = URL(string: trimTrailing(string)).map({ unwrap($0) }), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    /// Follows link-protection redirects to the address they wrap.
    static func unwrap(_ url: URL, depth: Int = 0) -> URL {
        guard depth < 4, CalendarJoinService.match(url) == nil else { return url }
        let s = url.absoluteString
        // Proofpoint v3: https://urldefense.com/v3/__https://zoom.us/j/1__;!!abc
        if s.contains("urldefense.com/v3/__"), let a = s.range(of: "/v3/__"), let b = s.range(of: "__;", range: a.upperBound..<s.endIndex),
           let inner = URL(string: String(s[a.upperBound..<b.lowerBound])) {
            return unwrap(inner, depth: depth + 1)
        }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return url }
        for name in ["url", "q", "u", "target", "dest", "destination", "redirect"] {
            if let value = items.first(where: { $0.name.lowercased() == name })?.value,
               value.lowercased().hasPrefix("http"), let inner = URL(string: trimTrailing(value)) {
                return unwrap(inner, depth: depth + 1)
            }
        }
        return url
    }

    static func removingLinks(from text: String) -> String {
        var out = text
        for regex in [schemeLink, bareLink] {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—|/()<>"))
        out = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: junk) }.filter { !$0.isEmpty }.joined(separator: ", ")
        // A bare service name ("Zoom", "Microsoft Teams Meeting") adds nothing next to the Join button.
        let lower = out.lowercased()
        if CalendarJoinService.allCases.contains(where: { lower == $0.name.lowercased() || lower == $0.name.lowercased() + " meeting" }) { return "" }
        return out
    }

    private static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let last = s.last, ".,;:!?)>'\"*".contains(last) { s = s.dropLast() }
        return String(s)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            switch name {
            case "amp": out += "&"
            case "quot": out += "\""
            case "apos": out += "'"
            case "lt": out += "<"
            case "gt": out += ">"
            case "nbsp": out += " "
            default:
                let digits = name.dropFirst()
                let code = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let code, let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Calendar's own link for showing an event. Repeating events also need the occurrence's start time.
    static func calendarAppURL(eventID: String?, start: Date, recurring: Bool) -> URL? {
        guard let eventID, let id = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        if recurring {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return URL(string: "ical://ekevent/\(f.string(from: start))/\(id)?method=show&options=more")
        }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
    }
}

// MARK: - Agenda rules

enum CalendarAgenda {
    /// All-day events first, then by start time.
    static func sorted(_ list: [CalendarMeeting]) -> [CalendarMeeting] {
        list.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    static func days(_ meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current) -> (today: [CalendarMeeting], tomorrow: [CalendarMeeting]) {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let after = calendar.date(byAdding: .day, value: 2, to: today) else { return ([], []) }
        func on(_ m: CalendarMeeting, _ from: Date, _ to: Date) -> Bool {
            m.start < to && (m.end > from || (m.end == m.start && m.start >= from))
        }
        return (sorted(meetings.filter { on($0, today, tomorrow) }), sorted(meetings.filter { on($0, tomorrow, after) }))
    }

    /// The meeting to show first: one starting within 10 minutes beats one already running (back-to-back
    /// meetings), then the most recently started one in progress, then the next one today or tomorrow.
    static func nextUp(_ meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current) -> CalendarMeeting? {
        let limit = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(172_800)
        let timed = meetings.filter { !$0.isAllDay && $0.end > now && $0.start < limit }
        let upcoming = timed.filter { $0.start > now }.sorted { $0.start < $1.start }
        let running = timed.filter { $0.isInProgress(at: now) }.sorted { $0.start > $1.start }
        if let soon = upcoming.first, soon.start.timeIntervalSince(now) <= 600 { return soon }
        return running.first ?? upcoming.first
    }

    static func minutes(_ seconds: TimeInterval) -> Int { max(0, Int((seconds / 60).rounded(.up))) }

    static func span(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// "in 12 min", "now" (started in the last 5 minutes), "ends in 5 min", "tomorrow".
    static func relative(_ m: CalendarMeeting, now: Date, calendar: Calendar = .current) -> String {
        if m.isAllDay { return "all day" }
        if m.end <= now { return "ended" }
        if m.start <= now {
            if now.timeIntervalSince(m.start) < 300 { return "now" }
            return "ends in " + span(minutes(m.end.timeIntervalSince(now)))
        }
        let wait = m.start.timeIntervalSince(now)
        if wait < 60 { return "now" }
        if !calendar.isDate(m.start, inSameDayAs: now) {
            return calendar.isDate(m.start, inSameDayAs: now.addingTimeInterval(86_400)) && wait > 3 * 3600 ? "tomorrow" : "in " + span(minutes(wait))
        }
        return "in " + span(minutes(wait))
    }

    static func shortTitle(_ title: String, limit: Int = 18) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        var cut = String(t.prefix(limit - 1))
        // Break at a word when one ends close to the limit: "Design review…", not "Design review: me…".
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 6 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":,;-–—·"))) + "…"
    }

    /// "Standup in 12m", "Standup now", "Now: Standup"; nil when switched off or nothing starts within the hour.
    static func menuBarText(_ meetings: [CalendarMeeting], now: Date, enabled: Bool) -> String? {
        guard enabled, let m = nextUp(meetings, now: now) else { return nil }
        let title = shortTitle(m.title)
        if m.isInProgress(at: now) { return "Now: \(title)" }
        let wait = m.start.timeIntervalSince(now)
        if wait < 60 { return "\(title) now" }
        let mins = minutes(wait)
        return mins <= 60 ? "\(title) in \(mins)m" : nil
    }

    /// Timed meetings whose alert is due and hasn't been shown yet.
    static func dueAlerts(_ meetings: [CalendarMeeting], now: Date, minutesBefore: Int, alreadyAlerted: Set<String>) -> [CalendarMeeting] {
        guard minutesBefore > 0 else { return [] }
        return meetings.filter { m in
            !m.isAllDay && !alreadyAlerted.contains(m.id)
                && m.start.timeIntervalSince(now) <= Double(minutesBefore * 60)
                && m.start.timeIntervalSince(now) > -60
        }
    }

    /// The minute timer only runs while something shows or acts on the time.
    static func timerNeeded(access: CalendarAccess, menuBar: Bool, alertMinutes: Int, panelOpen: Bool) -> Bool {
        access == .granted && (menuBar || alertMinutes > 0 || panelOpen)
    }

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func timeRange(_ m: CalendarMeeting) -> String {
        m.isAllDay ? "All day" : rangeFormatter.string(from: m.start, to: m.end)
    }
}

// MARK: - Service

/// Today's and tomorrow's events from EventKit, the next meeting, menu bar text and meeting alerts.
/// Nothing touches the calendar database until the user grants access from the Calendar tab.
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published private(set) var access: CalendarAccess = .notDetermined
    /// Events overlapping today and tomorrow, from every calendar.
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var calendars: [CalendarChoice] = []
    /// Advanced once a minute while the timer runs, so relative times stay current.
    @Published private(set) var now = Date()
    /// What the menu bar should show for the next meeting, or nil. Observe `$menuBarText` to refresh the title.
    @Published private(set) var menuBarText: String?
    @Published private(set) var problem: String?
    @Published var excludedCalendarIDs: Set<String> {
        didSet {
            guard excludedCalendarIDs != oldValue else { return }
            UserDefaults.standard.set(Array(excludedCalendarIDs).sorted(), forKey: Keys.calendarExcluded)
            tick()
        }
    }

    var visibleMeetings: [CalendarMeeting] { meetings.filter { !excludedCalendarIDs.contains($0.calendarID) } }
    var nextUp: CalendarMeeting? { CalendarAgenda.nextUp(visibleMeetings, now: now) }
    var agenda: (today: [CalendarMeeting], tomorrow: [CalendarMeeting]) { CalendarAgenda.days(visibleMeetings, now: now) }

    private var store: EKEventStore?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var storeObserver: NSObjectProtocol?
    private var panelSub: AnyCancellable?
    private var panelIsOpen = false
    private var started = false
    private var generation = 0
    private var fetchedDay: Date?
    private var refreshWork: DispatchWorkItem?
    private var alerted: Set<String>
    private var isDemo = false
    private var clockOverride: Date?

    init() {
        let d = UserDefaults.standard
        excludedCalendarIDs = Set(d.stringArray(forKey: Keys.calendarExcluded) ?? [])
        alerted = Set(d.stringArray(forKey: Keys.calendarAlerted) ?? [])
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.calendarMenuBar: false,
            Keys.calendarAlertMinutes: 0,
        ])
    }

    /// Call once at launch. Reads the authorization status only; fetches events if access was granted earlier.
    func start() {
        guard !started else { return }
        started = true
        CalendarService.registerDefaults()
        access = CalendarAccess.current
        panelSub = AppState.shared.$panelOpen.sink { [weak self] open in
            DispatchQueue.main.async { self?.panelChanged(open) }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(nc.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restartTimer()
            self?.refresh()
        })
        if access == .granted { attachStore(); refresh() }
        updateTimer()
    }

    /// Asks for full calendar access. Only ever called from the "Allow Calendar Access" button.
    func requestAccess() {
        guard !isDemo else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
            problem = "This copy of MacMate can't ask for calendar access. Use the MacMate app from the Applications folder."
            return
        }
        let store = self.store ?? EKEventStore()
        self.store = store
        store.requestFullAccessToEvents { [weak self] _, _ in
            onMain {
                guard let self else { return }
                self.access = CalendarAccess.current
                if self.access == .granted { self.attachStore(); self.refresh() }
                self.updateTimer()
            }
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The tab calls this when it appears; picks up a grant made in System Settings meanwhile.
    func tabAppeared() {
        if isDemo { tick(); return }
        let current = CalendarAccess.current
        if current != access { access = current }
        if access == .granted {
            attachStore()
            if fetchedDay == nil || fetchedDay != Calendar.current.startOfDay(for: Date()) { refresh() }
        }
        tick()
        updateTimer()
    }

    /// Call after changing the menu bar or alert setting.
    func settingsChanged() {
        updateTimer()
        tick()
    }

    func setIncluded(_ id: String, _ included: Bool) {
        if included { excludedCalendarIDs.remove(id) } else { excludedCalendarIDs.insert(id) }
    }

    // MARK: Fetching

    private func attachStore() {
        let store = self.store ?? EKEventStore()
        self.store = store
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    /// Coalesces the bursts of change notifications a sync produces.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refresh() {
        guard !isDemo else { tick(); return }
        guard access == .granted, let store else { meetings = []; tick(); return }
        generation += 1
        let gen = generation
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: day) else { return }
        inBackground {
            let all = store.calendars(for: .event)
            let choices = all.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: Color(nsColor: $0.color)) }
                .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
            let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
            let found = store.events(matching: predicate).compactMap(CalendarMeeting.init(event:))
            onMain {
                guard gen == self.generation else { return }
                self.fetchedDay = day
                if choices != self.calendars { self.calendars = choices }
                if found != self.meetings { self.meetings = found }
                self.tick()
            }
        }
    }

    // MARK: Clock

    private func updateTimer() {
        let d = UserDefaults.standard
        let needed = !isDemo && CalendarAgenda.timerNeeded(access: access, menuBar: d.bool(forKey: Keys.calendarMenuBar),
                                                           alertMinutes: d.integer(forKey: Keys.calendarAlertMinutes), panelOpen: panelIsOpen)
        if needed, timer == nil {
            // Fires one second past each minute, when meetings start and alerts fall due.
            let first = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 1), matchingPolicy: .nextTime)
                ?? Date().addingTimeInterval(60)
            let t = Timer(fire: first, interval: 60, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        updateTimer()
    }

    private func panelChanged(_ open: Bool) {
        guard open != panelIsOpen else { return }
        panelIsOpen = open
        if open, !isDemo, access == .granted { tick() }
        updateTimer()
    }

    private func tick() {
        let current = clockOverride ?? Date()
        if !isDemo, let fetchedDay, Calendar.current.startOfDay(for: current) != fetchedDay {
            self.fetchedDay = nil
            refresh()
        }
        now = current
        let visible = visibleMeetings
        let text = CalendarAgenda.menuBarText(visible, now: current, enabled: UserDefaults.standard.bool(forKey: Keys.calendarMenuBar))
        if text != menuBarText { menuBarText = text }
        if !isDemo { postAlerts(visible, now: current) }
    }

    private func postAlerts(_ visible: [CalendarMeeting], now: Date) {
        let minutes = UserDefaults.standard.integer(forKey: Keys.calendarAlertMinutes)
        let due = CalendarAgenda.dueAlerts(visible, now: now, minutesBefore: minutes, alreadyAlerted: alerted)
        guard !due.isEmpty else { return }
        for m in due {
            alerted.insert(m.id)
            let when = CalendarAgenda.relative(m, now: now)
            var lines = [CalendarAgenda.timeRange(m) + (m.displayLocation.map { " · \($0)" } ?? "")]
            if let link = m.joinLink { lines.append("Join \(link.service.name): \(link.url.absoluteString)") }
            Notifier.post(title: when == "now" ? "\(m.title) is starting" : "\(m.title) \(when)", body: lines.joined(separator: "\n"))
        }
        // Remember only events still on the agenda, so the list never grows.
        let ids = Set(meetings.map(\.id))
        alerted = alerted.filter { ids.contains($0) }
        UserDefaults.standard.set(Array(alerted), forKey: Keys.calendarAlerted)
    }

    // MARK: Sample data

    /// Fills the service with a made-up day (documentation screenshots and render checks only).
    /// Nothing is read from or written to the real calendar.
    func loadDemo(access: CalendarAccess = .granted, now: Date? = nil) {
        isDemo = true
        timer?.invalidate()
        timer = nil
        let reference = now ?? CalendarSample.referenceNow()
        clockOverride = reference
        self.access = access
        problem = nil
        calendars = CalendarSample.calendars
        meetings = CalendarSample.meetings(around: reference)
        tick()
    }
}

/// A realistic made-up day for renders and checks.
enum CalendarSample {
    static let calendars = [
        CalendarChoice(id: "work", title: "Work", source: "iCloud", color: .blue),
        CalendarChoice(id: "home", title: "Home", source: "iCloud", color: .green),
        CalendarChoice(id: "family", title: "Family", source: "iCloud", color: .orange),
        CalendarChoice(id: "holidays", title: "Holidays", source: "Other", color: .purple),
    ]

    /// Today at 10:48.
    static func referenceNow(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 10, minute: 48, second: 1, of: Date()) ?? Date()
    }

    static func meetings(around now: Date, calendar: Calendar = .current) -> [CalendarMeeting] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }
        func work(_ id: String, _ title: String, _ day: Date, _ h: Int, _ m: Int, _ minutes: Int,
                  location: String? = nil, url: URL? = nil, notes: String? = nil, cal: CalendarChoice = calendars[0]) -> CalendarMeeting {
            let start = at(day, h, m)
            return CalendarMeeting(id: id, title: title, start: start, end: start.addingTimeInterval(Double(minutes * 60)),
                                   location: location, url: url, notes: notes, calendarID: cal.id, calendarTitle: cal.title, color: cal.color)
        }
        return [
            CalendarMeeting(id: "allday", title: "Release day", start: today, end: tomorrow.addingTimeInterval(-1), isAllDay: true,
                            calendarID: "work", calendarTitle: "Work", color: .blue),
            work("standup", "Daily standup", today, 9, 30, 15, notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij"),
            work("review", "Design review: menu bar panel", today, 11, 0, 45, location: "Room 4 / https://us02web.zoom.us/j/81234567890?pwd=Q2hlY2s",
                 notes: "Agenda: https://docs.example.com/review"),
            work("lunch", "Lunch with Maya", today, 12, 30, 60, location: "Tartine, 600 Guerrero St", cal: calendars[1]),
            work("oneone", "1:1 with Alex", today, 15, 0, 30,
                 notes: "<p>Microsoft Teams meeting</p><a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjE5%40thread.v2/0?context=%7b%22Tid%22%3a%2211%22%7d\">Join the meeting now</a>"),
            work("pickup", "School pickup", today, 17, 15, 30, cal: calendars[2]),
            work("planning", "Sprint planning", tomorrow, 10, 0, 60, url: URL(string: "https://acme.webex.com/meet/planning")),
            work("dentist", "Dentist", tomorrow, 16, 0, 45, location: "Mission Dental", cal: calendars[1]),
        ]
    }
}
