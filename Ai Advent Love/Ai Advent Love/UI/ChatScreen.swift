//
//  ChatScreen.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import SwiftUI
import UIKit

struct ChatScreen: View {

    @StateObject private var vm = ChatViewModel()
    @State private var apiKeyInput: String = ""
    @State private var isShowingParsedDialog: Bool = false
    @State private var selectedMessageForExtend: ChatMessage? = nil
    @State private var isPromptPanelExpanded: Bool = false
    @State private var selectedPreset: ChatViewModel.SystemPromptPreset = .questionsThenFinalJSON
    @State private var promptDraft: String = ""

    @State private var isSettingsExpanded: Bool = false

    // Day 9/10 UI
    @State private var isCompressionExpanded: Bool = false
    @State private var isMemoryExpanded: Bool = false
    @State private var isShowingSummarySheet: Bool = false
    @State private var isShowingMemorySheet: Bool = false

    private var tokenPlaceholder: String {
        switch vm.selectedProvider {
        case .groq: return "Вставь Groq API key"
        case .claude: return "Вставь Claude Platform API key"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            messagesList
            tokenStatsBar
            Divider().opacity(0.2)
            composer
        }
        .onAppear {
            // если ключ уже есть — просто покажем, что он сохранён (не выводим его)
            if vm.hasAPIKey() {
                apiKeyInput = "******** (saved)"
            }
            promptDraft = vm.systemPrompt
            selectedPreset = .questionsThenFinalJSON
        }
        .onChange(of: vm.selectedProvider) { _, _ in
            apiKeyInput = vm.hasAPIKey() ? "******** (saved)" : ""
            vm.errorText = nil
        }
        .sheet(isPresented: $isShowingParsedDialog) {
            ParsedResponseSheet(message: selectedMessageForExtend)
        }
        .sheet(isPresented: $isShowingSummarySheet) {
            NavigationStack {
                ScrollView {
                    Text(vm.lastSummaryText.isEmpty ? "(пока нет summary)" : vm.lastSummaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle("Summary")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { isShowingSummarySheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingMemorySheet) {
            NavigationStack {
                ScrollView {
                    Text(vm.memoryStatusText.isEmpty ? "(память пока не подключена)" : vm.memoryStatusText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle("Memory")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { isShowingMemorySheet = false }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day 5")
                        .font(.headline)
                    Text("Added system prompt set up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Clear / start new dialog
                Button {
                    vm.clearDialog()
                    apiKeyInput = vm.hasAPIKey() ? "******** (saved)" : ""
                    promptDraft = vm.systemPrompt
                    selectedMessageForExtend = nil
                } label: {
                    Label("New", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isSending || vm.messages.isEmpty)
                .accessibilityLabel("Clear chat")

                if vm.isSending { ProgressView() }
            }

            // Settings spoiler (provider + token + system prompt)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSettingsExpanded.toggle()
                    }
                    if isSettingsExpanded {
                        promptDraft = vm.systemPrompt
                        apiKeyInput = vm.hasAPIKey() ? "******** (saved)" : ""
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: isSettingsExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isSettingsExpanded {
                    VStack(alignment: .leading, spacing: 12) {

                        // Provider
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Provider")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Provider", selection: $vm.selectedProvider) {
                                ForEach(ChatViewModel.LLMProvider.allCases) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // Token
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API token")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                TextField(tokenPlaceholder, text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)

                                Button("Save") {
                                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

                                    if trimmed.isEmpty || trimmed == "******** (saved)" || trimmed.hasPrefix("********") {
                                        vm.errorText = "Вставь реальный ключ, а не маску"
                                        return
                                    }

                                    vm.saveAPIKey(trimmed)
                                    apiKeyInput = vm.hasAPIKey() ? "******** (saved)" : ""
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        Divider().opacity(0.2)

                        // Day 9 — History compression (nested spoiler)
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isCompressionExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "text.badge.plus")
                                    Text("History compression")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: isCompressionExpanded ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            if isCompressionExpanded {
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle("Enable compression", isOn: $vm.compressionEnabled)

                                    Stepper(value: $vm.compressEveryNMessages, in: 5...50, step: 1) {
                                        Text("Summarize every \(vm.compressEveryNMessages) messages")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack(spacing: 10) {
                                        Button {
                                            isShowingSummarySheet = true
                                        } label: {
                                            Label("Show summary", systemImage: "doc.text.magnifyingglass")
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            vm.compressNow()
                                        } label: {
                                            Label("Compress now", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!vm.compressionEnabled)

                                        Spacer()
                                    }

                                    Text("Idea: каждые N сообщений делаем summary и храним его вместо оригинала.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }

                        // Day 10 — External memory (nested spoiler)
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isMemoryExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "externaldrive")
                                    Text("External memory")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: isMemoryExpanded ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            if isMemoryExpanded {
                                VStack(alignment: .leading, spacing: 12) {
                                    Toggle("Enable external memory", isOn: $vm.externalMemoryEnabled)

                                    Picker("Backend", selection: $vm.externalMemoryBackend) {
                                        ForEach(ChatViewModel.ExternalMemoryBackend.allCases) { b in
                                            Text(b.rawValue).tag(b)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    HStack(spacing: 10) {
                                        Button {
                                            isShowingMemorySheet = true
                                        } label: {
                                            Label("View", systemImage: "eye")
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            vm.saveExternalMemory()
                                        } label: {
                                            Label("Save", systemImage: "square.and.arrow.down")
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!vm.externalMemoryEnabled)

                                        Button {
                                            vm.clearExternalMemory()
                                        } label: {
                                            Label("Clear", systemImage: "trash")
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!vm.externalMemoryEnabled)

                                        Spacer()
                                    }

                                    Text("Goal: хранить summary/факты/промежуточные результаты между запусками (JSON/SQLite).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }

                        Divider().opacity(0.2)

                        // System prompt (nested spoiler)
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isPromptPanelExpanded.toggle()
                                }
                                if isPromptPanelExpanded {
                                    promptDraft = vm.systemPrompt
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("System prompt")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: isPromptPanelExpanded ? "chevron.up" : "chevron.down")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            if isPromptPanelExpanded {
                                VStack(alignment: .leading, spacing: 10) {

                                    Picker("Preset", selection: $selectedPreset) {
                                        ForEach(ChatViewModel.SystemPromptPreset.allCases) { preset in
                                            Text(preset.rawValue).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .onChange(of: selectedPreset) { _, newValue in
                                        vm.applySystemPromptPreset(newValue)
                                        promptDraft = vm.systemPrompt
                                    }

                                    Text("Current system prompt")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)

                                    TextEditor(text: $promptDraft)
                                        .font(.system(.footnote, design: .monospaced))
                                        .frame(minHeight: 110, maxHeight: 180)
                                        .padding(8)
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    HStack {
                                        Button {
                                            vm.updateSystemPrompt(promptDraft, note: "Manual edit")
                                            promptDraft = vm.systemPrompt
                                        } label: {
                                            Label("Apply", systemImage: "checkmark.circle.fill")
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Spacer()

                                        Text("Changes: \(vm.systemPromptHistory.count)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    Divider().opacity(0.2)

                                    // Temperature
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Text("Temperature")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(String(format: "%.2f", vm.temperature))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }

                                        Slider(value: $vm.temperature, in: 0...2, step: 0.05)

                                        HStack(spacing: 8) {
                                            Button("0") { vm.temperature = 0 }
                                            Button("0.7") { vm.temperature = 0.7 }
                                            Button("1.2") { vm.temperature = 1.2 }
                                            Spacer()
                                            Text(vm.selectedProvider == .claude ? "Claude: >1 будет обрезано до 1.0" : "Groq: диапазон до 2.0")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    // Token usage (estimates)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Tokens (estimate)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)

                                        HStack(spacing: 10) {
                                            Text("req: \(vm.requestTokensEstimate)")
                                            Text("resp: \(vm.responseTokensEstimate)")
                                            Text("total: \(vm.totalTokensEstimate)")
                                            Spacer()
                                            Text("limit: \(vm.contextLimitTokens)")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(vm.isOverContextLimit ? .red : .secondary)

                                        if vm.isOverContextLimit {
                                            Text("Превышен лимит контекста: укороти запрос или очисти диалог")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }

                                    if !vm.systemPromptHistory.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Recent changes")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)

                                            ForEach(vm.systemPromptHistory.suffix(3)) { item in
                                                HStack(spacing: 8) {
                                                    Text(item.time, style: .time)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                    Text(item.note ?? "Updated")
                                                        .font(.caption)
                                                        .lineLimit(1)
                                                    Spacer()
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if let e = vm.errorText {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(
                            message: msg,
                            showExtend: msg.role == .assistant,
                            onExtend: {
                                selectedMessageForExtend = msg
                                isShowingParsedDialog = true
                            }
                        )
                        .id(msg.id)
                        .transition(bubbleTransition(for: msg.role))
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.messages.count)
            }
            .onChange(of: vm.messages.count) { _, _ in
                guard let last = vm.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var tokenStatsBar: some View {
        // Show only after the first send attempt (when we have a limit) or when we have any estimates.
        let shouldShow = vm.contextLimitTokens > 0 || vm.requestTokensEstimate > 0 || vm.responseTokensEstimate > 0

        return Group {
            if shouldShow {
                HStack(spacing: 10) {
                    Text("req: \(vm.requestTokensEstimate)")
                    Text("resp: \(vm.responseTokensEstimate)")
                    Text("total: \(vm.totalTokensEstimate)")
                    Spacer()
                    Text("limit: \(vm.contextLimitTokens)")
                }
                .font(.caption)
                .foregroundStyle(vm.isOverContextLimit ? .red : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
            } else {
                EmptyView()
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Напиши сообщение…", text: $vm.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)

            Button {
                vm.send()
            } label: {
                Text("Отправить").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isSending || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func bubbleTransition(for role: ChatMessage.Role) -> AnyTransition {
        let edge: Edge = (role == .assistant) ? .leading : .trailing
        let insertion = AnyTransition.opacity
            .combined(with: .move(edge: edge))
            .combined(with: .scale(scale: 0.98))
        return .asymmetric(insertion: insertion, removal: .opacity)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let showExtend: Bool
    let onExtend: () -> Void

    var body: some View {
        HStack {
            if message.role == .assistant { bubble; Spacer(minLength: 30) }
            else { Spacer(minLength: 30); bubble }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)

            if showExtend {
                HStack {
                    Button {
                        onExtend()
                    } label: {
                        Label("Extend", systemImage: "curlybraces")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor.opacity(0.2), lineWidth: 1)
        )
        .frame(maxWidth: 520, alignment: message.role == .assistant ? .leading : .trailing)
    }

    private var backgroundColor: Color {
        message.role == .assistant
        ? Color(UIColor.secondarySystemBackground)
        : Color.accentColor.opacity(0.15)
    }

    private var borderColor: Color {
        message.role == .assistant ? .primary : .accentColor
    }
}

private struct ParsedResponseSheet: View {
    let message: ChatMessage?

    @Environment(\.dismiss) private var dismiss

    @State private var parsed: AgentResponse? = nil
    @State private var rawJSON: String? = nil
    @State private var parseError: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    if let parseError {
                        Text(parseError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if let parsed {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent("Time", value: parsed.time)
                                LabeledContent("Title", value: parsed.title)
                                LabeledContent("AI role", value: parsed.ai_role)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Key tags")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(parsed.key_tags.joined(separator: ", "))
                                        .font(.body)
                                }

                                Divider().opacity(0.2)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Answer")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(parsed.answer)
                                        .font(.body)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("JSON не найден в этом сообщении.")
                            .foregroundStyle(.secondary)
                    }

                    if let rawJSON {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Raw JSON")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        UIPasteboard.general.string = rawJSON
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .font(.footnote)
                                    .buttonStyle(.bordered)
                                }

                                Text(rawJSON)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Extend")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                parseSelectedMessage()
            }
        }
    }

    private func parseSelectedMessage() {
        parseError = nil
        parsed = nil
        rawJSON = nil

        guard let text = message?.text, !text.isEmpty else {
            parseError = "Сообщение пустое."
            return
        }

        // 1) Try to extract JSON from fenced code block first
        if let fenced = extractFencedJSON(from: text) {
            tryParseAgentResponse(from: fenced)
            return
        }

        // 2) Try existing extractor (first JSON object)
        if let jsonString = JSONExtractor.extractFirstJSONObject(from: text) {
            tryParseAgentResponse(from: jsonString)
            return
        }

        // 3) Best-effort: if the whole message looks like JSON
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            tryParseAgentResponse(from: trimmed)
            return
        }

        // No JSON found (most likely a clarifying question)
    }

    private func tryParseAgentResponse(from json: String) {
        rawJSON = json

        guard let data = json.data(using: String.Encoding.utf8) else {
            parseError = "Не удалось преобразовать JSON в UTF-8 data."
            return
        }

        // First: direct decode
        if let direct = try? JSONDecoder().decode(AgentResponse.self, from: data) {
            parsed = direct
            return
        }

        // Fallback: normalize keys/types (case-insensitive, array/object)
        do {
            let any = try JSONSerialization.jsonObject(with: data)

            // If it's an array, take first object
            let obj: Any
            if let arr = any as? [Any], let first = arr.first {
                obj = first
            } else {
                obj = any
            }

            guard let dict = obj as? [String: Any] else {
                parseError = "JSON найден, но формат не объект."
                return
            }

            func valueCI(_ key: String) -> Any? {
                if let v = dict[key] { return v }
                let lower = key.lowercased()
                if let v = dict[lower] { return v }
                // search case-insensitively
                for (k, v) in dict {
                    if k.lowercased() == lower { return v }
                }
                return nil
            }

            let time = (valueCI("time") as? String) ?? ""
            let answer = (valueCI("answer") as? String) ?? (valueCI("content") as? String) ?? ""
            let title = (valueCI("title") as? String) ?? ""
            let aiRole = (valueCI("ai_role") as? String) ?? (valueCI("role") as? String) ?? "assistant"

            var tags: [String] = []
            if let t = valueCI("key_tags") as? [String] {
                tags = t
            } else if let t = valueCI("key_tags") as? String {
                tags = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if let t = valueCI("tags") as? [String] {
                tags = t
            }

            let normalized: [String: Any] = [
                "time": time,
                "answer": answer,
                "key_tags": tags,
                "title": title,
                "ai_role": aiRole
            ]

            let normData = try JSONSerialization.data(withJSONObject: normalized)
            parsed = try JSONDecoder().decode(AgentResponse.self, from: normData)
        } catch {
            parseError = "Ошибка парсинга JSON: \(error.localizedDescription)"
        }
    }

    private func extractFencedJSON(from text: String) -> String? {
        // Supports ```json ... ``` or ``` ... ```
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var inFence = false
        var buffer: [Substring] = []

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("```") {
                if inFence {
                    // end
                    break
                } else {
                    // start
                    inFence = true
                    continue
                }
            }
            if inFence {
                buffer.append(line)
            }
        }

        let candidate = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if candidate.hasPrefix("{") || candidate.hasPrefix("[") {
            return candidate
        }
        return nil
    }
}
