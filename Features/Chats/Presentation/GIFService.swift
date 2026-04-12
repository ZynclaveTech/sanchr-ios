import Foundation

// MARK: - GIFResult

struct GIFResult: Identifiable, Sendable {
    let id: String
    let title: String
    let previewURL: URL     // tinygif — small preview for the picker grid
    let fullURL: URL        // full-size GIF sent as the attachment
}

// MARK: - GIFService

/// Tenor v2 API client for GIF search and trending.
/// Requires a Tenor API key — set the `apiKey` constant or inject via env.
/// Returns empty arrays (no crash) when the key is missing / request fails.
final class GIFService: Sendable {

    static let shared = GIFService()
    private init() {}

    // Replace with a real Tenor API key from console.cloud.google.com/apis.
    private let apiKey = "TENOR_API_KEY"
    private let clientKey = "sanchr_ios"
    private let limit = 24

    func trending() async -> [GIFResult] {
        await fetch(path: "featured", params: [:])
    }

    func search(query: String) async -> [GIFResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return await trending() }
        return await fetch(path: "search", params: ["q": trimmed])
    }

    // MARK: - Private

    private func fetch(path: String, params: [String: String]) async -> [GIFResult] {
        var components = URLComponents(string: "https://tenor.googleapis.com/v2/\(path)")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "client_key", value: clientKey),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "media_filter", value: "gif,tinygif"),
        ]
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(TenorResponse.self, from: data)
            return decoded.results.compactMap(GIFResult.init(from:))
        } catch {
            return []
        }
    }
}

// MARK: - Tenor wire models (private)

private struct TenorResponse: Decodable {
    let results: [TenorResult]
}

private struct TenorResult: Decodable {
    let id: String
    let title: String
    let mediaFormats: [String: TenorMedia]

    enum CodingKeys: String, CodingKey {
        case id, title
        case mediaFormats = "media_formats"
    }
}

private struct TenorMedia: Decodable {
    let url: String
}

private extension GIFResult {
    init?(from r: TenorResult) {
        guard
            let previewRaw = r.mediaFormats["tinygif"] ?? r.mediaFormats["gif"],
            let previewURL = URL(string: previewRaw.url),
            let fullRaw = r.mediaFormats["gif"] ?? r.mediaFormats["tinygif"],
            let fullURL = URL(string: fullRaw.url)
        else { return nil }

        self.id = r.id
        self.title = r.title
        self.previewURL = previewURL
        self.fullURL = fullURL
    }
}
