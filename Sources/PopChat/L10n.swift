import Foundation
import SwiftUI

/// Runtime-swappable localization for a SwiftPM app with no Xcode project.
///
/// Why not NSLocalizedString: it resolves through the main bundle's preferred
/// localization, which (a) follows only the SYSTEM language, and (b) is captured
/// at bundle load — an in-app language switch could not take effect without
/// relaunching. This helper looks up the table from a language directory chosen
/// live: the user's PopChat override ("appLanguage", Settings › General) when
/// set, else the system's resolved preference.
///
/// Tables live in Contents/Resources/<code>.lproj/Localizable.strings (copied
/// by build.sh next to the dependency bundles) and fall back to the development
/// language, English. A missing key returns the key itself, so a forgotten
/// translation degrades to readable English rather than an empty label.
///
/// String FORMAT: source strings stay in code as English literals wrapped in
/// `L(_:c:)` — the English text is BOTH the key and the fallback value. The
/// .strings files map English → translation. (No keys to invent, no lookup for
/// English users to pay; the fallback IS the correct rendering.)
enum L10n {
    /// User override: "system" (default), "en", "zh-Hans". Settings writes it;
    /// `LanguageChoice` is its UI face.
    static let languageKey = "appLanguage"
    /// Posted whenever the override changes, so every live window rebuilds its
    /// strings without a relaunch. Views observe it through `.onLanguageChange`.
    static let languageDidChange = Notification.Name("PopChatLanguageDidChange")

    private static let systemNames = Bundle.main.preferredLocalizations
    private static let available: [String] = {
        let dir = Bundle.main.resourceURL
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir?.path ?? ".")
        else { return [] }
        return entries.filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }()

    /// The language tables are read once and cached; a switch invalidates.
    private static var cache: [String: [String: String]] = [:]
    private static var cachedFor: String?
    private static let lock = NSLock()

    /// One non-ASCII char in the translation is enough to mark a table real —
    /// an empty or missing table must not be "selected" over the fallback.
    private static func hasContent(_ table: [String: String]) -> Bool {
        table.values.contains { $0.unicodeScalars.contains { !$0.isASCII } }
    }

    /// Resolves the override, falling back through the system preference when a
    /// table is missing or empty. "system" is the default stored value.
    static var currentLanguageCode: String {
        let override = UserDefaults.standard.string(forKey: languageKey) ?? "system"
        if override != "system", available.contains(override) {
            return override
        }
        for name in systemNames {
            if let match = available.first(where: { $0 == name || $0.hasPrefix(name + "-") }) {
                return match
            }
            // zh-Hant users should still get the zh-Hans table rather than
            // English — a related dialect beats a foreign language.
            if name == "zh-Hant", available.contains("zh-Hans") { return "zh-Hans" }
        }
        return available.first ?? "en"
    }

    static var usesSystemLanguage: Bool {
        (UserDefaults.standard.string(forKey: languageKey) ?? "system") == "system"
    }

    /// Re-read the table for `currentLanguageCode` (or test-inject another).
    /// Must NOT be called while holding the lock: it resolves the language and
    /// then takes the lock itself.
    static func reload(language: String? = nil) {
        let code = language ?? currentLanguageCode
        let table: [String: String]
        if let path = Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                       inDirectory: nil, forLocalization: code),
           let dict = NSDictionary(contentsOfFile: path) as? [String: String],
           hasContent(dict) {
            table = dict
        } else {
            table = [:]
        }
        lock.lock()
        defer { lock.unlock() }
        cache = [code: table]
        cachedFor = code
    }

    /// The resolved table (English fallback when the chosen one has none).
    /// NSLock is NOT reentrant, so the staleness check happens OUTSIDE the lock
    /// (reload takes it itself); the stale-then-reload race between threads
    /// costs at worst one extra table parse.
    private static func table() -> [String: String] {
        lock.lock()
        let stale = cachedFor != currentLanguageCode
        lock.unlock()
        if stale { reload() }
        lock.lock()
        defer { lock.unlock() }
        return cache[cachedFor ?? ""] ?? [:]
    }

    /// Translate `key`, with positional substitutes filled in order: {0} {1} …
    /// `c` disambiguates two different sentences that share English wording
    /// (e.g. a button label vs. an action row) but translate differently.
    static func string(_ key: String, c: String = "", _ args: [String]) -> String {
        var text = table()[key] ?? key
        for (index, arg) in args.enumerated() {
            text = text.replacingOccurrences(of: "{\(index)}", with: arg)
        }
        return text
    }

    /// Invalidate a memoized-language test hook.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        cachedFor = nil
    }
}

/// Shorthand so call sites read like prose: `L("Send")`, `L("… of …", "3 of 5")`.
@inline(__always)
func L(_ key: String, c: String = "", _ args: String...) -> String {
    L10n.string(key, c: c, args)
}

/// The language picker's choices (Settings › General › Language). "system" is
/// the shipped default and needs no table; the others must have tables.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L("Follow system")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// Writes the override, swaps the table, and tells every live window to
    /// rebuild its strings.
    func apply() {
        guard UserDefaults.standard.string(forKey: L10n.languageKey) ?? "system" != rawValue else { return }
        UserDefaults.standard.set(rawValue, forKey: L10n.languageKey)
        L10n.resetForTesting()
        NotificationCenter.default.post(name: L10n.languageDidChange, object: nil)
    }

    /// Names always in their own language, so the picker reads correctly from
    /// inside any language.
    static func selfNamed(_ code: String) -> String {
        switch code {
        case "zh-Hans": "简体中文"
        case "en": "English"
        default: code
        }
    }
}

extension View {
    /// Rebuild the subtree whenever the language override changes. Applied at
    /// the root of each window's content (panel, Settings) — rebuilding there
    /// re-resolves every L() in it.
    func onLanguageChange(action: (() -> Void)? = nil) -> some View {
        onReceive(NotificationCenter.default.publisher(for: L10n.languageDidChange)) { _ in
            action?()
        }
    }
}

/// Observable language tick: bumps on every override change so an
/// `@ObservedObject` holder re-renders. Simpler than the notification modifier
/// for views whose body reads L() deep inside child branches.
@MainActor
final class LanguageObserver: ObservableObject {
    @Published var tick = 0
    private var canceller: (any NSObjectProtocol)?

    init() {
        canceller = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick += 1 }
        }
    }
}
