import Foundation

// MARK: - Model list export (CSV / JSON)

enum ModelExportFormat: String, CaseIterable, Identifiable {
    case csv, json
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { self == .csv ? "CSV" : "JSON" }
}

enum ModelExport {
    static let columns = [
        "id", "name", "provider", "context_length", "max_output",
        "input_price", "output_price", "price_unit", "intelligence_index", "coding_index",
        "agentic_index", "input_modalities", "output_modalities", "expiration_date", "alias_of",
    ]

    struct Row: Encodable, Equatable {
        let id: String
        let name: String
        let provider: String
        let contextLength: Int?
        let maxOutput: Int?
        let inputPrice: Double?
        let outputPrice: Double?
        let priceUnit: String
        let intelligenceIndex: Double?
        let codingIndex: Double?
        let agenticIndex: Double?
        let inputModalities: [String]
        let outputModalities: [String]
        let expirationDate: String?
        let aliasOf: String?

        enum CodingKeys: String, CodingKey {
            case id, name, provider
            case contextLength = "context_length"
            case maxOutput = "max_output"
            case inputPrice = "input_price"
            case outputPrice = "output_price"
            case priceUnit = "price_unit"
            case intelligenceIndex = "intelligence_index"
            case codingIndex = "coding_index"
            case agenticIndex = "agentic_index"
            case inputModalities = "input_modalities"
            case outputModalities = "output_modalities"
            case expirationDate = "expiration_date"
            case aliasOf = "alias_of"
        }
    }

    static func row(_ m: ModelInfo, unit: PriceUnit) -> Row {
        func price(_ raw: String?) -> Double? {
            if m.isFree { return 0 }
            return PriceDisplay.perToken(raw).map { ($0 * unit.tokens * 1e9).rounded() / 1e9 }
        }
        let aa = m.benchmarks?.artificialAnalysis
        return Row(
            id: m.id, name: m.name, provider: m.provider,
            contextLength: m.contextLength, maxOutput: m.topProvider?.maxCompletionTokens,
            inputPrice: price(m.pricing?.prompt), outputPrice: price(m.pricing?.completion),
            priceUnit: "USD per \(unit.suffix) tokens",
            intelligenceIndex: aa?.intelligenceIndex, codingIndex: aa?.codingIndex, agenticIndex: aa?.agenticIndex,
            inputModalities: m.inputModalities, outputModalities: m.outputModalities,
            expirationDate: m.expirationDate, aliasOf: m.aliasTarget?.slug
        )
    }

    static func render(_ models: [ModelInfo], format: ModelExportFormat, unit: PriceUnit) -> String {
        let rows = models.map { row($0, unit: unit) }
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(rows)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        case .csv:
            var lines = [columns.joined(separator: ",")]
            for r in rows {
                let fields: [String] = [
                    r.id, r.name, r.provider, num(r.contextLength), num(r.maxOutput),
                    num(r.inputPrice), num(r.outputPrice), r.priceUnit, num(r.intelligenceIndex),
                    num(r.codingIndex), num(r.agenticIndex), r.inputModalities.joined(separator: "+"),
                    r.outputModalities.joined(separator: "+"), r.expirationDate ?? "", r.aliasOf ?? "",
                ]
                lines.append(fields.map(csvField).joined(separator: ","))
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private static func num(_ v: Int?) -> String { v.map(String.init) ?? "" }
    private static func num(_ v: Double?) -> String {
        guard let v else { return "" }
        return v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    /// RFC 4180 quoting; also neutralises spreadsheet formula prefixes.
    static func csvField(_ raw: String) -> String {
        var value = raw
        if let first = value.first, "=+-@".contains(first), Double(value) == nil { value = "'" + value }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
