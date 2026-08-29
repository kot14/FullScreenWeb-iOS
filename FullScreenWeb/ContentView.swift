//
//  ContentView.swift
//  FullScreenWeb
//

import SwiftUI

struct ContentView: View {
    /// Do not `@ObservedObject` the whole store — URL updates while browsing would
    /// rebuild this grid under the finger and break shortcut hit-testing.
    private let store = WebViewStore.shared
    @ObservedObject private var languageStore = LanguageStore.shared

    @State private var shortcuts: [LinkShortcut] = WebViewStore.shared.shortcuts
    @State private var isExternalDisplayConnected = WebViewStore.shared.isExternalDisplayConnected
    @State private var captureMouseForExternalDisplay = WebViewStore.shared.captureMouseForExternalDisplay
    @State private var showSettings = false
    @State private var showAddShortcut = false
    @State private var newTitle = ""
    @State private var newURL = ""

    private var shouldCaptureMouse: Bool {
        isExternalDisplayConnected && captureMouseForExternalDisplay
    }

    var body: some View {
        PointerCaptureHost(lockPointer: shouldCaptureMouse) {
            NavigationStack {
                mainContent
                    .navigationTitle(L10n.links)
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showAddShortcut = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(L10n.addShortcutA11y)
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel(L10n.settingsA11y)
                        }
                    }
                    .sheet(isPresented: $showSettings) {
                        SettingsView()
                    }
                    .sheet(isPresented: $showAddShortcut) {
                        addShortcutSheet
                    }
            }
        }
        .ignoresSafeArea()
        .environment(\.locale, languageStore.locale)
        .onReceive(store.$shortcuts) { shortcuts = $0 }
        .onReceive(store.$isExternalDisplayConnected) { isExternalDisplayConnected = $0 }
        .onReceive(store.$captureMouseForExternalDisplay) { captureMouseForExternalDisplay = $0 }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionStatus

                // Non-lazy grid: few items, avoids LazyVGrid recycle hit-test glitches.
                VStack(spacing: 16) {
                    ForEach(Array(stride(from: 0, to: shortcuts.count, by: 2)), id: \.self) { start in
                        HStack(spacing: 16) {
                            shortcutButton(shortcuts[start])
                            if start + 1 < shortcuts.count {
                                shortcutButton(shortcuts[start + 1])
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity, minHeight: 120)
                                    .padding()
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }

                if !isExternalDisplayConnected {
                    Text(L10n.connectMonitorHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
    }

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(isExternalDisplayConnected ? .green : .red)
                .frame(width: 10, height: 10)
            Text(isExternalDisplayConnected ? L10n.monitorConnected : L10n.monitorDisconnected)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func shortcutButton(_ shortcut: LinkShortcut) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            store.load(shortcut.urlString)
        } label: {
            VStack(spacing: 10) {
                FaviconView(urlString: shortcut.urlString, size: 36)
                Text(shortcut.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(displayHost(for: shortcut.urlString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding()
            .background(.regularMaterial, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.removeShortcut(shortcut)
            } label: {
                Label(L10n.delete, systemImage: "trash")
            }
        }
    }

    private var addShortcutSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.title, text: $newTitle)
                        .textInputAutocapitalization(.words)
                    TextField(L10n.url, text: $newURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } footer: {
                    Text(L10n.newShortcutFooter)
                }
            }
            .navigationTitle(L10n.newShortcutTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) {
                        resetAddForm()
                        showAddShortcut = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.add) {
                        store.addShortcut(title: newTitle, urlString: newURL)
                        resetAddForm()
                        showAddShortcut = false
                    }
                    .disabled(!canAddShortcut)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var canAddShortcut: Bool {
        !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetAddForm() {
        newTitle = ""
        newURL = ""
    }

    private func displayHost(for urlString: String) -> String {
        let normalized: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            normalized = urlString
        } else {
            normalized = "https://\(urlString)"
        }
        return URL(string: normalized)?.host ?? urlString
    }
}

#Preview {
    ContentView()
}
