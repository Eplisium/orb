import SwiftUI
import Charts

/// Settings → Usage: lifetime spend, requests, and tokens from the permanent
/// usage ledger, broken down by app feature, model, and day.
struct UsageSettingsView: View {
    @ObservedObject private var ledger = UsageLedger.shared
    @State private var range: Range = .allTime
    @State private var features: [UsageBucket] = []
    @State private var models: [UsageBucket] = []
    @State private var days: [UsageBucket] = []
    @State private var months: [UsageBucket] = []
    @State private var firstDate: Date?
    @State private var hoveredDay: Date?

    let accent: Color

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 Days", month = "30 Days", allTime = "All Time"
        var id: String { rawValue }
        var start: Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .allTime: return nil
            }
        }
    }

    private var totalCost: Double { features.reduce(0) { $0 + $1.cost } }
    private var totalRequests: Int { features.reduce(0) { $0 + $1.requests } }
    private var totalTokens: Int { features.reduce(0) { $0 + $1.tokens } }
    private var unpriced: Int { features.reduce(0) { $0 + $1.unpricedRequests } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage & Cost").font(.title3.weight(.semibold))
                    Text(firstDate.map { "Tracked since \($0.formatted(date: .abbreviated, time: .omitted)). Stored permanently on this Mac." }
                         ?? "Every paid request is recorded here permanently on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300).labelsHidden()
            }

            HStack(spacing: 12) {
                stat("Total spend", Self.money(totalCost), icon: "dollarsign.circle.fill")
                stat("Requests", totalRequests.formatted(), icon: "arrow.up.arrow.down.circle.fill")
                stat("Tokens", Self.compact(totalTokens), icon: "text.word.spacing")
                stat("Top feature", features.first(where: { $0.cost > 0 })?.key ?? features.max { $0.requests < $1.requests }?.key ?? "—",
                     icon: "star.circle.fill")
            }

            if unpriced > 0 {
                Text("\(unpriced) request\(unpriced == 1 ? "" : "s") had no cost reported by the provider (for example speech audio), so real spend may be higher than shown.")
                    .font(.caption).foregroundStyle(.orange)
            }

            if !features.isEmpty { charts }

            if features.isEmpty {
                Text("No usage recorded in this range yet. New requests appear here automatically.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                section("By app feature", features, showShare: true)
                section("By model", models, showShare: true)
                section(range == .allTime ? "By month" : "By day", range == .allTime ? months : days, showShare: false)
            }
        }
        .task(id: range) { reload() }
        .onChange(of: ledger.revision) { _, _ in reload() }
    }

    private var chartDays: Int {
        switch range {
        case .today: return 1
        case .week: return 7
        case .month, .allTime: return 30
        }
    }

    @ViewBuilder
    private var charts: some View {
        let series = UsageSeries.daily(days, days: chartDays, endingAt: Date())
        let slices = UsageSeries.topModels(models, limit: 5)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageSeries.chartTitle(days: chartDays, range: range == .allTime ? .allTime : .bounded))
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if let hovered = hoverPoint(in: series), let date = hovered.date {
                        Text("\(UsageSeries.shortDate(date)): \(Self.money(hovered.cost))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.primary)
                    }
                }
                Chart(series.filter { $0.date != nil }) { point in
                    BarMark(x: .value("Day", point.date ?? Date(), unit: .day), y: .value("Spend", point.cost))
                        .foregroundStyle(accent.opacity(hoveredDay == nil || isHovered(point) ? 1 : 0.45))
                        .accessibilityLabel(point.date.map { UsageSeries.shortDate($0) } ?? point.label)
                        .accessibilityValue(Self.money(point.cost))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: UsageSeries.axisStride(days: chartDays))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Self.money(d)) } } } }
                .chartXSelection(value: $hoveredDay)
                .frame(height: 130)
                .help("Hover a bar to see that day's spend")
            }
            if !slices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPEND BY MODEL").font(.caption.bold()).foregroundStyle(.secondary)
                    Chart(slices) { slice in
                        BarMark(x: .value("Spend", slice.cost), y: .value("Model", slice.label))
                            .foregroundStyle(accent.opacity(0.75))
                            .annotation(position: .trailing) { Text(Self.money(slice.cost)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .frame(height: CGFloat(slices.count) * 26 + 10)
                    .accessibilityLabel("Spend by model")
                    .accessibilityValue(slices.map { "\($0.label) \(Self.money($0.cost))" }.joined(separator: ", "))
                }
            }
        }
        .padding(14)
        .background(.orbSurface(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private func isHovered(_ point: UsagePoint) -> Bool {
        guard let hoveredDay, let date = point.date else { return false }
        return Calendar.current.isDate(date, inSameDayAs: hoveredDay)
    }

    private func hoverPoint(in series: [UsagePoint]) -> UsagePoint? {
        guard hoveredDay != nil else { return nil }
        return series.first(where: isHovered)
    }

    private func reload() {
        let since = range.start
        features = ledger.buckets(.feature, since: since)
        models = ledger.buckets(.model, since: since)
        days = ledger.buckets(.day, since: since)
        months = ledger.buckets(.month, since: since)
        firstDate = ledger.firstEventDate
    }

    private func stat(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).orbFont(size: 20, weight: .semibold, design: .rounded).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orbSurface(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func section(_ title: String, _ rows: [UsageBucket], showShare: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            let maxCost = rows.map(\.cost).max() ?? 0
            let maxRequests = rows.map(\.requests).max() ?? 1
            ForEach(rows.prefix(showShare ? 12 : 60)) { row in
                let weight = maxCost > 0 ? row.cost / maxCost : Double(row.requests) / Double(max(maxRequests, 1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.key).orbFont(size: 12, weight: .medium).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(row.requests) req · \(Self.compact(row.tokens)) tok")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Self.money(row.cost))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
                        if showShare, totalCost > 0 {
                            Text("\(Int((row.cost / totalCost * 100).rounded()))%")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }
                    }
                    GeometryReader { geo in
                        Capsule().fill(accent.opacity(0.7))
                            .frame(width: max(3, geo.size.width * weight), height: 4)
                    }.frame(height: 4)
                }
            }
            if showShare, rows.count > 12 {
                Text("+ \(rows.count - 12) more").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.orbSurface(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    static func money(_ value: Double) -> String {
        guard value > 0 else { return "$0.00" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}
