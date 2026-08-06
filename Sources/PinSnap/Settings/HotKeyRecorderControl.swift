import AppKit
import SwiftUI

/// 点击后监听下一次按键；Esc 取消。
struct HotKeyRecorderControl: View {
    let slot: HotKeySlot
    @ObservedObject private var prefs = HotKeyPreferences.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            beginRecording()
        } label: {
            Text(isRecording ? "…" : prefs.displayString(for: slot))
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .center)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { endRecording(commit: false) }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                Task { @MainActor in endRecording(commit: false) }
                return nil
            }
            let chord = KeyChord(event: event)
            guard chord.isValidBinding else { return nil }
            Task { @MainActor in
                HotKeyPreferences.shared.setChord(chord, for: slot)
                endRecording(commit: true)
            }
            return nil
        }
    }

    private func endRecording(commit _: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
