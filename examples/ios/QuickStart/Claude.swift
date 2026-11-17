import Foundation

/// A small streaming client for the Claude Messages API. Swift has no official
/// Anthropic SDK, so this is plain HTTP + server-sent events.
struct Claude {
    struct Message {
        let role: String // "user" or "assistant"
        let text: String
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case api(String)
        case refused

        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your Anthropic API key first."
            case .http(let code, let message): return "Claude answered \(code): \(message)"
            case .api(let message): return message
            case .refused: return "Claude declined to answer that."
            }
        }
    }

    /// Any Claude model works here. Swap it for "claude-haiku-5-5" for the fastest, cheapest replies.
    var model = "claude-opus-5-5"
    var apiKey: String?

    /// Streams the answer to `messages`, text piece by text piece.
    func stream(system: String, messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw Failure.http(status, Self.errorMessage(in: Data(body.utf8)) ?? body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = Data(line.dropFirst(5).utf8)
                        guard let event = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
                        switch event["type"] as? String {
                        case "content_block_delta":
                            // Only text: thinking deltas and the rest are skipped.
                            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                                throw Failure.refused
                            }
                        case "error":
                            throw Failure.api(Self.errorMessage(in: json) ?? "Claude stopped with an error.")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(system: String, messages: [Message]) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw Failure.noKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // If a safety check declines a request, the API retries it on a fallback model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] },
            // Low effort: quick, short spoken answers.
            "output_config": ["effort": "low"],
            "fallbacks": "default",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func errorMessage(in data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }
}
