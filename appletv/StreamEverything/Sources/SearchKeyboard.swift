import SwiftUI

/// Compact on-screen keyboard for search: a grid of keys that takes a column on the
/// left so the results stay visible and update as you type. The single-row and the
/// full-screen system keyboards were both slow to use with a remote.
struct SearchKeyboard: View {
    @Binding var text: String
    var onDone: () -> Void = {}
    @FocusState private var focusedKey: String?
    @State private var dictation = ""

    private let rows: [[String]] = [
        ["a", "b", "c", "d", "e", "f"],
        ["g", "h", "i", "j", "k", "l"],
        ["m", "n", "o", "p", "q", "r"],
        ["s", "t", "u", "v", "w", "x"],
        ["y", "z", "1", "2", "3", "4"],
        ["5", "6", "7", "8", "9", "0"]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        Button { text += key } label: { Text(key) }
                            .buttonStyle(KeyStyle())
                            .focused($focusedKey, equals: key)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { text += " " } label: { Image(systemName: "space").frame(width: 150) }
                    .buttonStyle(KeyStyle())
                Button { if !text.isEmpty { text.removeLast() } } label: { Image(systemName: "delete.left").frame(width: 70) }
                    .buttonStyle(KeyStyle())
                Button { text = "" } label: { Image(systemName: "xmark").frame(width: 70) }
                    .buttonStyle(KeyStyle())
            }
            // The system field is still there for Siri dictation and fast typing.
            TextField("Dictate or type", text: $dictation)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(width: 320)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: dictation) { _, value in
                    if !value.isEmpty { text = value; dictation = "" }
                }
        }
        .onAppear { focusedKey = "a" }
    }
}

private struct KeyStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .medium))
            .frame(minWidth: 42)
            .foregroundStyle(focused ? Theme.page : .white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(focused ? Color.white : Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
