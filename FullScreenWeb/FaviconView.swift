//
//  FaviconView.swift
//  FullScreenWeb
//

import SwiftUI
import UIKit

struct FaviconView: View {
    let urlString: String
    var size: CGFloat = 32

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.72, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: urlString) {
            await load()
        }
    }

    private func load() async {
        image = nil

        guard let faviconURL = Self.faviconURL(for: urlString) else { return }

        if let cached = FaviconCache.shared.image(for: faviconURL) {
            image = cached
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: faviconURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let loaded = UIImage(data: data)
            else { return }
            FaviconCache.shared.store(loaded, for: faviconURL)
            image = loaded
        } catch {
            // Keep globe placeholder.
        }
    }

    static func faviconURL(for urlString: String) -> URL? {
        guard let host = host(from: urlString) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "128"),
        ]
        return components.url
    }

    static func host(from urlString: String) -> String? {
        let normalized: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            normalized = urlString
        } else {
            normalized = "https://\(urlString)"
        }
        guard let host = URL(string: normalized)?.host, !host.isEmpty else { return nil }
        return host
    }
}

private final class FaviconCache {
    static let shared = FaviconCache()

    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
