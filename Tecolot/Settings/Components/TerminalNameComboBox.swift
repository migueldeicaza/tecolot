import SwiftUI
import AppKit

struct TerminalNameComboBox: NSViewRepresentable {
    private static let fallbackValue = "xterm-256color"
    private static let values = [
        fallbackValue,
        "xterm-color",
        "xterm",
        "vt100",
        "xterm-ghostty"
    ]

    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fallbackValue: Self.fallbackValue)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.addItems(withObjectValues: Self.values)
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.delegate = context.coordinator
        comboBox.stringValue = text
        comboBox.setAccessibilityLabel(String(localized: "Declare terminal as"))
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        let fallbackValue: String

        init(text: Binding<String>, fallbackValue: String) {
            self.text = text
            self.fallbackValue = fallbackValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            text.wrappedValue = comboBox.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard
                let comboBox = notification.object as? NSComboBox,
                comboBox.stringValue.isEmpty
            else {
                return
            }
            comboBox.stringValue = fallbackValue
            text.wrappedValue = fallbackValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard
                let comboBox = notification.object as? NSComboBox,
                let selectedValue = comboBox.objectValueOfSelectedItem as? String
            else {
                return
            }
            comboBox.stringValue = selectedValue
            text.wrappedValue = selectedValue
        }
    }
}
