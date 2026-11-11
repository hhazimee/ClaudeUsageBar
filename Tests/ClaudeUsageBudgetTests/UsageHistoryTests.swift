import Foundation
import Testing
@testable import ClaudeUsageBudget

@Suite("Usage history")
struct UsageHistoryTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // 2027-01-15 08:00 UTC
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600
    let day: TimeInterval = 24 * 3600

    func reading(_ used: Int, resetsAt: Date) -> BudgetReading {
        BudgetReading(id: "haz", name: "Haz", used: used, resetsAt: resetsAt)
    }

    @Test func firstReadingCountsNothing() {
        var history = UsageHistory()
        history.observe([reading(40, resetsAt: start.addingTimeInterval(3 * day))], now: start, calendar: calendar)
        let stats = history.stats(for: "haz", now: start, calendar: calendar)
        #expect(stats?.today == 0)
        #expect(stats?.trackedDays == 1)
    }

    @Test func risesAddUpPerDay() {
        let reset = start.addingTimeInterval(5 * day)
        var history = UsageHistory()
        history.observe([reading(10, resetsAt: reset)], now: start, calendar: calendar)
        history.observe([reading(15, resetsAt: reset)], now: start.addingTimeInterval(hour), calendar: calendar)
        history.observe([reading(30, resetsAt: reset)], now: start.addingTimeInterval(day), calendar: calendar)

        let stats = history.stats(for: "haz", now: start.addingTimeInterval(day), calendar: calendar)
        #expect(stats?.today == 15)
        #expect(stats?.trackedDays == 2)
        #expect(stats?.week == 10)
        #expect(stats?.recent.suffix(2) == [5, 15])
        #expect(stats?.recent.first == .some(nil))
    }

    @Test func newWindowCountsItsUsage() {
        var history = UsageHistory()
        history.observe([reading(90, resetsAt: start.addingTimeInterval(hour))], now: start, calendar: calendar)
        history.observe([reading(4, resetsAt: start.addingTimeInterval(7 * day + hour))],
                        now: start.addingTimeInterval(2 * hour), calendar: calendar)
        #expect(history.stats(for: "haz", now: start.addingTimeInterval(2 * hour), calendar: calendar)?.today == 4)
    }

    @Test func gapDaysCountAsZeroInTheAverage() {
        let reset = start.addingTimeInterval(6 * day)
        var history = UsageHistory()
        history.observe([reading(0, resetsAt: reset)], now: start, calendar: calendar)
        history.observe([reading(30, resetsAt: reset)], now: start.addingTimeInterval(2 * day), calendar: calendar)
        let stats = history.stats(for: "haz", now: start.addingTimeInterval(2 * day), calendar: calendar)
        #expect(stats?.trackedDays == 3)
        #expect(stats?.week == 10)
    }

    @Test func dropsDaysOlderThanNinety() {
        var history = UsageHistory()
        var now = start
        var used = 0
        for _ in 0..<100 {
            used = (used + 1) % 100
            history.observe([reading(used, resetsAt: now.addingTimeInterval(3 * day))], now: now, calendar: calendar)
            now = now.addingTimeInterval(day)
        }
        #expect(history.dayCount(for: "haz") == 90)
    }

    @Test func retainDropsRemovedAccounts() {
        var history = UsageHistory()
        history.observe([reading(1, resetsAt: start)], now: start, calendar: calendar)
        history.retain(ids: [])
        #expect(history.stats(for: "haz", now: start, calendar: calendar) == nil)
    }
}
