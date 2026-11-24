import SwiftUI

/// An integer text field that edits a local draft. It stores the draft only
/// when the user presses Return, when the focus goes out of the field, or
/// when the field goes out of the view.
///
/// A `TextField` with a value format writes each keystroke to its binding.
/// Thus profile validation gets values that the user did not finish, such as
/// the 0 that stays when you change 30 to 40, and rejects them.
///
/// When the draft is less than `minimum`, or when `commit` returns false, the
/// field ignores the draft and shows the stored value again.
///
/// Give the field the identity of the object that it edits, for example
/// `.id(profile.id)`. Then a different object gets a new field with a new
/// draft, and the old field stores its draft in the old object.
struct CommittedIntegerField: View {
    let title: String
    let value: Int
    var minimum: Int = 1
    /// Stores a value. Returns false when the value was not stored.
    let commit: (Int) -> Bool

    @State private var draft: Int
    @FocusState private var isFocused: Bool

    init(_ title: String, value: Int, minimum: Int = 1, commit: @escaping (Int) -> Bool) {
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
            // The window can close, or the page can change, before the
            // focus change arrives. Store the draft here to keep the edit.
            .onDisappear(perform: commitDraft)
    }

    private func commitDraft() {
        guard draft >= minimum else {
            draft = value
            return
        }
        guard draft != value else {
            return
        }
        if !commit(draft) {
            // The store did not accept the value. Show the stored value.
            draft = value
        }
    }
}
