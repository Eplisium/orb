import SwiftUI

// MARK: - Settings logic (Phase 7)
//
// Pure, unit-tested types for the Settings scene: appearance preferences,
// pane list, usage-chart series, save status and inline validation.

// MARK: Appearance

struct AppearancePrefs: Equatable {
    enum Scheme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small, standard, large, xLarge
        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: return "Small"
            case .standard: return "Default"
            case .large: return "Large"
            case .xLarge: return "Extra Large"
            }
        }

        var dynamicTypeSize: DynamicTypeSize {
            switch self {
            case .small: return .medium
            case .standard: return .large
            case .large: return .xLarge
            case .xLarge: return .xxLarge
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        case comfortable, compact
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var rowPadding: CGFloat { self == .compact ? 3 : 7 }
        /// Never below the 28 pt hit target the design system uses.
        var minimumRowHeight: CGFloat { self == .compact ? 28 : 36 }
        var controlSize: ControlSize { self == .compact ? .small : .regular }
    }

    enum MotionOverride: String, CaseIterable, Identifiable {
        case system, on, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Follow System"
            case .on: return "Reduce"
            case .off: return "Allow"
            }
        }
    }

    var scheme: Scheme = .system
    var textSize: TextSize = .standard
    var density: Density = .comfortable
    var reduceMotion: MotionOverride = .system

    static let schemeKey = "orb.appearance.scheme"
    static let textSizeKey = "orb.appearance.textSize"
    static let densityKey = "orb.appearance.density"
    static let motionKey = "orb.appearance.reduceMotion"

    var preferredColorScheme: ColorScheme? {
        switch scheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The OS Reduce Motion setting is never overridden away: "Allow" only
    /// means "don't add more reduction than the system asks for".
    func effectiveReduceMotion(system: Bool) -> Bool {
        system || reduceMotion == .on
    }

    static func load(from defaults: UserDefaults = .standard) -> AppearancePrefs {
        AppearancePrefs(
            scheme: defaults.string(forKey: schemeKey).flatMap(Scheme.init(rawValue:)) ?? .system,
            textSize: defaults.string(forKey: textSizeKey).flatMap(TextSize.init(rawValue:)) ?? .standard,
            density: defaults.string(forKey: densityKey).flatMap(Density.init(rawValue:)) ?? .comfortable,
            reduceMotion: defaults.string(forKey: motionKey).flatMap(MotionOverride.init(rawValue:)) ?? .system
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(scheme.rawValue, forKey: Self.schemeKey)
        defaults.set(textSize.rawValue, forKey: Self.textSizeKey)
        defaults.set(density.rawValue, forKey: Self.densityKey)
        defaults.set(reduceMotion.rawValue, forKey: Self.motionKey)
    }
}

/// Applies the saved appearance to a window's whole view tree.
struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearancePrefs.schemeKey) private var scheme = AppearancePrefs.Scheme.system.rawValue
    @AppStorage(AppearancePrefs.textSizeKey) private var textSize = AppearancePrefs.TextSize.standard.rawValue
    @AppStorage(AppearancePrefs.densityKey) private var density = AppearancePrefs.Density.comfortable.rawValue

    func body(content: Content) -> some View {
        let prefs = AppearancePrefs(
            scheme: .init(rawValue: scheme) ?? .system,
            textSize: .init(rawValue: textSize) ?? .standard,
            density: .init(rawValue: density) ?? .comfortable
        )
        content
            .preferredColorScheme(prefs.preferredColorScheme)
            .dynamicTypeSize(prefs.textSize.dynamicTypeSize)
            .controlSize(prefs.density.controlSize)
    }
}

extension View {
    func orbAppearance() -> some View { modifier(AppearanceModifier()) }
}

// MARK: Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, usage, mcp, network, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts & Keys"
        case .usage: return "Usage & Credits"
        case .mcp: return "MCP"
        case .network: return "Network"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "key"
        case .usage: return "chart.bar"
        case .mcp: return "puzzlepiece.extension"
        case .network: return "network"
        case .advanced: return "slider.horizontal.3"
        }
    }

    static let storageKey = "orb.settings.pane"

    /// Maps the old single-row tab names so existing deep links keep working.
    static func fromLegacy(_ name: String) -> SettingsPane {
        switch name {
        case "API Key", "Key Info": return .accounts
        case "Credits", "Usage", "Activity": return .usage
        case "Providers": return .advanced
        case "MCP Servers": return .mcp
        case "Advanced": return .network
        default: return .general
        }
    }

    static func restore(from defaults: UserDefaults = .standard) -> SettingsPane {
        defaults.string(forKey: storageKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    func store(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.storageKey) }
}

// MARK: Usage chart series

struct UsagePoint: Identifiable, Equatable {
    let label: String
    let cost: Double
    var id: String { label }
}

enum UsageSeries {
    /// One point per calendar day in the window, oldest first; days without
    /// spend are zero so the chart axis is continuous.
    static func daily(_ buckets: [UsageBucket], days: Int, endingAt end: Date, calendar: Calendar = .current) -> [UsagePoint] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let byDay = Dictionary(buckets.map { ($0.key, $0.cost) }, uniquingKeysWith: +)
        let endDay = calendar.startOfDay(for: end)
        return (0..<max(days, 0)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: endDay).map { date in
                let label = formatter.string(from: date)
                return UsagePoint(label: label, cost: byDay[label] ?? 0)
            }
        }
    }

    /// Top `limit` spenders; the rest roll into "Other" so totals are preserved.
    static func topModels(_ buckets: [UsageBucket], limit: Int) -> [UsagePoint] {
        let priced = buckets.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }
        var slices = priced.prefix(limit).map { UsagePoint(label: $0.key, cost: $0.cost) }
        let rest = priced.dropFirst(limit).reduce(0) { $0 + $1.cost }
        if rest > 0 { slices.append(UsagePoint(label: "Other", cost: rest)) }
        return slices
    }

    static func accessibilitySummary(_ series: [UsagePoint]) -> String {
        let total = series.reduce(0) { $0 + $1.cost }
        guard total > 0, let peak = series.max(by: { $0.cost < $1.cost }) else { return "No spend recorded." }
        return "Total \(UsageSettingsView.money(total)) over \(series.count) days. Highest on \(peak.label) at \(UsageSettingsView.money(peak.cost))."
    }
}

// MARK: Save status

enum SaveStatus: Equatable {
    case idle, saving, saved, failed(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .saving: return "Saving…"
        case .saved: return "Saved"
        case .failed(let reason): return "Couldn't save: \(reason)"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return ""
        case .saving: return "arrow.triangle.2.circlepath"
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// "Saved" fades away; a failure stays until the user acts on it.
    var afterDisplayTime: SaveStatus { self == .saved ? .idle : self }
}

// MARK: Inline validation

enum FieldCheck: Equatable {
    case empty
    case valid
    case invalid(String)

    var message: String? { if case .invalid(let m) = self { return m } else { return nil } }
}

enum KeyFieldValidation {
    /// Format only; the key is never echoed into a message and never leaves the device here.
    static func check(_ raw: String) -> FieldCheck {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .empty }
        guard key.hasPrefix("sk-or-") else { return .invalid("OpenRouter keys start with “sk-or-”.") }
        guard key.count >= 32 else { return .invalid("That key looks too short.") }
        return .valid
    }
}

enum RangeValidation {
    static func check(_ raw: String, in range: ClosedRange<Int>, unit: String) -> FieldCheck {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .empty }
        if let value = Int(text), range.contains(value) { return .valid }
        return .invalid("Enter a number from \(range.lowerBound) to \(range.upperBound) \(unit).")
    }
}

// MARK: Views

/// General → Appearance. Changes apply live to every window.
struct AppearanceSettingsSection: View {
    @AppStorage(AppearancePrefs.schemeKey) private var scheme = AppearancePrefs.Scheme.system.rawValue
    @AppStorage(AppearancePrefs.textSizeKey) private var textSize = AppearancePrefs.TextSize.standard.rawValue
    @AppStorage(AppearancePrefs.densityKey) private var density = AppearancePrefs.Density.comfortable.rawValue
    @AppStorage(AppearancePrefs.motionKey) private var motion = AppearancePrefs.MotionOverride.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Appearance", systemImage: "paintpalette").font(.title3.weight(.semibold))
            Picker("Theme", selection: $scheme) {
                ForEach(AppearancePrefs.Scheme.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            Picker("Text size", selection: $textSize) {
                ForEach(AppearancePrefs.TextSize.allCases) { Text($0.title).tag($0.rawValue) }
            }.frame(maxWidth: 320)
            Picker("Density", selection: $density) {
                ForEach(AppearancePrefs.Density.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).frame(maxWidth: 320)
            Picker("Animations", selection: $motion) {
                ForEach(AppearancePrefs.MotionOverride.allCases) { Text($0.title).tag($0.rawValue) }
            }.frame(maxWidth: 320)
            Text("ORB always follows your Mac's Reduce Motion setting. “Reduce” turns animations down even when the system hasn't.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Inline "Saved / Saving… / Couldn't save" indicator; words and a symbol, not colour alone.
struct SaveStatusLabel: View {
    let status: SaveStatus

    var body: some View {
        if status != .idle {
            Label(status.text, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle({ if case .failed = status { return Color.red } else { return Color.secondary } }())
                .accessibilityElement(children: .combine)
        }
    }
}
