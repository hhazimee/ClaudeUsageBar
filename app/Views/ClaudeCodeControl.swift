import SwiftUI

/// Shows whether Claude Code is on this account, or offers to switch it here.
struct ClaudeCodeControl: View {
    let isActive: Bool
    let canSwitch: Bool
    let isSwitching: Bool
    let action: () -> Void

    var body: some View {
        if isActive {
            Text("Claude Code")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.18))
                .foregroundColor(.accentColor)
                .cornerRadius(4)
        } else if isSwitching {
            ProgressView().controlSize(.small)
        } else {
            Button("Switch", action: action)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!canSwitch)
                .help(canSwitch ? "" : "Log in to Claude Code as this account once")
        }
    }
}
