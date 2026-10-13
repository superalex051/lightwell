import SwiftUI

/// True while a text field in the key window has keyboard focus. Menu shortcuts that are
/// also text editing keys (Cmd+Delete, Cmd+Up) are disabled then, so the keystroke reaches
/// the field instead of acting on the selected file.
struct TextInputActiveKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var textInputActive: Bool? {
        get { self[TextInputActiveKey.self] }
        set { self[TextInputActiveKey.self] = newValue }
    }
}

extension View {
    /// Apply to every text field in the main window.
    func publishesTextInput() -> some View {
        focusedValue(\.textInputActive, true)
    }
}
