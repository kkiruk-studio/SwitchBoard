import Foundation

struct ModelRates: Codable {
    let input: Double       // USD per 1M tokens
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

@MainActor
enum PricingTable {
    // 최후의 폴백 (LiteLLM fetch 실패 + 패턴 매칭 실패 시)
    private static let fallbackRates: [(pattern: String, rates: ModelRates)] = [
        ("opus",   ModelRates(input: 15.0, output: 75.0, cacheRead: 1.50,  cacheWrite: 18.75)),
        ("haiku",  ModelRates(input: 1.0,  output: 5.0,  cacheRead: 0.10,  cacheWrite: 1.25)),
        ("sonnet", ModelRates(input: 3.0,  output: 15.0, cacheRead: 0.30,  cacheWrite: 3.75)),
    ]

    // 원격에서 받은 모델별 정확한 가격 (full model name → rates)
    private static var remote: [String: ModelRates] = [:]

    private static let cacheKey = "pricingTableCache"
    private static let cacheDateKey = "pricingTableCacheDate"
    private static let refreshInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let feedURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    static func loadCached() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: ModelRates].self, from: data) {
            remote = decoded
        }
    }

    /// 마지막 성공 fetch가 refreshInterval 이상 지났으면 재시도
    static func refreshIfStale() {
        let last = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        if let last = last, Date().timeIntervalSince(last) < refreshInterval, !remote.isEmpty {
            return
        }
        Task.detached { await fetchRemote() }
    }

    private static func fetchRemote() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var parsed: [String: ModelRates] = [:]
            for (name, value) in json {
                guard let entry = value as? [String: Any] else { continue }
                // Anthropic 계열만 저장 (용량 절약)
                let lower = name.lowercased()
                guard lower.contains("claude") || lower.contains("anthropic") else { continue }
                let input = (entry["input_cost_per_token"] as? Double) ?? 0
                let output = (entry["output_cost_per_token"] as? Double) ?? 0
                let cacheRead = (entry["cache_read_input_token_cost"] as? Double) ?? 0
                let cacheWrite = (entry["cache_creation_input_token_cost"] as? Double) ?? 0
                // per-token → per 1M tokens
                parsed[name] = ModelRates(
                    input: input * 1_000_000,
                    output: output * 1_000_000,
                    cacheRead: cacheRead * 1_000_000,
                    cacheWrite: cacheWrite * 1_000_000
                )
            }
            guard !parsed.isEmpty else { return }
            await MainActor.run {
                remote = parsed
                if let encoded = try? JSONEncoder().encode(parsed) {
                    UserDefaults.standard.set(encoded, forKey: cacheKey)
                    UserDefaults.standard.set(Date(), forKey: cacheDateKey)
                }
            }
        } catch {
            // 조용히 실패 — 다음 polling 때 재시도
        }
    }

    static func rates(for model: String?) -> ModelRates {
        guard let model = model else { return defaultRates }
        let lower = model.lowercased()
        // 1) 원격 정확 매치
        if let exact = remote[model] { return exact }
        // 2) 원격 부분 매치 (접미사/접두사 버전 차이)
        if let partial = remote.first(where: { lower.contains($0.key.lowercased()) || $0.key.lowercased().contains(lower) }) {
            return partial.value
        }
        // 3) 폴백 패턴 매칭
        for entry in fallbackRates where lower.contains(entry.pattern) {
            return entry.rates
        }
        return defaultRates
    }

    private static var defaultRates: ModelRates {
        fallbackRates.first { $0.pattern == "sonnet" }!.rates
    }

    static func cost(
        model: String?,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> Double {
        let r = rates(for: model)
        let perMillion = 1_000_000.0
        return (Double(input) * r.input
              + Double(output) * r.output
              + Double(cacheRead) * r.cacheRead
              + Double(cacheWrite) * r.cacheWrite) / perMillion
    }
}
