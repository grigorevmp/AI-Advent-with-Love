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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            messagesList
            Divider().opacity(0.2)
            composer
        }
        .onAppear {
            // если ключ уже есть — просто покажем, что он сохранён (не выводим его)
            if vm.hasAPIKey() {
                apiKeyInput = "*Change to edit*"
            }
            promptDraft = vm.systemPrompt
            selectedPreset = .questionsThenFinalJSON
        }
        .sheet(isPresented: $isShowingParsedDialog) {
            ParsedResponseSheet(message: selectedMessageForExtend)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day 5")
                        .font(.headline)
                    Text("Agent chat (Changing system prompt)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if vm.isSending { ProgressView() }
            }

            HStack(spacing: 10) {
                TextField("Вставь GroqClient api key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                Button("Сохранить") {
                    if !apiKeyInput.isEmpty {
                        vm.saveAPIKey(apiKeyInput)
                        apiKeyInput = "******** (saved in Keychain)"
                    } else {
                        vm.errorText = "Похоже, это не ключ"
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            // System prompt panel
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPromptPanelExpanded.toggle()
                    }
                    if isPromptPanelExpanded {
                        // keep draft in sync when opening
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
                            // Apply preset and update draft so user can further tweak
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
                                // keep in sync
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

        guard let jsonString = JSONExtractor.extractFirstJSONObject(from: text) else {
            // Not a JSON message (most likely a clarifying question)
            return
        }

        rawJSON = jsonString

        guard let data = jsonString.data(using: String.Encoding.utf8) else {
            parseError = "Не удалось преобразовать JSON в UTF-8 data."
            return
        }

        do {
            parsed = try JSONDecoder().decode(AgentResponse.self, from: data)
        } catch {
            parseError = "Ошибка парсинга JSON: \(error.localizedDescription)"
        }
    }
}
