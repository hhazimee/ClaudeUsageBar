import Foundation

/// One account's weekly figures, as read from the API.
struct BudgetReading: Equatable {
    let id: String
    let name: String
    let used: Int
    let resetsAt: Date?
}

/// A shared daily allowance across accounts of the same size, used one at a
/// time. A point is 1% of one account's weekly limit.
struct DailyBudget: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var lastUsed: Int
        var resetsAt: Date?
        var spent: Int
        var allowance: Double
    }

    enum Alert: Equatable {
        case nearlyUsed
        case used
    }

    private static let week: TimeInterval = 7 * 24 * 3600
    private static let day: TimeInterval = 24 * 3600

    private(set) var day: String = ""
    private(set) var entries: [String: Entry] = [:]
    private var alertedNearlyUsed = false
    private var alertedUsed = false

    var allowance: Double { entries.values.reduce(0) { $0 + $1.allowance } }
    var spent: Int { entries.values.reduce(0) { $0 + $1.spent } }

    /// Usage left divided by whole days until reset. A window that will have
    /// reset by `date`, or has not started, counts as a full week.
    static func share(used: Int, resetsAt: Date?, at date: Date) -> Double {
        guard let resetsAt, resetsAt > date else {
            let usedNow = (resetsAt == nil) ? used : 0
            return Double(max(0, 100 - usedNow)) / 7
        }
        let days = max(1, (resetsAt.timeIntervalSince(date) / Self.day).rounded(.up))
        return Double(max(0, 100 - used)) / days
    }

    static func allowance(for readings: [BudgetReading], at date: Date) -> Double {
        readings.reduce(0) { $0 + share(used: $1.used, resetsAt: $1.resetsAt, at: date) }
    }

    /// The account to use next: usage left, soonest reset, because anything
    /// left at reset is lost.
    static func recommended(from readings: [BudgetReading]) -> BudgetReading? {
        readings
            .filter { $0.used < 100 }
            .min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    /// Records the readings and returns any alerts now due. `complete` is false
    /// while an included account has no data, since the allowance is then too
    /// low to alert on.
    mutating func observe(_ readings: [BudgetReading], day newDay: String, now: Date, complete: Bool) -> [Alert] {
        if newDay != day {
            day = newDay
            entries = [:]
            alertedNearlyUsed = false
            alertedUsed = false
        }

        for reading in readings {
            guard var entry = entries[reading.id] else {
                entries[reading.id] = Entry(
                    lastUsed: reading.used,
                    resetsAt: reading.resetsAt,
                    spent: 0,
                    allowance: Self.share(used: reading.used, resetsAt: reading.resetsAt, at: now)
                )
                continue
            }

            if Self.windowRolled(entry, reading, now: now) {
                entry.spent += reading.used
                entry.allowance += Self.share(used: reading.used, resetsAt: reading.resetsAt, at: now)
            } else if reading.used > entry.lastUsed {
                entry.spent += reading.used - entry.lastUsed
            }
            entry.lastUsed = reading.used
            entry.resetsAt = reading.resetsAt
            entries[reading.id] = entry
        }

        guard complete, allowance > 0 else { return [] }

        var alerts: [Alert] = []
        if Double(spent) >= allowance {
            if !alertedUsed { alerts.append(.used) }
            alertedUsed = true
            alertedNearlyUsed = true
        } else if Double(spent) >= allowance * 0.75 {
            if !alertedNearlyUsed { alerts.append(.nearlyUsed) }
            alertedNearlyUsed = true
        }
        return alerts
    }

    /// Keeps only these accounts, for when one is unticked or removed.
    mutating func retain(ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    // The API's reset time wobbles by under a second between fetches, so only
    // a jump of over an hour counts as a new window.
    private static func windowRolled(_ entry: Entry, _ reading: BudgetReading, now: Date) -> Bool {
        windowRolled(lastUsed: entry.lastUsed, resetsAt: entry.resetsAt, reading: reading, now: now)
    }

    static func windowRolled(lastUsed: Int, resetsAt: Date?, reading: BudgetReading, now: Date) -> Bool {
        guard let old = resetsAt else { return false }
        if let new = reading.resetsAt, new.timeIntervalSince(old) > 3600 { return true }
        return old <= now && reading.used < lastUsed
    }
}
