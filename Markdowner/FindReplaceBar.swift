import SwiftUI

struct FindReplaceBar: View {
    @Binding var isPresented: Bool
    @Binding var showReplace: Bool

    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var matchCount = 0
    @State private var matchIndex = -1

    var onFind: (String, Bool) -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onReplace: (String) -> Void
    var onReplaceAll: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Find", text: $findText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 140)
                    .onSubmit { runFind() }
                    .onChange(of: findText) { _, newValue in
                        onFind(newValue, caseSensitive)
                    }

                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .trailing)

                Button {
                    onPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Previous match (⇧⌘G)")

                Button {
                    onNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Next match (⌘G)")

                Toggle(isOn: $caseSensitive) {
                    Text("Aa")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .help("Case sensitive")
                .onChange(of: caseSensitive) { _, _ in
                    onFind(findText, caseSensitive)
                }

                Button {
                    showReplace.toggle()
                } label: {
                    Image(systemName: showReplace ? "chevron.up" : "chevron.down")
                    Text("Replace")
                }
                .buttonStyle(.borderless)

                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close (⎋)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)

                    TextField("Replace with", text: $replaceText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 140)
                        .onSubmit { onReplace(replaceText) }

                    Button("Replace") {
                        onReplace(replaceText)
                    }
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button("Replace All") {
                        onReplaceAll(replaceText)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markdownerFindResult)) { note in
            if let info = note.userInfo {
                matchCount = info["count"] as? Int ?? 0
                matchIndex = info["index"] as? Int ?? -1
            }
        }
        .onAppear {
            if !findText.isEmpty {
                onFind(findText, caseSensitive)
            }
        }
    }

    private var matchLabel: String {
        if findText.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        let current = matchIndex >= 0 ? matchIndex + 1 : 0
        return "\(current) of \(matchCount)"
    }

    private func runFind() {
        onFind(findText, caseSensitive)
        onNext()
    }

    private func close() {
        isPresented = false
        onClose()
    }

    /// Allows parent to push initial focus/query.
    func applyExternalResult(count: Int, index: Int) {
        matchCount = count
        matchIndex = index
    }
}
