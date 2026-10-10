import Foundation

/// A user-defined prompt shortcut, invoked as "/name input" in the chat field.
/// `{input}` in the template marks where the typed remainder goes; without a
/// placeholder the input is appended on a new line.
struct PromptShortcut: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var template: String

    func expand(input: String) -> String {
        if template.contains("{input}") {
            return template.replacingOccurrences(of: "{input}", with: input)
        }
        return input.isEmpty ? template : template + "\n\n" + input
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published var shortcuts: [PromptShortcut] {
        didSet { persist() }
    }

    private static let defaultsKey = "shortcutsJSON"

    /// Built-in commands, always available. They live OUTSIDE the persisted list
    /// on purpose: an upgrade must not have to migrate stored JSON to reach a new
    /// command, and deleting one in Settings must not break it either. A user
    /// shortcut with the same name takes precedence, so `/word` stays overridable.
    ///
    /// `/word` is the quick dictionary: send a bare `/word` (or `/word 剩余文字`)
    /// and the model glosses the word. Because the composer only completes a
    /// slash-command ONCE a name is typed, the empty-composer hint row makes the
    /// no-argument form discoverable.
    static let builtIns: [PromptShortcut] = [
        PromptShortcut(
            id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001")!,
            name: "word",
            template: """
            Define the word or phrase below. If it is English (or any language other than 中文), reply in 中文; if it is 中文, reply in English. Cover: part of speech, IPA or pinyin, core senses with one short example each, common collocations or usage notes, and nearby synonyms with what separates them. Keep it compact — this is a quick lookup, not an essay.

            {input}
            """
        ),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([PromptShortcut].self, from: data) {
            shortcuts = stored
        } else {
            shortcuts = [
                PromptShortcut(
                    id: UUID(),
                    name: "translate",
                    template: "Translate the following into natural, idiomatic English. Reply with the translation only:\n\n{input}"
                ),
                PromptShortcut(
                    id: UUID(),
                    name: "explain",
                    template: "Explain the following clearly and concisely, assuming a technical reader:\n\n{input}"
                ),
            ]
            persist()
        }
    }

    func match(name: String) -> PromptShortcut? {
        if let user = shortcuts.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return user
        }
        return Self.builtIns.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// Every command the composer's "/" popup should offer: user shortcuts plus
    /// the built-ins that aren't shadowed by one.
    var allCommands: [PromptShortcut] {
        shortcuts + Self.builtIns.filter { builtin in
            !shortcuts.contains { $0.name.compare(builtin.name, options: .caseInsensitive) == .orderedSame }
        }
    }

    func add() {
        shortcuts.append(PromptShortcut(id: UUID(), name: "new-shortcut", template: "…{input}"))
    }

    func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
