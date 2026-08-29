//
//  SettingsView.swift
//  FullScreenWeb
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = WebViewStore.shared
    @ObservedObject private var languageStore = LanguageStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    connectionStatus
                }

                Section {
                    Picker(L10n.language, selection: $languageStore.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                } header: {
                    Text(L10n.languageSection)
                } footer: {
                    Text(L10n.languageFooter)
                }

                Section {
                    scaleRow(
                        title: L10n.horizontal,
                        value: store.scaleX,
                        format: { String(format: "%.3f×", $0) },
                        onSlider: { store.scaleX = $0 },
                        onMinus: { store.nudgeScaleX(-0.001) },
                        onPlus: { store.nudgeScaleX(0.001) }
                    )

                    scaleRow(
                        title: L10n.vertical,
                        value: store.scaleY,
                        format: { String(format: "%.3f×", $0) },
                        onSlider: { store.scaleY = $0 },
                        onMinus: { store.nudgeScaleY(-0.001) },
                        onPlus: { store.nudgeScaleY(0.001) }
                    )

                    offsetRow(
                        title: L10n.offsetX,
                        value: store.offsetX,
                        onSlider: { store.offsetX = $0 },
                        onMinus: { store.nudgeOffsetX(-1) },
                        onPlus: { store.nudgeOffsetX(1) }
                    )

                    offsetRow(
                        title: L10n.offsetY,
                        value: store.offsetY,
                        onSlider: { store.offsetY = $0 },
                        onMinus: { store.nudgeOffsetY(-1) },
                        onPlus: { store.nudgeOffsetY(1) }
                    )

                    Button(L10n.resetStretch) {
                        store.resetTransform()
                    }
                } header: {
                    Text(L10n.stretchSection)
                }

                Section {
                    Toggle(L10n.showAddressBar, isOn: $store.isAddressBarVisible)
                } header: {
                    Text(L10n.addressBarSection)
                } footer: {
                    Text(L10n.addressBarFooter)
                }

                Section {
                    Toggle(L10n.adBlock, isOn: $store.isAdBlockEnabled)
                } header: {
                    Text(L10n.adBlockSection)
                } footer: {
                    Text(L10n.adBlockFooter)
                }

                Section {
                    Text(L10n.aboutFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
            .environment(\.locale, languageStore.locale)
        }
    }

    private var connectionStatus: some View {
        HStack {
            Circle()
                .fill(store.isExternalDisplayConnected ? .green : .red)
                .frame(width: 10, height: 10)
            Text(store.isExternalDisplayConnected ? L10n.monitorConnected : L10n.monitorDisconnected)
                .foregroundStyle(.secondary)
        }
    }

    private func scaleRow(
        title: String,
        value: CGFloat,
        format: (CGFloat) -> String,
        onSlider: @escaping (CGFloat) -> Void,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(action: onMinus) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)

                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { onSlider(CGFloat($0)) }
                    ),
                    in: 0.7...1.5,
                    step: 0.001
                )

                Button(action: onPlus) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            .font(.title3)
        }
        .padding(.vertical, 4)
    }

    private func offsetRow(
        title: String,
        value: CGFloat,
        onSlider: @escaping (CGFloat) -> Void,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f px", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(action: onMinus) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)

                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { onSlider(CGFloat($0)) }
                    ),
                    in: -200...200,
                    step: 1
                )

                Button(action: onPlus) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            .font(.title3)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SettingsView()
}
