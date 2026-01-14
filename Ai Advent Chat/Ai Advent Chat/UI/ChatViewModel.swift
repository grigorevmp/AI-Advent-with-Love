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

    private let systemPrompt: String = """
Ты — агент для сбора требований и подготовки итогового результата (ТЗ).

ВАЖНОЕ ПРАВИЛО ФОРМАТА (ДВА РЕЖИМА):
1) УТОЧНЯЮЩИЕ ВОПРОСЫ (когда данных недостаточно)
- Отвечай Обычным текстом (НЕ JSON).
- Никаких тегов, никаких ключей, никаких фигурных скобок.
- В ответе должен быть ОДИН следующий вопрос + при необходимости 1–2 пункта что уже понятно.

2) ФИНАЛЬНЫЙ РЕЗУЛЬТАТ (когда данных достаточно)
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

ПРАВИЛА ДЛЯ ФИНАЛА:
- title = "FINAL_TZ"
- ai_role всегда "assistant"
- key_tags: 3–8 тегов, lower_snake_case; ОБЯЗАТЕЛЬНО включи "final" и 2–3 тега по теме (например: "tz", "requirements", "ios_app").
- answer содержит ГОТОВОЕ ТЗ целиком (структурировано: Цель, Контекст, Функциональные требования, НФТ, Ограничения, API/Интеграции, UX, Ошибки/логирование, Критерии приёмки).

Твоя цель — задавать вопросы до тех пор, пока не сможешь выдать финальный JSON.
"""

    private let maxOutputTokens: Int = 700

    private let client = GroqClient()

    init() {
        messages.append(
            ChatMessage(
                role: .assistant,
                text: "Привет! Я собираю требования и в конце выдам FINAL ТЗ в JSON-формате."
            )
        )
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

