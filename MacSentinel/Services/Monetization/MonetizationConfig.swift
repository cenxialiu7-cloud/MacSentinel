//
//  MonetizationConfig.swift
//  MacSentinel
//
//  Lightweight sponsor / VPN affiliate config.
//  Mirrors the model documented in MediaGrab/MONETIZATION.md:
//    1. VPN affiliate (primary)
//    2. Donation (Ko-fi)
//    3. NO third-party JavaScript / ad iframes inside the app —
//       MacSentinel is a security tool, embedding ad scripts would
//       contradict its identity. Web landing page handles iframe ads.
//
//  Any offer with an empty URL is treated as disabled and the
//  corresponding UI auto-hides. The user can globally disable sponsor
//  messages from Settings.
//

import Foundation

/// A single affiliate / sponsor offer surfaced inside the app.
struct SponsorOffer: Identifiable, Hashable {
    let id: String              // stable id for analytics / dismiss tracking
    let badge: String           // short tag e.g. "⚡ 限時優惠"
    let headline: String        // one-liner shown as title
    let subtext: String         // secondary description
    let ctaTitle: String        // button label
    let url: URL?               // affiliate URL; nil → component hidden

    /// Whether this offer should actually be rendered.
    var isLive: Bool { url != nil }
}

/// Append UTM parameters so the affiliate dashboard can attribute conversions
/// to the source surface (e.g. "dashboard banner" vs "settings card").
private func attachUTM(_ raw: String, source: String, content: String) -> URL? {
    guard !raw.isEmpty, var components = URLComponents(string: raw) else { return nil }
    var items = components.queryItems ?? []
    items.append(.init(name: "utm_source",   value: "macsentinel"))
    items.append(.init(name: "utm_medium",   value: "app"))
    items.append(.init(name: "utm_campaign", value: source))
    items.append(.init(name: "utm_content",  value: content))
    components.queryItems = items
    return components.url
}

enum MonetizationConfig {

    // ─── VPN affiliate offers ──────────────────────────────────────────────
    // Replace the rawURL strings with your real affiliate URLs from:
    //   NordVPN:   https://nordvpn.com/affiliate/
    //   Surfshark: https://surfshark.com/affiliates
    // Leaving rawURL empty automatically hides the offer.
    static let vpnOffers: [SponsorOffer] = [
        SponsorOffer(
            id: "nordvpn",
            badge: "⚡ 推薦合作",
            headline: "守護網路隱私",
            subtext: "掃描到不必要外連？搭配 VPN 加密所有流量。",
            ctaTitle: "了解 NordVPN",
            url: attachUTM(
                "https://nordvpn.com/",                     // ← put real affiliate URL here
                source: "dashboard",
                content: "vpn-banner"
            )
        ),
        SponsorOffer(
            id: "surfshark",
            badge: "🔒 隱私首選",
            headline: "Surfshark VPN 86% 折扣",
            subtext: "無裝置數量限制，一個帳號保護全家 Mac。",
            ctaTitle: "查看 Surfshark",
            url: attachUTM(
                "",                                         // ← empty = hidden
                source: "settings",
                content: "vpn-card"
            )
        ),
    ]

    // ─── Donation links ────────────────────────────────────────────────────
    static let donationURL: URL? = URL(string: "https://ko-fi.com/")    // ← real Ko-fi page

    // ─── User-controlled toggle ────────────────────────────────────────────
    // Backed by UserDefaults so user choice persists. Default ON.
    static let showSponsorMessagesKey = "showSponsorMessages"

    static var isUserOptedIn: Bool {
        // First launch → default ON. After user toggles → respect their choice.
        if UserDefaults.standard.object(forKey: showSponsorMessagesKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: showSponsorMessagesKey)
    }

    /// First live offer (skipping any with empty URLs).
    static var primaryVPNOffer: SponsorOffer? {
        vpnOffers.first(where: { $0.isLive })
    }
}
