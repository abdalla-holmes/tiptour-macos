//
//  PointerAgentCardView.swift
//  TipTour
//
//  Compact normal-state card for the pointer-first product surface.
//

import SwiftUI

struct PointerAgentCardView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(DS.Colors.accent.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pointer Agent")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(pointerAgentSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                compactStatePill(
                    companionManager.isAutopilotEnabled ? "Auto-click" : "Point only",
                    systemImage: companionManager.isAutopilotEnabled ? "wand.and.stars" : "hand.tap",
                    isActive: companionManager.isAutopilotEnabled
                )
                compactStatePill(
                    companionManager.isAccurateGroundingEnabled ? "Local grounding" : "AX/DOM",
                    systemImage: "scope",
                    isActive: companionManager.isAccurateGroundingEnabled
                )
            }

            Button {
                companionManager.setAutopilotEnabled(!companionManager.isAutopilotEnabled)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: companionManager.isAutopilotEnabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(companionManager.isAutopilotEnabled ? "Switch to point-only" : "Let TipTour click")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var pointerAgentSubtitle: String {
        if companionManager.isHermesOrchestratorEnabled {
            return "Auto routes bigger tasks to Hermes."
        }
        return "TipTour plans one action, points, then acts."
    }

    private func compactStatePill(
        _ title: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(isActive ? DS.Colors.accent : DS.Colors.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isActive ? DS.Colors.accent.opacity(0.12) : Color.white.opacity(0.05))
        )
    }
}
