//
//  ChatViewModel.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var errorText: String? = nil

    @Published var lastParsed: AgentResponse? = nil
    @Published var lastRawJSON: String? = nil
    @Published var isFinalResultReady: Bool = false

    /// History of prompt changes during the dialog (for debugging / UI display)
    @Published private(set) var systemPromptHistory: [SystemPromptChange] = []

    @Published var systemPrompt: String = """
Ты — агент для ответа на вопросы

- Отвечай ТОЛЬКО валидным JSON-объектом строго по схеме ниже.
- Никакого текста до/после JSON. Никаких markdown. Только один JSON.

СХЕМА (ключи строго такие же):
{
  "time": "ISO-8601 строка с таймзоной",
  "answer": "...",
  "key_tags": ["..."],
  "title": "...",
  "ai_role": "assistant"
}

"""

    enum SystemPromptPreset: String, CaseIterable, Identifiable {
        case strictJSON = "Strict JSON"
        case questionsThenFinalJSON = "Questions then FINAL JSON"
        case freeForm = "Free form"

        var id: String { rawValue }

        var promptText: String {
            switch self {
            case .strictJSON:
                return """
Ты — агент для ответа на вопросы.

- Отвечай ТОЛЬКО валидным JSON-объектом строго по схеме ниже.
- Никакого текста до/после JSON. Никаких markdown. Только один JSON.

СХЕМА (ключи строго такие же):
{
  \"time\": \"ISO-8601 строка с таймзоной\",
  \"answer\": \"...\",
  \"key_tags\": [\"...\"],
  \"title\": \"...\",
  \"ai_role\": \"assistant\"
}
"""

            case .questionsThenFinalJSON:
                return """
Ты — агент, который помогает собрать данные и в какой-то момент выдать финальный результат.

Правила общения:
- Если данных недостаточно, задавай уточняющие вопросы обычным текстом (НЕ JSON, без тегов).
- Как только ты собрал достаточно информации, верни один финальный ответ ТОЛЬКО валидным JSON по схеме ниже.
- В финальном JSON обязательно добавь в key_tags тег \"final\".
- Никакого текста до/после финального JSON. Никаких markdown.

СХЕМА (ключи строго такие же):
{
  \"time\": \"ISO-8601 строка с таймзоной\",
  \"answer\": \"...\",
  \"key_tags\": [\"...\"],
  \"title\": \"...\",
  \"ai_role\": \"assistant\"
}
"""

            case .freeForm:
                return """
Ты — дружелюбный ассистент.
Отвечай обычным текстом, кратко и по делу.
"""
            }
        }
    }

    struct SystemPromptChange: Identifiable {
        let id = UUID()
        let time: Date
        let oldPrompt: String
        let newPrompt: String
        let note: String?
    }

    /// Update system prompt during an ongoing dialog.
    /// The next request will use the new prompt.
    func updateSystemPrompt(_ newPrompt: String, note: String? = nil) {
        let trimmed = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let old = systemPrompt
        systemPrompt = trimmed
        systemPromptHistory.append(.init(time: Date(), oldPrompt: old, newPrompt: trimmed, note: note))

        // If the new prompt switches to free-form, reset JSON parsing state to avoid confusion.
        // (We keep the message history intact.)
        if trimmed.contains("обычным текстом") || trimmed.lowercased().contains("free") {
            lastParsed = nil
            lastRawJSON = nil
        }
    }

    /// Convenience to set one of the built-in presets.
    func applySystemPromptPreset(_ preset: SystemPromptPreset) {
        updateSystemPrompt(preset.promptText, note: "Preset: \(preset.rawValue)")
    }

    private let maxOutputTokens: Int = 700

    private let client = GroqClient()

    init() {
        // Default behavior for the current homework: questions first, then FINAL JSON.
        systemPrompt = SystemPromptPreset.questionsThenFinalJSON.promptText
        systemPromptHistory.append(.init(time: Date(), oldPrompt: "", newPrompt: systemPrompt, note: "Initial"))
    }

    private func handleLLMFinalText(_ text: String) {
        guard let jsonString = JSONExtractor.extractFirstJSONObject(from: text) else {
            // Это уточняющий вопрос в обычном тексте — JSON нет, ничего не парсим
            return
        }
        lastRawJSON = jsonString

        guard let data = jsonString.data(using: String.Encoding.utf8) else {
            lastParsed = nil
            return
        }

        if let parsed = try? JSONDecoder().decode(AgentResponse.self, from: data) {
            lastParsed = parsed
            if parsed.key_tags.contains("final") {
                isFinalResultReady = true
            }
        } else {
            lastParsed = nil
        }
    }

    func saveAPIKey(_ key: String) {
        do {
            try KeychainStore.shared.saveAPIKey(key)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func hasAPIKey() -> Bool {
        return (KeychainStore.shared.loadAPIKey()?.isEmpty == false)
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if isFinalResultReady {
            errorText = "Результат уже сформирован (FINAL_TZ). Начните новый диалог, чтобы собрать новое ТЗ."
            return
        }

        inputText = ""
        errorText = nil
        lastParsed = nil
        lastRawJSON = nil
        messages.append(ChatMessage(role: .user, text: text))
        isSending = true

        Task {
            defer { isSending = false }
            do {
                let system: Message = .init(role: "system", content: systemPrompt)
                let history: [Message] = messages.suffix(12).map {
                    Message(role: $0.role == .user ? "user" : "assistant", content: $0.text)
                }

                guard let apiKey = KeychainStore.shared.loadAPIKey(), !apiKey.isEmpty else {
                    throw NSError(domain: "Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key не задан. Сначала сохраните ключ в настройках."])
                }

                // TODO: Добавь в GroqClient поддержку max_tokens и прокинь сюда maxOutputTokens,
                // чтобы модель автоматически ограничивала длину ответа.
                let reply = try await client.chat(
                    apiKey: apiKey,
                    messages: [system] + history,
                    model: "llama-3.1-8b-instant"
                )

                messages.append(ChatMessage(role: .assistant, text: reply))
                handleLLMFinalText(reply)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorText = msg
                messages.append(ChatMessage(role: .assistant, text: "Ошибка: \(msg)"))
            }
        }
    }
}
