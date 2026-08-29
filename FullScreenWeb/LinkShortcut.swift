//
//  LinkShortcut.swift
//  FullScreenWeb
//

import Foundation

struct LinkShortcut: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var urlString: String

    init(id: UUID = UUID(), title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }

    static let defaults: [LinkShortcut] = [
        LinkShortcut(title: "Google", urlString: "https://www.google.com"),
        LinkShortcut(title: "DuckDuckGo", urlString: "https://duckduckgo.com"),
    ]
}
