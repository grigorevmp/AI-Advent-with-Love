//
//  StreamingChatClient.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import Foundation

final class StreamingChatClient {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
    }

    enum ClientError: Error, LocalizedError {
        case badStatus(Int, String)
        case invalidEvent(String)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body): return "HTTP \(code): \(body)"
            case .invalidEvent(let s): return "Bad SSE event: \(s)"
            }
        }
    }

    let endpoint: URL
    let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Вызывает onDelta на каждом кусочке текста
    func streamChat(
        apiKey: String,
        model: String,
        messages: [Message],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws {

        let body = RequestBody(model: model, messages: messages, stream: true, temperature: 0.7)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, resp) = try await session.bytes(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.badStatus(-1, "No HTTPURLResponse")
        }
        guard (200...299).contains(http.statusCode) else {
            // Прочитаем тело ошибки (AsyncBytes -> Data) с лимитом, чтобы не зависнуть на больших ответах
            let errData = try await readAll(bytes: bytes, limit: 64 * 1024)
            throw ClientError.badStatus(http.statusCode, String(data: errData, encoding: .utf8) ?? "")
        }

        // SSE: строки вида "data: {...}" и пустая строка как разделитель событий
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" { break }
            guard let json = payload.data(using: .utf8) else { continue }

            // OpenAI-compatible streaming event:
            // { "choices": [ { "delta": { "content": "..." } } ] }
            if let chunk = parseDeltaContent(from: json) {
                await onDelta(chunk)
            }
        }
    }

    private func parseDeltaContent(from data: Data) -> String? {
        struct Event: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }
        return (try? JSONDecoder().decode(Event.self, from: data))?.choices.first?.delta.content
    }
    // Helper to read all data from AsyncBytes with a size limit
    private func readAll(bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(limit, 4096))

        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}
