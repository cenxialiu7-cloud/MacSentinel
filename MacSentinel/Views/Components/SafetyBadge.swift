import SwiftUI

// MARK: - SafetyLevel UI extensions

extension SafetyLevel {
    var color: Color {
        switch self {
        case .safe:        return .green
        case .recommended: return .blue
        case .caution:     return .orange
        case .risky:       return .red
        }
    }
}

/// Visual badge used throughout the app for safety level display.
struct SafetyBadge: View {
    let level: SafetyLevel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: level.systemImage)
                .font(.caption2)
            if !compact {
                Text(level.shortLabel).font(.caption2.bold())
            }
        }
        .padding(.horizontal, compact ? 3 : 6)
        .padding(.vertical, 2)
        .background(level.color.opacity(0.15), in: Capsule())
        .foregroundStyle(level.color)
    }
}
