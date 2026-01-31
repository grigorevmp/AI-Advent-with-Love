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
    enum ExternalMemoryScope: String, CaseIterable, Identifiable {
        case summaryOnly = "Summary"
        case fullDialog = "Full dialog"
        case both = "Both"
        var id: String { rawValue }
    }
    enum ExternalMemoryBackend: String, CaseIterable, Identifiable {
        case jsonFile = "JSON"
        case sqlite = "SQLite"
        var id: String { rawValue }
    }

    @Published var externalMemoryEnabled: Bool = true
    @Published var externalMemoryBackend: ExternalMemoryBackend = .jsonFile

    /// What exactly we persist between launches.
    @Published var externalMemoryScope: ExternalMemoryScope = .both

    /// If true — auto-save memory on each send (user message and/or after assistant reply).
    @Published var externalMemoryAutoSaveOnSend: Bool = true

    /// Optional note attached to the next manual save (UI can set this later).
    @Published var externalMemoryNoteDraft: String = ""

    @Published private(set) var memoryStatusText: String = ""

    /// Day 10 — retrieval settings (very simple baseline)
    private let memoryRetrievalMaxSnippets: Int = 6
    private let memoryRetrievalMaxCharsPerSnippet: Int = 420

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

        // Compression state (Day 9)
        var rollingSummary: String
        var lastSummaryText: String
        var compressionCount: Int

        // Dialog state (Day 10)
        var scope: String
        var dialog: [StoredChatMessage]?

        // Optional free-form note
        var notes: String?
    }

    private struct StoredChatMessage: Codable {
        var role: String   // "user" | "assistant"
        var text: String
        var createdAtISO: String
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func toStored(_ msg: ChatMessage) -> StoredChatMessage {
        let role: String = (msg.role == .user) ? "user" : "assistant"
        return StoredChatMessage(role: role, text: msg.text, createdAtISO: isoNow())
    }

    private func fromStored(_ stored: StoredChatMessage) -> ChatMessage {
        let role: ChatMessage.Role = (stored.role == "user") ? .user : .assistant
        return ChatMessage(role: role, text: stored.text)
    }

    func loadExternalMemoryIfPresent(forceRestoreDialog: Bool = false) {
        guard externalMemoryEnabled else { return }
        guard FileManager.default.fileExists(atPath: memoryFileURL.path) else {
            memoryStatusText = "No saved memory (file not found)"
            return
        }

        do {
            let data = try Data(contentsOf: memoryFileURL)
            let snap = try JSONDecoder().decode(MemorySnapshot.self, from: data)

            // Restore compression state
            rollingSummary = snap.rollingSummary
            lastSummaryText = snap.lastSummaryText
            compressionCount = snap.compressionCount

            // Restore scope if present
            if let s = ExternalMemoryScope(rawValue: snap.scope) {
                externalMemoryScope = s
            }

            // Restore dialog only if snapshot has it and current dialog is empty or forceRestoreDialog is true
            if let dialog = snap.dialog, (messages.isEmpty || forceRestoreDialog) {
                let restored = dialog.map { fromStored($0) }
                messages = restored
            }

            memoryStatusText = "Loaded: \(snap.savedAtISO)"
        } catch {
            memoryStatusText = "Failed to load memory: \(error.localizedDescription)"
        }
    }

    /// Reads external memory snapshot from disk (JSON backend only). Returns nil if missing/failed.
    private func readMemorySnapshotIfPresent() -> MemorySnapshot? {
        guard externalMemoryEnabled else { return nil }
        guard externalMemoryBackend == .jsonFile else { return nil }
        guard FileManager.default.fileExists(atPath: memoryFileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: memoryFileURL)
            return try JSONDecoder().decode(MemorySnapshot.self, from: data)
        } catch {
            // Keep status, but don't crash the chat.
            memoryStatusText = "Failed to read memory: \(error.localizedDescription)"
            return nil
        }
    }

    private func normalizeQueryTokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let parts = lowered
            .split { ch in
                ch.isWhitespace || ",.;:!?()[]{}\n\r\t\"'“”«»–—/\\|@#№$%^&*+=<>".contains(ch)
            }
            .map(String.init)

        // Drop tiny tokens to reduce noise.
        return parts.filter { $0.count >= 3 }
    }

    /// Baseline retrieval: score each stored message by how many query tokens it contains.
    /// Returns up to `memoryRetrievalMaxSnippets` short snippets.
    private func retrieveMemorySnippets(for userQuery: String) -> [String] {
        guard externalMemoryEnabled else { return [] }
        guard let snap = readMemorySnapshotIfPresent() else { return [] }

        let tokens = normalizeQueryTokens(userQuery)
        guard !tokens.isEmpty else {
            // If the user asks a generic "о чем мы говорили", return the latest few messages.
            if let dialog = snap.dialog, !dialog.isEmpty {
                let tail = dialog.suffix(6)
                return tail.map { stored in
                    let who = (stored.role == "user") ? "User" : "Assistant"
                    return "\(who): \(stored.text)"
                }
            }
            return []
        }

        var scored: [(score: Int, text: String)] = []

        if let dialog = snap.dialog {
            for m in dialog {
                let hay = m.text.lowercased()
                var s = 0
                for t in tokens {
                    if hay.contains(t) { s += 1 }
                }
                if s > 0 {
                    let who = (m.role == "user") ? "User" : "Assistant"
                    scored.append((s, "\(who): \(m.text)"))
                }
            }
        }

        // Also consider rolling summary as a single candidate.
        let sum = snap.rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sum.isEmpty {
            let hay = sum.lowercased()
            var s = 0
            for t in tokens {
                if hay.contains(t) { s += 1 }
            }
            if s > 0 {
                scored.append((s, "Summary: \(sum)"))
            }
        }

        if scored.isEmpty {
            // If nothing matched, return the latest few messages so the model at least has context.
            if let dialog = snap.dialog, !dialog.isEmpty {
                let tail = dialog.suffix(6)
                return tail.map { stored in
                    let who = (stored.role == "user") ? "User" : "Assistant"
                    return "\(who): \(stored.text)"
                }
            }
            return []
        }

        // Sort by score desc, keep best.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.text.count < b.text.count
        }

        return scored.prefix(memoryRetrievalMaxSnippets).map { item in
            var t = item.text
            if t.count > memoryRetrievalMaxCharsPerSnippet {
                let idx = t.index(t.startIndex, offsetBy: memoryRetrievalMaxCharsPerSnippet)
                t = String(t[..<idx]) + "…"
            }
            return t
        }
    }

    /// Public helper for UI/debug: re-load memory from disk (optionally overriding current messages).
    func restoreFromExternalMemory(forceDialog: Bool = false) {
        loadExternalMemoryIfPresent(forceRestoreDialog: forceDialog)
    }

    func saveExternalMemory(notes: String? = nil) {
        guard externalMemoryEnabled else {
            memoryStatusText = "External memory disabled"
            return
        }

        switch externalMemoryBackend {
        case .jsonFile:
            do {
                // Всегда сохраняем всё, чтобы память реально работала как долговременная.
                // Scope влияет только на то, что мы подмешиваем в контекст, а не на хранение.
                let scope = externalMemoryScope

                let rolling = rollingSummary
                let last = lastSummaryText
                let count = compressionCount

                // Всегда сохраняем полный диалог
                let dialog: [StoredChatMessage] = messages.map { toStored($0) }

                let snap = MemorySnapshot(
                    savedAtISO: isoNow(),
                    rollingSummary: rolling,
                    lastSummaryText: last,
                    compressionCount: count,
                    scope: scope.rawValue,
                    dialog: dialog,
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
            if externalMemoryScope == .fullDialog || externalMemoryScope == .both {
                // We clear the persisted file, but do NOT force-clear the on-screen dialog unless you want it.
                // Keep current messages intact; user can press "New" in UI to clear.
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

    /// Build a compact context for the model: system + (optional retrieved memory) + (optional summary) + recent tail.
    private func buildContextMessages(system: Message, history: [Message]) -> [Message] {
        var result: [Message] = [system]

        // (A) Retrieval: pull relevant snippets from external memory on every send.
        // We use the last user message as the query.
        if externalMemoryEnabled {
            let lastUserText = messages.last(where: { $0.role == .user })?.text ?? ""
            let snippets = retrieveMemorySnippets(for: lastUserText)
            memoryStatusText = "Retrieved: \(snippets.count) snippets"
            if !snippets.isEmpty {
                let joined = snippets.joined(separator: "\n")
                let memMsg = Message(
                    role: "system",
                    content: "Relevant memory (use as context, do not quote verbatim):\n" + joined
                )
                result.append(memMsg)
            }
        }

        // (B) Rolling summary from Day 9 (if present)
        if !rollingSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summaryMsg = Message(
                role: "system",
                content: "Conversation summary (use as context, do not quote verbatim):\n" + rollingSummary
            )
            result.append(summaryMsg)
        }

        // (C) Recent visible tail
        result.append(contentsOf: history)
        return result
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
        // Если экран пустой (после перезапуска/очистки) — сначала восстановим память,
        // потом добавим новое сообщение пользователя.
        if externalMemoryEnabled && messages.isEmpty {
            loadExternalMemoryIfPresent(forceRestoreDialog: false)
        }

        messages.append(ChatMessage(role: .user, text: text))
        
        if externalMemoryEnabled && externalMemoryAutoSaveOnSend {
            saveExternalMemory(notes: "Auto-save: user message")
        }
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
                if externalMemoryEnabled && externalMemoryAutoSaveOnSend {
                    saveExternalMemory(notes: "Auto-save: assistant reply")
                }
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
