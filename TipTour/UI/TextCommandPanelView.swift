import SwiftUI

struct TextCommandPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @FocusState private var isInputFocused: Bool
    @State private var commandText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "command")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16, height: 16)

                TextField("Ask TipTour...", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .tint(DS.Colors.textSecondary)
                    .focused($isInputFocused)
                    .onSubmit {
                        submitCommand()
                    }
                    .onExitCommand {
                        commandText = ""
                        companionManager.dismissTextCommandPanel()
                    }
            }

            if let activityText = companionManager.textCommandActivityText,
               !activityText.isEmpty {
                TextCommandActivityTicker(
                    text: activityText,
                    isActive: companionManager.voiceState == .processing
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.background.opacity(0.96))
                .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.8)
        )
        .animation(.snappy(duration: 0.22), value: companionManager.textCommandActivityText)
        .onAppear {
            commandText = ""
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private func submitCommand() {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        commandText = ""
        Task {
            await companionManager.submitTextCommand(trimmedCommand)
        }
    }
}

private struct TextCommandActivityTicker: View {
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DS.Colors.textSecondary.opacity(isActive ? 0.82 : 0.42))
                .frame(width: 4, height: 4)

            ZStack(alignment: .leading) {
                Text(text)
                    .id(text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, 25)
        .padding(.trailing, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }
}
