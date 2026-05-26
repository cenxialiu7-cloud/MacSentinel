//
//  SponsorBanner.swift
//  MacSentinel
//
//  Compact, dismissible sponsor banner shown on the Dashboard. Hidden when:
//    • the user opted out in Settings, or
//    • the offer has no live affiliate URL, or
//    • the user dismissed it this session (the ✕ button)
//
//  No third-party scripts. Just a SwiftUI card + URL open. Click opens the
//  default browser via NSWorkspace.
//

import SwiftUI

struct SponsorBanner: View {

    /// Per-session dismissal (resets on app restart — by design, so a
    /// permanent off-switch lives in Settings, not in the banner).
    @State private var dismissed: Bool = false

    /// Persisted user preference from Settings ("顯示贊助商訊息").
    @AppStorage(MonetizationConfig.showSponsorMessagesKey)
    private var showSponsorMessages: Bool = true

    @Environment(\.openURL) private var openURL

    var body: some View {
        if showSponsorMessages, !dismissed,
           let offer = MonetizationConfig.primaryVPNOffer,
           let url = offer.url {

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(offer.headline)
                        .font(.callout.weight(.semibold))
                    Text(offer.subtext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button {
                    openURL(url)
                } label: {
                    Text(offer.ctaTitle)
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("本次關閉（永久關閉請至「設定 → 支援與贊助」）")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.08),
                             Color.cyan.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview {
    SponsorBanner()
        .padding()
        .frame(width: 700)
}
