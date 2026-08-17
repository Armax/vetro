import Foundation
import Observation
import Security

/// User settings from the design's Settings page, persisted to UserDefaults
/// (API keys go to the Keychain).
@MainActor
@Observable
final class AppSettings {
    var appearance: Appearance { didSet { save("appearance", appearance.rawValue) } }
    var wallpaper: Wallpaper { didSet { save("wallpaper", wallpaper.rawValue) } }
    var reduceTransparency: Bool { didSet { save("reduceTransparency", reduceTransparency) } }
    /// Terminal font size; applies to newly started chats.
    var fontSize: Int { didSet { save("fontSize", fontSize) } }
    var showInMenuBar: Bool { didSet { save("showInMenuBar", showInMenuBar) } }
    var restoreChats: Bool { didSet { save("restoreChats", restoreChats) } }
    var preventSleep: Bool { didSet { save("preventSleep", preventSleep) } }
    var agentNotifications: Bool { didSet { save("agentNotifications", agentNotifications) } }
    var notifyOnlyInBackground: Bool { didSet { save("notifyOnlyInBackground", notifyOnlyInBackground) } }
    var harnessHooks: Bool { didSet { save("harnessHooks", harnessHooks) } }
    var sidebarVisible: Bool { didSet { save("sidebarVisible", sidebarVisible) } }
    var sidebarWidth: Double { didSet { save("sidebarWidth", sidebarWidth) } }
    var gitPanelWidth: Double { didSet { save("gitPanelWidth", gitPanelWidth) } }
    var gitSummaryProvider: String { didSet { save("gitSummaryProvider", gitSummaryProvider) } }
    var gitSummaryModelGrok: String { didSet { save("gitSummaryModelGrok", gitSummaryModelGrok) } }
    var gitSummaryModelChatGPT: String { didSet { save("gitSummaryModelChatGPT", gitSummaryModelChatGPT) } }

    var theme: Theme { appearance == .light ? .light : .dark }

    enum Appearance: String { case dark, light }

    init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        wallpaper = Wallpaper(rawValue: d.string(forKey: "wallpaper") ?? "") ?? .graphite
        reduceTransparency = d.bool(forKey: "reduceTransparency")
        fontSize = d.object(forKey: "fontSize") as? Int ?? 13
        showInMenuBar = d.object(forKey: "showInMenuBar") as? Bool ?? true
        restoreChats = d.bool(forKey: "restoreChats")
        preventSleep = d.bool(forKey: "preventSleep")
        agentNotifications = d.object(forKey: "agentNotifications") as? Bool ?? true
        notifyOnlyInBackground = d.object(forKey: "notifyOnlyInBackground") as? Bool ?? true
        harnessHooks = d.object(forKey: "harnessHooks") as? Bool ?? true
        sidebarVisible = d.object(forKey: "sidebarVisible") as? Bool ?? true
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? 268
        gitPanelWidth = d.object(forKey: "gitPanelWidth") as? Double ?? 320
        gitSummaryProvider = d.string(forKey: "gitSummaryProvider") ?? "grok"
        gitSummaryModelGrok = d.string(forKey: "gitSummaryModelGrok") ?? "grok-4.6"
        gitSummaryModelChatGPT = d.string(forKey: "gitSummaryModelChatGPT") ?? "gpt-5.6-luna"
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// API keys for the VM agents (claude / codex / grok), stored in the Keychain.
/// The VM side that consumes them is wired separately.
enum APIKeyStore {
    static let providers: [(id: String, name: String, sub: String)] = [
        ("anthropic", "Anthropic", "claude"),
        ("openai", "OpenAI", "codex"),
        ("xai", "xAI", "grok"),
    ]

    private static func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.vetro.app.apikey",
            kSecAttrAccount as String: id,
        ]
    }

    static func get(_ id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ id: String, value: String) {
        let data = Data(value.utf8)
        var add = query(id)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func remove(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
