import SwiftUI

/// An integer text field that edits a local draft and only stores it when the
/// user presses Return or leaves the field.
///
/// A plain value-formatted `TextField` writes every keystroke back to its
/// binding, so intermediate values such as the 0 left when changing 30 to 40
/// reach profile validation and are rejected. A draft below `minimum` is
/// discarded on commit and the field shows the stored value again.
struct CommittedIntegerField: View {
    let title: String
    let value: Int
    var minimum: Int = 1
    let commit: (Int) -> Void

    @State private var draft: Int
    @FocusState private var isFocused: Bool

    init(_ title: String, value: Int, minimum: Int = 1, commit: @escaping (Int) -> Void) {
        self.title = title
        self.value = value
        self.minimum = minimum
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, value: $draft, format: .number)
            .focused($isFocused)
            .onSubmit(commitDraft)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitDraft()
                }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
    }

    private func commitDraft() {
        guard draft >= minimum else {
            draft = value
            return
        }
        if draft != value {
            commit(draft)
        }
    }
}
