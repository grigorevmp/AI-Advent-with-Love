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
        case missingSystemPrompt
        case badStatus(Int, String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingApiKey:
                return "Не задан Groq API Key (gsk_...)"
            case .missingSystemPrompt:
                return "Не задан systemPrompt для выбранного провайдера"
            case .badStatus(let code, let body):
                return "Groq вернул статус \(code): \(body)"
            case .decodeFailed(let raw):
                return "Не удалось распарсить ответ: \(raw)"
            }
        }
    }

    enum Provider: String, CaseIterable, Identifiable {
        case groq = "Groq" // Быстрый, неточный, бесплатный
        case claude = "Claude" // Долгий, точный, платный
        var id: String { rawValue }
    }

    private let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let claudeEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Backward-compatible Groq call (OpenAI-compatible endpoint).
    func chat(apiKey: String, messages: [Message], model: String = "llama-3.1-8b-instant") async throws -> String {
        try await chat(
            provider: .groq,
            apiKey: apiKey,
            systemPrompt: nil,
            messages: messages,
            model: model,
            maxTokens: nil,
            temperature: 0.7
        )
    }

    /// Universal chat for Groq (OpenAI-compatible) and Claude (Anthropic Messages API).
    /// - For `.claude`, `systemPrompt` is recommended; `messages` should contain only user/assistant history.
    func chat(
        provider: Provider,
        apiKey: String,
        systemPrompt: String?,
        messages: [Message],
        model: String,
        maxTokens: Int? = nil,
        temperature: Double? = 0.7
    ) async throws -> String {

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingApiKey }

        switch provider {
        case .groq:
            return try await chatGroq(apiKey: key, messages: messages, model: model, temperature: temperature)

        case .claude:
            // Claude uses system prompt separately; drop any system messages from the history.
            let history = messages.filter { $0.role != "system" }
            return try await chatClaude(
                apiKey: key,
                systemPrompt: systemPrompt ?? "",
                messages: history,
                model: model,
                maxTokens: maxTokens ?? 800,
                temperature: temperature
            )
        }
    }

    private func chatGroq(apiKey: String, messages: [Message], model: String, temperature: Double?) async throws -> String {
        let reqBody = ChatRequest(model: model, messages: messages, temperature: temperature)

        var req = URLRequest(url: groqEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            return (decoded.choices.first?.message.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ClientError.decodeFailed(raw)
        }
    }

    private func chatClaude(
        apiKey: String,
        systemPrompt: String,
        messages: [Message],
        model: String,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> String {

        // Claude Messages API
        var req = URLRequest(url: claudeEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Claude expects roles: user/assistant (system is separate)
        let claudeMsgs: [ClaudeMessage] = messages
            .filter { $0.role != "system" }
            .map { ClaudeMessage(role: $0.role, content: $0.content) }

        let body = ClaudeRequest(
            model: model,
            max_tokens: maxTokens,
            system: systemPrompt.isEmpty ? nil : systemPrompt,
            temperature: temperature,
            messages: claudeMsgs
        )

        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await session.data(for: req)
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.decodeFailed("No HTTPURLResponse")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode, raw)
        }

        do {
            let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            let out = decoded.content.compactMap { $0.text }.joined()
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Claude (Anthropic Messages API) DTOs

struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String?
    let temperature: Double?
    let messages: [ClaudeMessage]
}

struct ClaudeMessage: Encodable {
    let role: String   // "user" | "assistant"
    let content: String
}

struct ClaudeResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    let content: [ContentBlock]
}
