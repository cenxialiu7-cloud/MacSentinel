#!/usr/bin/env swift

// MARK: - MacSentinel AppIcon Generator
//
// Produces a 1024×1024 base icon plus all sizes required by macOS app bundles,
// rendered with CoreGraphics. Run from project root:
//   swift Scripts/GenerateAppIcon.swift
//
// Design: hexagonal sentinel shield over a cool blue-cyan squircle gradient,
// with a centered monitoring pulse line. Distinct from competitor visuals
// (yellow CleanMyMac, green MacKeeper, slate Onyx, orange iStat).

import AppKit
import CoreGraphics

// MARK: - Configuration

let outputDir = "MacSentinel/Resources/Assets.xcassets/AppIcon.appiconset"
let fileManager = FileManager.default

// Apple macOS AppIcon manifest — each entry needs a discrete PNG.
struct IconSize {
    let pixels: CGFloat
    let scale: Int          // 1 or 2 (Retina)
    let idiom: String       // "mac"
    let sizePoints: String  // "16x16", "32x32", etc.
    var filename: String { "icon_\(Int(pixels))x\(Int(pixels)).png" }
}

let manifest: [IconSize] = [
    .init(pixels: 16,   scale: 1, idiom: "mac", sizePoints: "16x16"),
    .init(pixels: 32,   scale: 2, idiom: "mac", sizePoints: "16x16"),
    .init(pixels: 32,   scale: 1, idiom: "mac", sizePoints: "32x32"),
    .init(pixels: 64,   scale: 2, idiom: "mac", sizePoints: "32x32"),
    .init(pixels: 128,  scale: 1, idiom: "mac", sizePoints: "128x128"),
    .init(pixels: 256,  scale: 2, idiom: "mac", sizePoints: "128x128"),
    .init(pixels: 256,  scale: 1, idiom: "mac", sizePoints: "256x256"),
    .init(pixels: 512,  scale: 2, idiom: "mac", sizePoints: "256x256"),
    .init(pixels: 512,  scale: 1, idiom: "mac", sizePoints: "512x512"),
    .init(pixels: 1024, scale: 2, idiom: "mac", sizePoints: "512x512"),
]

// MARK: - Drawing

/// Render the MacSentinel icon at the given pixel size into a CGImage.
func renderIcon(pixelSize: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: Int(pixelSize),
        height: Int(pixelSize),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { fatalError("Failed to create CGContext") }

    // CoreGraphics origin is bottom-left; flip so y grows downward like UIKit.
    ctx.translateBy(x: 0, y: pixelSize)
    ctx.scaleBy(x: 1, y: -1)

    let canvasRect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

    // ─── 1. Squircle background with gradient ────────────────────────────
    // macOS Big Sur+ uses an iOS-style continuous rounded rectangle (squircle).
    // The corner radius is approximately 0.2237 × side length.
    let cornerRadius = pixelSize * 0.2237
    let inset = pixelSize * 0.07
    let bgRect = canvasRect.insetBy(dx: inset, dy: inset)

    let squirclePath = NSBezierPath(roundedRect: bgRect,
                                     xRadius: cornerRadius,
                                     yRadius: cornerRadius).cgPath
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // Linear gradient: deep navy → vivid cyan (cool, security-themed).
    // Coordinates: top-left corner to bottom-right.
    let gradColors = [
        CGColor(red: 0.06, green: 0.13, blue: 0.45, alpha: 1.0),  // #0F2173 deep navy
        CGColor(red: 0.18, green: 0.31, blue: 0.78, alpha: 1.0),  // #2E50C7
        CGColor(red: 0.06, green: 0.70, blue: 0.86, alpha: 1.0),  // #10B5DC cyan
    ] as CFArray
    let stops: [CGFloat] = [0.0, 0.5, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: stops) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: bgRect.minX, y: bgRect.minY),
            end:   CGPoint(x: bgRect.maxX, y: bgRect.maxY),
            options: []
        )
    }

    // Subtle inner highlight at top for glossy feel
    let highlightRect = CGRect(x: bgRect.minX, y: bgRect.minY,
                                width: bgRect.width, height: bgRect.height * 0.45)
    let highlightColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    if let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors,
                                    locations: [0, 1]) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: highlightRect.midX, y: highlightRect.minY),
            end:   CGPoint(x: highlightRect.midX, y: highlightRect.maxY),
            options: []
        )
    }

    ctx.restoreGState()

    // ─── 2. Hexagonal sentinel shield ────────────────────────────────────
    // Hexagon (pointed top) instead of heraldic shield — distinct from
    // MacKeeper's rounded shield and security-software clichés.
    let shieldCenter = CGPoint(x: canvasRect.midX, y: canvasRect.midY)
    let shieldRadius = pixelSize * 0.30

    let hexagonPath = CGMutablePath()
    for i in 0..<6 {
        let angle = (Double(i) * .pi / 3.0) - (.pi / 2.0)  // start at top
        let x = shieldCenter.x + CGFloat(cos(angle)) * shieldRadius
        let y = shieldCenter.y + CGFloat(sin(angle)) * shieldRadius
        if i == 0 { hexagonPath.move(to: CGPoint(x: x, y: y)) }
        else      { hexagonPath.addLine(to: CGPoint(x: x, y: y)) }
    }
    hexagonPath.closeSubpath()

    // Shield fill: subtle white with low alpha, layered over base gradient
    ctx.saveGState()
    ctx.addPath(hexagonPath)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    ctx.fillPath()

    // Shield outline
    ctx.addPath(hexagonPath)
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    ctx.setLineWidth(pixelSize * 0.018)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // ─── 3. Centered pulse / sparkline ───────────────────────────────────
    // 5-segment EKG-style line representing monitoring activity.
    let pulseWidth = shieldRadius * 1.45
    let pulseY = shieldCenter.y + pixelSize * 0.015
    let amplitude = pixelSize * 0.085

    let pulsePoints: [CGPoint] = [
        .init(x: shieldCenter.x - pulseWidth * 0.5,  y: pulseY),
        .init(x: shieldCenter.x - pulseWidth * 0.20, y: pulseY),
        .init(x: shieldCenter.x - pulseWidth * 0.08, y: pulseY - amplitude * 0.9),  // up
        .init(x: shieldCenter.x + pulseWidth * 0.0,  y: pulseY + amplitude * 1.2),  // sharp down
        .init(x: shieldCenter.x + pulseWidth * 0.08, y: pulseY - amplitude * 1.4),  // sharp up (peak)
        .init(x: shieldCenter.x + pulseWidth * 0.20, y: pulseY),
        .init(x: shieldCenter.x + pulseWidth * 0.5,  y: pulseY),
    ]

    let pulsePath = CGMutablePath()
    pulsePath.move(to: pulsePoints[0])
    for p in pulsePoints.dropFirst() { pulsePath.addLine(to: p) }

    ctx.saveGState()
    ctx.addPath(pulsePath)
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1.0)
    ctx.setLineWidth(pixelSize * 0.022)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // ─── 4. Accent dot at the pulse peak ─────────────────────────────────
    let peakPoint = pulsePoints[4]
    ctx.saveGState()
    let dotRadius = pixelSize * 0.022
    ctx.setFillColor(red: 0.40, green: 1.0, blue: 0.95, alpha: 1.0)  // bright cyan
    ctx.fillEllipse(in: CGRect(x: peakPoint.x - dotRadius,
                                y: peakPoint.y - dotRadius,
                                width: dotRadius * 2,
                                height: dotRadius * 2))
    // Glow halo
    ctx.setFillColor(red: 0.40, green: 1.0, blue: 0.95, alpha: 0.35)
    let haloRadius = dotRadius * 2.2
    ctx.fillEllipse(in: CGRect(x: peakPoint.x - haloRadius,
                                y: peakPoint.y - haloRadius,
                                width: haloRadius * 2,
                                height: haloRadius * 2))
    ctx.restoreGState()

    // ─── 5. Subtle drop shadow inside the squircle for depth ─────────────
    // (Just a darkening at the bottom edge.)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    let shadowRect = CGRect(x: bgRect.minX, y: bgRect.maxY - bgRect.height * 0.25,
                             width: bgRect.width, height: bgRect.height * 0.25)
    let shadowColors = [
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
        CGColor(red: 0, green: 0, blue: 0, alpha: 0.18),
    ] as CFArray
    if let shadow = CGGradient(colorsSpace: colorSpace, colors: shadowColors,
                                locations: [0, 1]) {
        ctx.drawLinearGradient(
            shadow,
            start: CGPoint(x: shadowRect.midX, y: shadowRect.minY),
            end:   CGPoint(x: shadowRect.midX, y: shadowRect.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("Failed to create CGImage") }
    return image
}

// MARK: - NSBezierPath → CGPath helper (no UIKit on macOS)

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            case .lineTo:    path.addLine(to: CGPoint(x: points[0].x, y: points[0].y))
            case .curveTo, .cubicCurveTo:
                path.addCurve(to:      CGPoint(x: points[2].x, y: points[2].y),
                              control1: CGPoint(x: points[0].x, y: points[0].y),
                              control2: CGPoint(x: points[1].x, y: points[1].y))
            case .quadraticCurveTo:
                path.addQuadCurve(to:     CGPoint(x: points[1].x, y: points[1].y),
                                  control: CGPoint(x: points[0].x, y: points[0].y))
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// MARK: - PNG output

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  ✓ \(path) (\(image.width)×\(image.height))")
    } catch {
        fatalError("Failed to write \(path): \(error)")
    }
}

// MARK: - Contents.json builder

func writeContentsJSON(at path: String) {
    var images: [[String: String]] = []
    for size in manifest {
        images.append([
            "idiom":     size.idiom,
            "scale":     "\(size.scale)x",
            "size":      size.sizePoints,
            "filename":  size.filename,
        ])
    }
    let manifestDict: [String: Any] = [
        "images": images,
        "info": [
            "author":  "macsentinel-icon-generator",
            "version": 1,
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: manifestDict,
                                            options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(path)")
}

// MARK: - Main

print("Generating MacSentinel AppIcon set → \(outputDir)")
try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Generate unique pixel sizes only (dedupe across scale variants)
let uniqueSizes = Set(manifest.map { $0.pixels })
for size in uniqueSizes.sorted() {
    let image = renderIcon(pixelSize: size)
    writePNG(image, to: "\(outputDir)/icon_\(Int(size))x\(Int(size)).png")
}

writeContentsJSON(at: "\(outputDir)/Contents.json")
print("Done.")
