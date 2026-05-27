//
//  TreemapView.swift
//  MacSentinel
//
//  Simple proportional treemap. Implements a slice-and-dice algorithm
//  (alternating horizontal/vertical splits along the longer axis) which
//  is much simpler than squarified treemap and good enough for a small
//  N (≤ 12 hotspots).
//

import SwiftUI

struct TreemapItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: Double       // size in bytes (or any positive metric)
    let color: Color
}

struct TreemapView: View {
    let items: [TreemapItem]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(rects(in: geo.size), id: \.0.id) { item, rect in
                    Rectangle()
                        .fill(item.color.opacity(0.85))
                        .frame(width: rect.width, height: rect.height)
                        .overlay(
                            Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            // Only label if box is big enough
                            if rect.width > 70 && rect.height > 32 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.label)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(ByteFormatter.format(UInt64(item.value)))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                            }
                        }
                        .offset(x: rect.minX, y: rect.minY)
                        .help("\(item.label) — \(ByteFormatter.format(UInt64(item.value)))")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: - Layout

    private func rects(in size: CGSize) -> [(TreemapItem, CGRect)] {
        let sorted = items.sorted { $0.value > $1.value }
        let total = sorted.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [] }

        var pending = sorted
        var rectFrame = CGRect(origin: .zero, size: size)
        var output: [(TreemapItem, CGRect)] = []

        while let head = pending.first {
            pending.removeFirst()
            let fraction = head.value / total
            // Decide axis: split along the longer side
            let horizontal = rectFrame.width >= rectFrame.height
            if horizontal {
                let w = rectFrame.width * CGFloat(fraction / fractionRemaining(used: output, total: total))
                output.append((head, CGRect(x: rectFrame.minX, y: rectFrame.minY,
                                            width: w, height: rectFrame.height)))
                rectFrame = CGRect(x: rectFrame.minX + w, y: rectFrame.minY,
                                   width: rectFrame.width - w, height: rectFrame.height)
            } else {
                let h = rectFrame.height * CGFloat(fraction / fractionRemaining(used: output, total: total))
                output.append((head, CGRect(x: rectFrame.minX, y: rectFrame.minY,
                                            width: rectFrame.width, height: h)))
                rectFrame = CGRect(x: rectFrame.minX, y: rectFrame.minY + h,
                                   width: rectFrame.width, height: rectFrame.height - h)
            }
        }
        return output
    }

    private func fractionRemaining(used: [(TreemapItem, CGRect)], total: Double) -> Double {
        let usedValue = used.reduce(0.0) { $0 + $1.0.value }
        return max(0.0001, 1.0 - usedValue / total)
    }
}
