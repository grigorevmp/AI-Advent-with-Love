//
//  GroqClient.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import Foundation

final class GroqClient {

    enum ClientError: Error, LocalizedError {
        case missingApiKey
        case badStatus(Int, String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "Не задан Groq API Key (gsk_...)"
            case .badStatus(let code, let body):
                return "Groq вернул статус \(code): \(body)"
            case .decodeFailed(let raw):
                return "Не удалось распарсить ответ: \(raw)"
            }
        }
    }

    private let session: URLSession
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")! //  [oai_citation:3‡Groq Community](https://community.groq.com/t/what-is-the-base-url-path-for-groq-api/487?utm_source=chatgpt.com)

    init(session: URLSession = .shared) {
        self.session = session
    }

    func chat(apiKey: String, messages: [Message], model: String = "llama-3.1-8b-instant") async throws -> String { //  [oai_citation:4‡GroqCloud](https://console.groq.com/docs/api-reference?utm_source=chatgpt.com)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingApiKey }

        let reqBody = ChatRequest(model: model, messages: messages)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await session.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.decodeFailed("No HTTPURLResponse")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode, raw)
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return (decoded.choices.first?.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ClientError.decodeFailed(raw)
        }
    }
}

// MARK: - OpenAI-compatible DTOs

struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double?

    init(model: String, messages: [Message], temperature: Double? = 0.7) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
    }
}

struct Message: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

struct ChatResponse: Decodable {
    let choices: [Choice]
}

struct Choice: Decodable {
    let message: Message
}
