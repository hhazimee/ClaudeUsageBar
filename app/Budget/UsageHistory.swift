import Foundation

/// Weekly-limit points each account used per day, kept for 90 days.
/// A point is 1% of that account's weekly limit.
struct UsageHistory: Codable, Equatable {
    struct Track: Codable, Equatable {
        var lastUsed: Int
        var resetsAt: Date?
        var since: String
        var days: [String: Int]
    }

    struct Stats: Equatable {
        let today: Int
        let week: Double
        let month: Double
        let trackedDays: Int
        let since: String
        /// The last 14 days, oldest first. Nil before tracking began.
        let recent: [Int?]
    }

    static let keepDays = 90

    private(set) var tracks: [String: Track] = [:]

    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Usage seen while the Mac was off lands on the day it is next read.
    mutating func observe(_ readings: [BudgetReading], now: Date, calendar: Calendar = .current) {
        let today = Self.key(now, calendar: calendar)
        let cutoff = Self.key(Self.daysBack(Self.keepDays - 1, from: now, calendar: calendar), calendar: calendar)

        for reading in readings {
            guard var track = tracks[reading.id] else {
                tracks[reading.id] = Track(lastUsed: reading.used, resetsAt: reading.resetsAt,
                                           since: today, days: [today: 0])
                continue
            }
            var rise = 0
            if DailyBudget.windowRolled(lastUsed: track.lastUsed, resetsAt: track.resetsAt, reading: reading, now: now) {
                rise = reading.used
            } else if reading.used > track.lastUsed {
                rise = reading.used - track.lastUsed
            }
            track.days[today, default: 0] += rise
            track.days = track.days.filter { $0.key >= cutoff }
            track.lastUsed = reading.used
            track.resetsAt = reading.resetsAt
            tracks[reading.id] = track
        }
    }

    mutating func retain(ids: Set<String>) {
        tracks = tracks.filter { ids.contains($0.key) }
    }

    func dayCount(for id: String) -> Int {
        tracks[id]?.days.count ?? 0
    }

    /// Averages divide by calendar days since tracking began, today included.
    func stats(for id: String, now: Date, calendar: Calendar = .current) -> Stats? {
        guard let track = tracks[id] else { return nil }
        let day = { (back: Int) in Self.key(Self.daysBack(back, from: now, calendar: calendar), calendar: calendar) }
        let tracked = (0..<Self.keepDays).prefix { day($0) >= track.since }.count

        func average(_ n: Int) -> Double {
            let span = min(n, tracked)
            guard span > 0 else { return 0 }
            return Double((0..<span).reduce(0) { $0 + (track.days[day($1)] ?? 0) }) / Double(span)
        }

        let recent: [Int?] = (0..<14).reversed().map { back in
            let key = day(back)
            return key >= track.since ? (track.days[key] ?? 0) : nil
        }

        return Stats(today: track.days[day(0)] ?? 0, week: average(7), month: average(30),
                     trackedDays: tracked, since: track.since, recent: recent)
    }

    private static func daysBack(_ n: Int, from date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -n, to: date) ?? date
    }
}
