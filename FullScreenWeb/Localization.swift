//
//  Localization.swift
//  FullScreenWeb
//

import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ukrainian
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.languageSystem
        case .ukrainian: return "Українська"
        case .english: return "English"
        }
    }

    /// BCP-47 code used for string lookup (`uk` / `en`).
    var resolvedCode: String {
        switch self {
        case .ukrainian: return "uk"
        case .english: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "uk"
            if preferred.hasPrefix("uk") || preferred.hasPrefix("ru") {
                return "uk"
            }
            return "en"
        }
    }

    var locale: Locale {
        Locale(identifier: resolvedCode)
    }
}

final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    private enum DefaultsKey {
        static let language = "app.language"
    }

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.language)
        }
    }

    var resolvedCode: String { language.resolvedCode }
    var locale: Locale { language.locale }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.language),
           let saved = AppLanguage(rawValue: raw) {
            language = saved
        } else {
            language = .system
        }
    }
}

enum L10n {
    // MARK: - Content

    static var links: String { t("links") }
    static var addShortcutA11y: String { t("addShortcutA11y") }
    static var settingsA11y: String { t("settingsA11y") }
    static var connectMonitorHint: String { t("connectMonitorHint") }
    static var monitorConnected: String { t("monitorConnected") }
    static var monitorDisconnected: String { t("monitorDisconnected") }
    static var delete: String { t("delete") }
    static var title: String { t("title") }
    static var url: String { t("url") }
    static var newShortcutFooter: String { t("newShortcutFooter") }
    static var newShortcutTitle: String { t("newShortcutTitle") }
    static var cancel: String { t("cancel") }
    static var add: String { t("add") }
    static var siteFallbackTitle: String { t("siteFallbackTitle") }

    // MARK: - Settings

    static var settings: String { t("settings") }
    static var done: String { t("done") }
    static var horizontal: String { t("horizontal") }
    static var vertical: String { t("vertical") }
    static var offsetX: String { t("offsetX") }
    static var offsetY: String { t("offsetY") }
    static var resetStretch: String { t("resetStretch") }
    static var stretchSection: String { t("stretchSection") }
    static var showAddressBar: String { t("showAddressBar") }
    static var addressBarSection: String { t("addressBarSection") }
    static var addressBarFooter: String { t("addressBarFooter") }
    static var adBlock: String { t("adBlock") }
    static var adBlockSection: String { t("adBlockSection") }
    static var adBlockFooter: String { t("adBlockFooter") }
    static var aboutFooter: String { t("aboutFooter") }
    static var languageSection: String { t("languageSection") }
    static var language: String { t("language") }
    static var languageSystem: String { t("languageSystem") }
    static var languageFooter: String { t("languageFooter") }

    // MARK: - External chrome

    static var quickAccessA11y: String { t("quickAccessA11y") }
    static var urlPlaceholder: String { t("urlPlaceholder") }
    static var go: String { t("go") }
    static var removeFromQuickAccessA11y: String { t("removeFromQuickAccessA11y") }
    static var addToQuickAccessA11y: String { t("addToQuickAccessA11y") }

    static func t(_ key: String) -> String {
        let code = LanguageStore.shared.resolvedCode
        if let value = table[code]?[key] {
            return value
        }
        return table["uk"]?[key] ?? key
    }

    private static let table: [String: [String: String]] = [
        "uk": [
            "links": "Посилання",
            "addShortcutA11y": "Додати кнопку",
            "settingsA11y": "Налаштування",
            "connectMonitorHint": "Підключи монітор, щоб відкрити посилання на зовнішньому екрані.",
            "monitorConnected": "Монітор підключено",
            "monitorDisconnected": "Монітор не підключено",
            "delete": "Видалити",
            "title": "Назва",
            "url": "URL",
            "newShortcutFooter": "Кнопка відкриє це посилання на зовнішньому моніторі.",
            "newShortcutTitle": "Нова кнопка",
            "cancel": "Скасувати",
            "add": "Додати",
            "siteFallbackTitle": "Сайт",
            "settings": "Налаштування",
            "done": "Готово",
            "horizontal": "Горизонталь",
            "vertical": "Вертикаль",
            "offsetX": "Зсув X",
            "offsetY": "Зсув Y",
            "resetStretch": "Скинути розтягнення",
            "stretchSection": "Розгортка на моніторі",
            "showAddressBar": "Показати адресний рядок",
            "addressBarSection": "Панель адреси на моніторі",
            "addressBarFooter": "Адресу вводь на моніторі (миша + клавіатура). Tab фокусує поле URL, Enter — перейти.",
            "adBlock": "Ad block",
            "adBlockSection": "Блокування реклами",
            "adBlockFooter": "Блокує рекламні/трекінгові домени, типові ad-шляхи та ховає банери (WKContentRuleList + косметичне прибирання). Після зміни сторінка перезавантажується.",
            "aboutFooter": "Монітор — браузер на весь екран. iPad — лише touch-налаштування. Миша працює тільки на моніторі.",
            "languageSection": "Мова",
            "language": "Мова інтерфейсу",
            "languageSystem": "Системна",
            "languageFooter": "Зміна мови застосовується одразу.",
            "quickAccessA11y": "Швидкий доступ",
            "urlPlaceholder": "Введи адресу сайту",
            "go": "Перейти",
            "removeFromQuickAccessA11y": "Прибрати зі швидкого доступу",
            "addToQuickAccessA11y": "Додати в швидкий доступ",
        ],
        "en": [
            "links": "Links",
            "addShortcutA11y": "Add shortcut",
            "settingsA11y": "Settings",
            "connectMonitorHint": "Connect a monitor to open links on the external display.",
            "monitorConnected": "Monitor connected",
            "monitorDisconnected": "Monitor not connected",
            "delete": "Delete",
            "title": "Title",
            "url": "URL",
            "newShortcutFooter": "This shortcut opens the link on the external monitor.",
            "newShortcutTitle": "New shortcut",
            "cancel": "Cancel",
            "add": "Add",
            "siteFallbackTitle": "Site",
            "settings": "Settings",
            "done": "Done",
            "horizontal": "Horizontal",
            "vertical": "Vertical",
            "offsetX": "Offset X",
            "offsetY": "Offset Y",
            "resetStretch": "Reset stretch",
            "stretchSection": "Display stretch",
            "showAddressBar": "Show address bar",
            "addressBarSection": "Address bar on monitor",
            "addressBarFooter": "Enter the address on the monitor (mouse + keyboard). Tab focuses the URL field, Enter navigates.",
            "adBlock": "Ad block",
            "adBlockSection": "Ad blocking",
            "adBlockFooter": "Blocks ad/tracker domains, common ad paths, and hides banners (WKContentRuleList + cosmetic cleanup). The page reloads after changing this.",
            "aboutFooter": "Monitor — full-screen browser. iPad — touch settings only. The mouse works only on the monitor.",
            "languageSection": "Language",
            "language": "Interface language",
            "languageSystem": "System",
            "languageFooter": "Language changes apply immediately.",
            "quickAccessA11y": "Quick access",
            "urlPlaceholder": "Enter a website address",
            "go": "Go",
            "removeFromQuickAccessA11y": "Remove from quick access",
            "addToQuickAccessA11y": "Add to quick access",
        ],
    ]
}
