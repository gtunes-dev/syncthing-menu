// render-app-icon.swift — DEV TOOL
//
// Renders the app icon (AppIcon.appiconset, all ten renditions) from the
// design settled 2026-08-03: the Syncthing mark INVERTED — white squircle,
// Syncthing-blue ring/nodes/hub/spokes at the EXACT proportions measured
// from the official logo SVG — with a menu panel centered on the ring (the
// "menu" in Syncthing Menu). Run from the project root:
//   swift Scripts/render-app-icon.swift
//
// Exact logo geometry (from syncthing/assets/logo-only.svg): nodes ON the
// ring at −26.4° / +166.0° / +49.9° (y-down); node & hub radius 0.206·R;
// ring & spoke stroke 0.137·R; hub center offset (+0.204R, +0.133R).
//
// Small renditions simplify (Apple-sanctioned per-size art): below 128 px
// the five-row menu is unreadable, so 64/32 px drop to three rows with
// heavier weights, and 16 px to two rows with no spokes. Judged by eye in
// the icon lab.

import AppKit
import CoreGraphics

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let nodeAngles: [CGFloat] = [deg(-26.4), deg(166.0), deg(49.9)]
let blue = CGColor(red: 0x0B / 255.0, green: 0x8E / 255.0, blue: 0xD0 / 255.0, alpha: 1)
let blueLight = CGColor(red: 0x58 / 255.0, green: 0xC5 / 255.0, blue: 0xF1 / 255.0, alpha: 1)

func render(px: Int) -> Data {
    let scale = CGFloat(px) / 1024.0
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    // Size class: weights and row counts step up as the canvas shrinks.
    let tiny = px <= 16, small = px <= 64
    let quietRows = tiny ? 1 : (small ? 2 : 4)

    // macOS icon grid: content square ~824 pt in the 1024 canvas.
    let content = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: content, cornerWidth: 185, cornerHeight: 185,
                          transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let plate = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                 CGColor(red: 0.918, green: 0.949, blue: 0.969, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: plate,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100),
                           end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 0.78, green: 0.85, blue: 0.89, alpha: 1))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The inverted Syncthing mark at exact proportions (weights amplified
    // in the small classes so the mark survives the shrink).
    let center = CGPoint(x: 512, y: 512)
    let R: CGFloat = 296
    let stroke = R * (tiny ? 0.24 : small ? 0.18 : 0.137)
    let nodeRadius = R * (tiny ? 0.30 : small ? 0.25 : 0.206)
    ctx.setStrokeColor(blue); ctx.setFillColor(blue)
    ctx.setLineWidth(stroke)
    ctx.strokeEllipse(in: CGRect(x: center.x - R, y: center.y - R,
                                 width: R * 2, height: R * 2))
    let nodes = nodeAngles.map {
        CGPoint(x: center.x + R * cos($0), y: center.y + R * sin($0))
    }
    for p in nodes {
        ctx.fillEllipse(in: CGRect(x: p.x - nodeRadius, y: p.y - nodeRadius,
                                   width: nodeRadius * 2, height: nodeRadius * 2))
    }

    // Hub + spokes behind the panel, at the logo's exact hub position.
    // Dropped at 16 px — pure noise there.
    if !tiny {
        let hub = CGPoint(x: center.x + 0.204 * R, y: center.y + 0.133 * R)
        ctx.setLineWidth(stroke)
        for p in nodes {
            ctx.strokeLineSegments(between: [hub, p])
        }
        ctx.fillEllipse(in: CGRect(x: hub.x - nodeRadius, y: hub.y - nodeRadius,
                                   width: nodeRadius * 2, height: nodeRadius * 2))
    }

    // The menu panel, centered on the ring both axes. Full size: highlight
    // row + four quiet rows. Small classes: fewer, chunkier rows.
    let rowH: CGFloat = tiny ? 120 : (small ? 64 : 50)
    let quietH: CGFloat = tiny ? 90 : (small ? 52 : 26)
    let gap: CGFloat = tiny ? 56 : (small ? 40 : 20)
    let topPad: CGFloat = tiny ? 60 : (small ? 44 : 34)
    let panelH = topPad * 2 + rowH + (quietH + gap) * CGFloat(quietRows)
    let panel = CGRect(x: 362, y: 512 - panelH / 2, width: 300, height: panelH)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: small ? 56 : 34,
                           cornerHeight: small ? 56 : 34, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 42,
                  color: CGColor(red: 0.05, green: 0.25, blue: 0.38, alpha: 0.30))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(panelPath); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(panelPath)
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(small ? 40 : 22)
    ctx.strokePath()

    let inset: CGFloat = small ? 52 : 38
    let rowX = panel.minX + inset
    let rowW = panel.width - inset * 2
    ctx.setFillColor(blue)
    ctx.addPath(CGPath(roundedRect: CGRect(x: rowX, y: panel.minY + topPad,
                                           width: rowW, height: rowH),
                       cornerWidth: rowH * 0.32, cornerHeight: rowH * 0.32, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(blueLight)
    for i in 0..<quietRows {
        let y = panel.minY + topPad + rowH + gap + CGFloat(i) * (quietH + gap)
        ctx.addPath(CGPath(roundedRect: CGRect(x: rowX, y: y, width: rowW, height: quietH),
                           cornerWidth: quietH * 0.5, cornerHeight: quietH * 0.5,
                           transform: nil))
        ctx.fillPath()
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = "Sources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let renditions: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in renditions {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("rendered AppIcon.appiconset (\(renditions.count) renditions)")
