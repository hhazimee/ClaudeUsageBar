import Foundation
import Testing
@testable import ClaudeUsageBudget

@Suite("Daily budget")
struct DailyBudgetTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    func haz(_ used: Int, resetIn hours: Double = 70) -> BudgetReading {
        BudgetReading(id: "haz", name: "Haz", used: used, resetsAt: now.addingTimeInterval(hours * hour))
    }

    func haz2(_ used: Int, resetIn hours: Double = 13) -> BudgetReading {
        BudgetReading(id: "haz2", name: "Haz2", used: used, resetsAt: now.addingTimeInterval(hours * hour))
    }

    @Test func allowanceAddsEachAccountsShareOverWholeDaysLeft() {
        let allowance = DailyBudget.allowance(for: [haz(31), haz2(96)], at: now)
        #expect(allowance == 27)
    }

    @Test func windowThatHasResetByThatDateCountsAsAFullWeek() {
        let later = now.addingTimeInterval(24 * hour)
        #expect(abs(DailyBudget.share(used: 96, resetsAt: haz2(96).resetsAt, at: later) - 100.0 / 7) < 0.001)
    }

    @Test func windowNotStartedSpreadsOverAWeek() {
        #expect(abs(DailyBudget.share(used: 0, resetsAt: nil, at: now) - 100.0 / 7) < 0.001)
    }

    @Test func recommendsSoonestResetWithUsageLeft() {
        #expect(DailyBudget.recommended(from: [haz(31), haz2(96)])?.id == "haz2")
        #expect(DailyBudget.recommended(from: [haz(31), haz2(100)])?.id == "haz")
        #expect(DailyBudget.recommended(from: [haz(100), haz2(100)]) == nil)
    }

    @Test func spentAddsRisesAcrossAccounts() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31), haz2(96)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(36), haz2(98)], day: "d1", now: now, complete: true)
        #expect(budget.spent == 7)
    }

    @Test func smallDropWithoutNewWindowIsNotCounted() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(30)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(32)], day: "d1", now: now, complete: true)
        #expect(budget.spent == 2)
        #expect(budget.allowance == 23)
    }

    @Test func resetMidDayCountsNewUsageAndGrowsAllowance() {
        var budget = DailyBudget()
        _ = budget.observe([haz2(96)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz2(98)], day: "d1", now: now, complete: true)
        let after = now.addingTimeInterval(14 * hour)
        _ = budget.observe([haz2(3, resetIn: 14 + 168)], day: "d1", now: after, complete: true)
        #expect(budget.spent == 5)
        #expect(abs(budget.allowance - (4 + 97.0 / 7)) < 0.001)
    }

    @Test func resetTimeWobbleIsNotANewWindow() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(31, resetIn: 70.0003)], day: "d1", now: now, complete: true)
        #expect(budget.spent == 0)
        #expect(budget.allowance == 23)
    }

    @Test func alertsFireOncePerDayInOrder() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31)], day: "d1", now: now, complete: true)  // allowance 23
        #expect(budget.observe([haz(40)], day: "d1", now: now, complete: true) == [])
        #expect(budget.observe([haz(49)], day: "d1", now: now, complete: true) == [.nearlyUsed])
        #expect(budget.observe([haz(50)], day: "d1", now: now, complete: true) == [])
        #expect(budget.observe([haz(54)], day: "d1", now: now, complete: true) == [.used])
        #expect(budget.observe([haz(60)], day: "d1", now: now, complete: true) == [])
    }

    @Test func noAlertsUntilEveryAccountHasData() {
        var budget = DailyBudget()
        _ = budget.observe([haz2(96)], day: "d1", now: now, complete: false)
        #expect(budget.observe([haz2(100)], day: "d1", now: now, complete: false) == [])
    }

    @Test func newDayStartsAgain() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(60)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(60)], day: "d2", now: now, complete: true)
        #expect(budget.spent == 0)
        #expect(budget.observe([haz(80)], day: "d2", now: now, complete: true) == [.used])
    }

    @Test func untickedAccountLeavesTheTotals() {
        var budget = DailyBudget()
        _ = budget.observe([haz(31), haz2(96)], day: "d1", now: now, complete: true)
        budget.retain(ids: ["haz"])
        #expect(budget.allowance == 23)
    }

    @Test func survivesSavingAndLoading() throws {
        var budget = DailyBudget()
        _ = budget.observe([haz(31)], day: "d1", now: now, complete: true)
        _ = budget.observe([haz(49)], day: "d1", now: now, complete: true)
        var loaded = try JSONDecoder().decode(DailyBudget.self, from: JSONEncoder().encode(budget))
        #expect(loaded == budget)
        #expect(loaded.observe([haz(50)], day: "d1", now: now, complete: true) == [])
    }
}
