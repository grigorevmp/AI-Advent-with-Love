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

    /* Temperature = 0
    Максимальная точность, одинаковые ответы, почти без вариативности. Подходит для кода, ТЗ, требований, инструкций, аналитики.

    Temperature = 0.7
    Баланс точности и гибкости. Ответы живые, но стабильные. Подходит для обычного чата, объяснений, ассистентов.

    Temperature = 1.2
    Высокая креативность, разнообразные формулировки, возможны неточности. Подходит для идей, мозгового штурма, творчества.*/
    @Published var temperature: Double = 0.7

    // Token accounting (estimated)
    @Published private(set) var requestTokensEstimate: Int = 0
    @Published private(set) var responseTokensEstimate: Int = 0
    @Published private(set) var totalTokensEstimate: Int = 0
    @Published private(set) var contextLimitTokens: Int = 0
    @Published private(set) var isOverContextLimit: Bool = false

    // Day 9 — compression settings/state
    @Published var compressionEnabled: Bool = true
    @Published var compressEveryNMessages: Int = 10
    @Published private(set) var lastSummaryText: String = ""
    @Published private(set) var compressionCount: Int = 0

    // Day 10 — external memory (JSON/SQLite; JSON implemented, SQLite placeholder)
    enum ExternalMemoryBackend: String, CaseIterable, Identifiable {
        case jsonFile = "JSON"
        case sqlite = "SQLite"
        var id: String { rawValue }
    }

    @Published var externalMemoryEnabled: Bool = true
    @Published var externalMemoryBackend: ExternalMemoryBackend = .jsonFile
    @Published private(set) var memoryStatusText: String = ""

    private let maxOutputTokens: Int = 700

    private let client = GroqClient()

    // Compression storage
    private var rollingSummary: String = ""   // kept out of UI; lastSummaryText is for UI

    // External memory file
    private var memoryFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("ai_advent_memory.json")
    }

    init() {
        // Default behavior for the current homework: questions first, then FINAL JSON.
        systemPrompt = SystemPromptPreset.questionsThenFinalJSON.promptText
        systemPromptHistory.append(.init(time: Date(), oldPrompt: "", newPrompt: systemPrompt, note: "Initial"))

        // Load external memory (if any)
        loadExternalMemoryIfPresent()
    }

    /// Clears the dialog and allows starting a new TЗ collection flow
    func clearDialog() {
        messages.removeAll()
        inputText = ""
        errorText = nil
        lastParsed = nil
        lastRawJSON = nil
        isFinalResultReady = false

        rollingSummary = ""
        lastSummaryText = ""
        compressionCount = 0

        // keep system prompt, but mark restart
        systemPromptHistory.append(
            .init(time: Date(), oldPrompt: systemPrompt, newPrompt: systemPrompt, note: "Dialog cleared")
        )
    }

    // MARK: - Day 10: External memory (JSON)

    private struct MemorySnapshot: Codable {
        var savedAtISO: String
        var rollingSummary: String
        var lastSummaryText: String
        var compressionCount: Int
        var notes: String?
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func loadExternalMemoryIfPresent() {
        guard externalMemoryEnabled else { return }
        guard FileManager.default.fileExists(atPath: memoryFileURL.path) else {
            memoryStatusText = "No saved memory"
            return
        }

        do {
            let data = try Data(contentsOf: memoryFileURL)
            let snap = try JSONDecoder().decode(MemorySnapshot.self, from: data)
            rollingSummary = snap.rollingSummary
            lastSummaryText = snap.lastSummaryText
            compressionCount = snap.compressionCount
            memoryStatusText = "Loaded: \(snap.savedAtISO)"
        } catch {
            memoryStatusText = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    func saveExternalMemory(notes: String? = nil) {
        guard externalMemoryEnabled else {
            memoryStatusText = "External memory disabled"
            return
        }
        switch externalMemoryBackend {
        case .jsonFile:
            do {
                let snap = MemorySnapshot(
                    savedAtISO: isoNow(),
                    rollingSummary: rollingSummary,
                    lastSummaryText: lastSummaryText,
                    compressionCount: compressionCount,
                    notes: notes
                )
                let data = try JSONEncoder().encode(snap)
                try data.write(to: memoryFileURL, options: [.atomic])
                memoryStatusText = "Saved: \(snap.savedAtISO)"
            } catch {
                memoryStatusText = "Failed to save memory: \(error.localizedDescription)"
            }

        case .sqlite:
            // Placeholder: will be implemented later
            memoryStatusText = "SQLite backend not implemented yet"
        }
    }

    func clearExternalMemory() {
        do {
            if FileManager.default.fileExists(atPath: memoryFileURL.path) {
                try FileManager.default.removeItem(at: memoryFileURL)
            }
            rollingSummary = ""
            lastSummaryText = ""
            compressionCount = 0
            memoryStatusText = "Cleared"
        } catch {
            memoryStatusText = "Failed to clear: \(error.localizedDescription)"
        }
    }

    // MARK: - Day 9: Compression

    /// Build a compact context for the model: system + (optional summary) + recent tail.
    private func buildContextMessages(system: Message, history: [Message]) -> [Message] {
        if rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [system] + history
        }

        let summaryMsg = Message(
            role: "system",
            content: "Conversation summary (use as context, do not quote verbatim):\n" + rollingSummary
        )
        return [system, summaryMsg] + history
    }

    /// Summarize older dialog into `rollingSummary` and optionally drop old messages.
    /// Implementation: when message count reaches N, summarize everything except last `keepLast` messages.
    private func compressIfNeededAfterAssistantReply() async {
        guard compressionEnabled else { return }
        guard compressEveryNMessages >= 5 else { return }

        // Count only real dialog messages (user/assistant). When enough accumulated, compress.
        let total = messages.count
        guard total >= compressEveryNMessages else { return }

        // Keep a tail to preserve local coherence.
        let keepLast = min(8, total) // keep last 8 messages
        let prefixCount = max(0, total - keepLast)
        guard prefixCount >= 2 else { return }

        // Build text for summarization from the prefix
        let prefix = messages.prefix(prefixCount)
        let sourceText = prefix
            .map { msg in
                let who = (msg.role == .user) ? "User" : "Assistant"
                return "\(who): \(msg.text)"
            }
            .joined(separator: "\n")

        // Call the same provider to summarize (short, factual)
        guard let apiKey = loadAPIKey(for: selectedProvider), !apiKey.isEmpty else { return }
        let provider: GroqClient.Provider = (selectedProvider == .groq) ? .groq : .claude

        let summarizeSystem = Message(role: "system", content: "You summarize dialog for memory. Output plain text (no JSON). Focus on facts, decisions, constraints, open questions. Keep it compact.")
        let summarizeUser = Message(role: "user", content: "Existing summary (may be empty):\n\(rollingSummary)\n\nSummarize and merge the following dialog chunk:\n\(sourceText)\n\nReturn UPDATED summary only.")

        do {
            let summary = try await client.chat(
                provider: provider,
                apiKey: apiKey,
                systemPrompt: summarizeSystem.content,
                messages: [summarizeSystem, summarizeUser],
                model: (provider == .groq) ? "llama-3.1-8b-instant" : "claude-sonnet-4-20250514",
                maxTokens: 350,
                temperature: 0.2
            )

            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                rollingSummary = trimmed
                lastSummaryText = trimmed
                compressionCount += 1

                // Drop the summarized prefix from visible messages
                messages.removeFirst(prefixCount)

                // Persist memory between runs (optional)
                if externalMemoryEnabled {
                    saveExternalMemory(notes: "Auto-save after compression")
                }
            }
        } catch {
            // Non-fatal: do not break chat
            memoryStatusText = "Compression failed: \(error.localizedDescription)"
        }
    }

    /// Manual compression trigger for UI.
    func compressNow() {
        Task {
            await compressIfNeededAfterAssistantReply()
        }
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


    enum LLMProvider: String, CaseIterable, Identifiable {
        case groq = "Groq"
        case claude = "Claude"
        var id: String { rawValue }
    }

    /// Selected provider. UI can bind to this.
    @Published var selectedProvider: LLMProvider = .groq

    func saveAPIKey(_ key: String) {
        saveAPIKey(key, for: selectedProvider)
    }

    func saveAPIKey(_ key: String, for provider: LLMProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "Похоже, это не ключ"
            return
        }

        switch provider {
        case .groq:
            do {
                try KeychainStore.shared.saveGroqAPIKey(trimmed)
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }

        case .claude:
            do {
                try KeychainStore.shared.saveClaudeAPIKey(trimmed)
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func hasAPIKey() -> Bool {
        hasAPIKey(for: selectedProvider)
    }

    func hasAPIKey(for provider: LLMProvider) -> Bool {
        return (loadAPIKey(for: provider)?.isEmpty == false)
    }

    private func loadAPIKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .groq:
            return KeychainStore.shared.loadGroqAPIKey()
        case .claude:
            return KeychainStore.shared.loadClaudeAPIKey()
        }
    }

    private func effectiveTemperature(for provider: LLMProvider) -> Double {
        let t = temperature
        switch provider {
        case .groq:
            // Groq doc: 0 is converted internally; keep > 0 and <= 2
            return min(max(t, 1e-8), 2.0)
        case .claude:
            // Claude temperature is typically 0..1
            return min(max(t, 0.0), 1.0)
        }
    }

    /// Conservative context limits for the selected models.
    /// - Groq llama-3.1-8b-instant: 131072
    /// - Claude Sonnet 4 (standard): 200000 (1M requires beta header)
    private func contextLimit(for provider: LLMProvider) -> Int {
        switch provider {
        case .groq:
            return 131_072
        case .claude:
            return 200_000
        }
    }

    /// Very lightweight token estimator (no tiktoken on iOS by default).
    /// Uses max(words, chars/4) heuristic which is good enough for homework comparisons.
    private func estimateTokens(_ text: String) -> Int {
        if text.isEmpty { return 0 }

        // Word-ish count
        let wordLike = text
            .split { ch in
                ch.isWhitespace || ",.;:!?()[]{}\n\r\t\"'“”«»–—".contains(ch)
            }
            .count

        let charCount = text.count
        let charHeuristic = Int(ceil(Double(charCount) / 4.0))

        return max(wordLike, charHeuristic)
    }

    private func updateTokenAccountingBeforeSend(system: Message, history: [Message], provider: LLMProvider) {
        let promptText = ([system] + history)
            .map { $0.content }
            .joined(separator: "\n")

        let req = estimateTokens(promptText)
        let limit = contextLimit(for: provider)

        requestTokensEstimate = req
        responseTokensEstimate = 0
        totalTokensEstimate = req
        contextLimitTokens = limit

        // We also need room for the model output.
        isOverContextLimit = (req + maxOutputTokens) > limit
    }

    private func updateTokenAccountingAfterReply(_ reply: String) {
        let resp = estimateTokens(reply)
        responseTokensEstimate = resp
        totalTokensEstimate = requestTokensEstimate + resp
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

                // Use a limited tail of visible messages; older context is stored in rollingSummary.
                let tail: [Message] = messages.suffix(12).map {
                    Message(role: $0.role == .user ? "user" : "assistant", content: $0.text)
                }

                let contextMessages: [Message] = buildContextMessages(system: system, history: tail)

                // Token accounting + over-limit guard (based on actual context we send)
                // Note: we account system+summary+tail by passing `history: contextMessages` without the system.
                // We'll compute accounting using a synthetic split to avoid changing estimator signature.
                let accSystem = contextMessages.first ?? system
                let accHistory = Array(contextMessages.dropFirst())
                updateTokenAccountingBeforeSend(system: accSystem, history: accHistory, provider: selectedProvider)

                if isOverContextLimit {
                    throw NSError(
                        domain: "Chat",
                        code: 413,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Запрос слишком длинный: ~\(requestTokensEstimate) токенов (+ ответ до \(maxOutputTokens)) > лимит \(contextLimitTokens). Укороти запрос или очисти диалог."
                        ]
                    )
                }

                guard let apiKey = loadAPIKey(for: selectedProvider), !apiKey.isEmpty else {
                    throw NSError(domain: "Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key не задан. Сначала сохраните ключ в настройках."])
                }

                // Universal client call (Groq / Claude)
                let provider: GroqClient.Provider = (selectedProvider == .groq) ? .groq : .claude

                let reply = try await client.chat(
                    provider: provider,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    messages: contextMessages,
                    model: (provider == .groq) ? "llama-3.1-8b-instant" : "claude-sonnet-4-20250514",
                    maxTokens: maxOutputTokens,
                    temperature: effectiveTemperature(for: selectedProvider)
                )

                messages.append(ChatMessage(role: .assistant, text: reply))
                updateTokenAccountingAfterReply(reply)
                handleLLMFinalText(reply)

                // Attempt compression after a successful assistant turn
                await compressIfNeededAfterAssistantReply()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorText = msg
                messages.append(ChatMessage(role: .assistant, text: "Ошибка: \(msg)"))
            }
        }
    }
}
