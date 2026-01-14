//
//  ChatScreen.swift
//  Ai Advent Chat
//
//  Created by Mikhail Grigorev on 12.01.2026.
//

import SwiftUI

struct ChatScreen: View {

    @StateObject private var vm = ChatViewModel()
    @State private var apiKeyInput: String = ""
    @State private var isShowingParsedDialog: Bool = false

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
        }
        .sheet(isPresented: $isShowingParsedDialog) {
            ParsedResponseSheet(parsed: vm.lastParsed, rawJSON: vm.lastRawJSON)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Day 1")
                        .font(.headline)
                    Text("Groq API + мое первое ios приложение :)")
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
                            showExtend: msg.role == .assistant && msg.id == vm.messages.last?.id && vm.lastParsed != nil,
                            onExtend: { isShowingParsedDialog = true }
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
                Button("Extend") {
                    onExtend()
                }
                .font(.footnote)
                .buttonStyle(.bordered)
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
    let parsed: AgentResponse?
    let rawJSON: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let parsed {
                        Group {
                            LabeledContent("Time", value: parsed.time)
                            LabeledContent("Title", value: parsed.title)
                            LabeledContent("AI role", value: parsed.ai_role)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Key tags").font(.subheadline).foregroundStyle(.secondary)
                                Text(parsed.key_tags.joined(separator: ", "))
                                    .font(.body)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Answer").font(.subheadline).foregroundStyle(.secondary)
                                Text(parsed.answer)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)

                        Divider().opacity(0.2)
                    } else {
                        Text("Parsed response is not available (JSON parse failed).")
                            .foregroundStyle(.secondary)
                    }

                    if let rawJSON {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Raw JSON").font(.subheadline).foregroundStyle(.secondary)
                            Text(rawJSON)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Parsed Agent Response")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
