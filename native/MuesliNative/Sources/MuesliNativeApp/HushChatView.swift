import AppKit
import SwiftUI

struct HushChatView: View {
    @ObservedObject var model: AppModel
    @State private var question = ""
    @FocusState private var focused: Bool
    private let recipes: [(String, String)] = [
        ("List recent todos", "List the action items and todos from my recent meetings, with owners."),
        ("Write weekly recap", "Write a concise recap of this week's meetings: decisions, open questions, next steps."),
        ("Draft follow-up email", "Draft a follow-up email for my most recent meeting."),
        ("Summarize decisions", "What decisions were made across my recent meetings?"),
        ("Who did I meet with?", "Who did I meet with recently, and what did we discuss?")
    ]
    private var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Ask anything" : "Hi \(first), ask anything"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                PageTitle("Chat")
                Text(greeting).font(MuesliTheme.title1())
                    .padding(.top, MuesliTheme.spacing32)
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    TextField("Ask about your meetings", text: $question, axis: .vertical)
                        .textFieldStyle(.plain).font(MuesliTheme.body())
                        .focused($focused).onSubmit(send)
                    HStack {
                        Text("Answers use your encrypted meeting library")
                            .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                        Spacer()
                        Button(action: send) { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderedProminent).tint(MuesliTheme.accent)
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    }
                }
                .padding(MuesliTheme.spacing20)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
                Text("Recipes").font(MuesliTheme.headline())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: MuesliTheme.spacing12) {
                    ForEach(recipes, id: \.0) { recipe in
                        Button(recipe.0) { question = recipe.1; send() }
                            .buttonStyle(.bordered).disabled(model.busy)
                    }
                }
                if model.busy { ProgressView("Thinking…") }
                if !model.answer.isEmpty {
                    Text(model.answer).font(MuesliTheme.body()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MuesliTheme.spacing20)
                        .background(MuesliTheme.backgroundRaised)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
                }
                if let error = model.error { Text(error).foregroundStyle(MuesliTheme.recording).textSelection(.enabled) }
            }
            .padding(MuesliTheme.spacing24)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .background(MuesliTheme.backgroundBase)
        .foregroundStyle(MuesliTheme.textPrimary)
        .onAppear { focused = true }
    }

    private func send() {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        model.run { try await model.ask(prompt) }
    }
}

struct HushStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.testMode {
                HStack {
                    Image(systemName: "testtube.2")
                    Text("TEST MODE — external services mocked")
                    Spacer()
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(MuesliTheme.spacing12)
                .background(MuesliTheme.backgroundRaised)
            }
            if model.busy || model.recording || model.error != nil {
                HStack(spacing: MuesliTheme.spacing12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.error ?? model.status).font(MuesliTheme.caption()).lineLimit(3)
                    Spacer()
                    if model.error != nil {
                        Button("Dismiss") { model.error = nil }.buttonStyle(.borderless)
                    }
                }
                .foregroundStyle(model.error == nil ? MuesliTheme.textSecondary : MuesliTheme.recording)
                .padding(MuesliTheme.spacing12)
                .background(MuesliTheme.backgroundRaised)
            }
        }
    }
}
