import SwiftUI

/// The Statistics tab: one card per account.
struct StatisticsSection: View {
    @ObservedObject var accounts: AccountsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(accounts.managers, id: \.account.id) { manager in
                if manager.account.id != accounts.managers.first?.account.id {
                    Divider()
                }
                AccountStatsCard(emoji: manager.account.emoji,
                                 name: manager.account.displayName,
                                 color: manager.account.color,
                                 stats: accounts.stats(for: manager))
            }
            Text("% of each account's weekly limit")
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
        }
    }
}

struct AccountStatsCard: View {
    let emoji: String
    let name: String
    let color: Color
    let stats: UsageHistory.Stats?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(emoji).font(.system(size: 13))
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(color)
                    Spacer()
                    if let stats {
                        Text("Today \(stats.today)%")
                            .font(.subheadline)
                    }
                }

                if let stats {
                    HStack(spacing: 16) {
                        if stats.trackedDays < 7 {
                            StatFigure(label: "Avg since \(Self.shortDate(stats.since))", value: stats.week)
                        } else {
                            StatFigure(label: "7-day avg", value: stats.week)
                            if stats.trackedDays >= 30 {
                                StatFigure(label: "30-day avg", value: stats.month)
                            }
                        }
                    }
                    UsageStrip(values: stats.recent)
                } else {
                    Text("No data yet")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }
        }
    }

    private static func shortDate(_ key: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: key) else { return key }
        let show = DateFormatter()
        show.dateFormat = "MMM d"
        return show.string(from: date)
    }
}

struct StatFigure: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int(value.rounded()))% / day")
                .font(.system(size: 15, weight: .semibold))
            Text(label)
                .font(.caption2)
                .foregroundColor(Color.secondaryText)
        }
    }
}

/// Daily bars, oldest first. Nil days (before tracking) draw as empty slots.
/// Days above an even weekly pace (100/7) turn orange.
struct UsageStrip: View {
    let values: [Int?]
    var height: CGFloat = 28

    private static let pace = 100.0 / 7

    var body: some View {
        let top = max(Double(values.compactMap { $0 }.max() ?? 0), Self.pace)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                let value = values[i]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(value))
                    .frame(height: max(2, height * CGFloat(Double(value ?? 0) / top)))
                    .frame(maxWidth: .infinity)
                    .help(value.map { "\($0)%" } ?? "")
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func color(_ value: Int?) -> Color {
        guard let value else { return Color.secondary.opacity(0.15) }
        return Double(value) > Self.pace ? .orange : .accentColor
    }
}
