import Foundation

// MARK: - orb:// deep links
//
//   orb://model/<id>             → select the model in the browser
//   orb://chat?model=<id>        → new chat with that model (model optional)
//   orb://compare?ids=a,b        → open Compare with those models
//
// Model ids contain slashes ("openai/gpt-4o"), so `orb://model/openai/gpt-4o`
// keeps everything after "model/" as the id. Parsing is pure and strict:
// anything unrecognised returns nil and the app ignores it.

enum DeepLink: Equatable {
    case model(String)
    case chat(model: String?)
    case compare([String])

    static let scheme = "orb"

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (components.host ?? "").lowercased()
        // `orb:model/x` (no //) has no host; treat the first path segment as one.
        var path = components.percentEncodedPath
        var verb = host
        if verb.isEmpty {
            let trimmed = path.drop { $0 == "/" }
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            verb = parts.first.map { String($0).lowercased() } ?? ""
            path = parts.count > 1 ? "/" + parts[1] : ""
        }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        switch verb {
        case "model":
            let raw = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard let id = validID(raw.removingPercentEncoding ?? "") else { return nil }
            return .model(id)
        case "chat":
            guard let raw = query["model"] else { return .chat(model: nil) }
            guard let id = validID(raw) else { return nil }
            return .chat(model: id)
        case "compare":
            let ids = (query["ids"] ?? "")
                .split(separator: ",")
                .compactMap { validID(String($0)) }
            var seen = Set<String>()
            let unique = ids.filter { seen.insert($0).inserted }
            guard !unique.isEmpty else { return nil }
            return .compare(Array(unique.prefix(maximumCompareIDs)))
        default:
            return nil
        }
    }

    static let maximumCompareIDs = 10

    /// Model ids are short, printable and path-safe ("vendor/name:variant",
    /// optional leading "~").
    static func validID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...200).contains(id.count), id.contains("/"), !id.contains(".."),
              !id.hasPrefix("/"), !id.hasSuffix("/") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.:~@+"))
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return id
    }

    /// Builds the canonical link (for "Copy Link" and round-trip tests).
    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .model(let id):
            c.host = "model"
            c.path = "/" + id
        case .chat(let model):
            c.host = "chat"
            if let model { c.queryItems = [URLQueryItem(name: "model", value: model)] }
        case .compare(let ids):
            c.host = "compare"
            c.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        }
        return c.url
    }

    /// What the shell should do. Compare links stage the selection, then
    /// open the panel.
    var shellAction: ShellAction {
        switch self {
        case .model(let id): return .selectModel(id)
        case .chat(let model): return model.map(ShellAction.chatWithModel) ?? .newChat
        case .compare(let ids): return .openCompareWith(ids)
        }
    }
}
