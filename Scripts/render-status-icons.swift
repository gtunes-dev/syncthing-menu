// render-status-icons.swift — DEV TOOL
//
// Renders the menu-bar status icons as monochrome template PNGs (1x = 18px,
// 2x = 36px) into the asset catalog. Run from the project root:
//   swift Scripts/render-status-icons.swift
//
// Design system (redesigned 2026-08-03, supersedes the 2026-07-07 family;
// developed in the icon lab with Greg's sketches):
// - The frame is the SYNCTHING LOGO's geometry: one ring with three rim
//   nodes at the exact angles measured from the official logo SVG
//   (syncthing/assets/logo-only.svg): upper-right −26.4°, left +166.0°,
//   lower-right +49.9° (y-down). Angles are exact; weights are optically
//   compensated for 18 px (exact-proportion nodes would be ~2.5 px dots).
// - Ink is binary: every stroke full-strength. Mid-alpha in template images
//   is the system's "disabled" dialect, so states never dim — the only
//   dimming is the runtime `appearsDisabled` for "not running".
// - States differ by center MASS/silhouette in the constant frame:
//   idle = empty, syncing = ↔ (data exchanged between devices),
//   paused = ‖, error = ! . Texture-level changes are imperceptible at
//   menu-bar size.
// - The update badge sits at the EXACT lower-right node position, fully
//   replacing it — "that node lights up as the update light". Halo
//   treatment: the ring opens around a knockout gap and the badge disc
//   (with a knocked-out up-arrow) floats in it. The badge may graze bare
//   stroke ends of center glyphs (a depth cue), never a semantic carrier
//   (arrowheads, the ! stem); the error dot takes the closest approach —
//   verified acceptable at real size.
//
// Black-on-transparent so macOS renders them as templates.

import AppKit
import CoreGraphics

enum IconState { case idle, syncing, paused, error }

let C = CGPoint(x: 12, y: 12)
let ringR: CGFloat = 8.0
let ringStroke: CGFloat = 1.9
let nodeR: CGFloat = 2.2

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Exact node angles from the official Syncthing logo SVG (y-down, matching
/// the flipped context). The lower-right node doubles as the update badge's
/// position.
let nodeAngles: [CGFloat] = [deg(-26.4), deg(166.0), deg(49.9)]
let badgeAngle = deg(49.9)

func nodePoint(_ angle: CGFloat) -> CGPoint {
    CGPoint(x: C.x + ringR * cos(angle), y: C.y + ringR * sin(angle))
}

func render(_ state: IconState, update: Bool, size: Int) -> Data {
    let scale = CGFloat(size) / 24.0
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 24); ctx.scaleBy(x: 1, y: -1)   // top-left origin
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.setStrokeColor(black); ctx.setFillColor(black)
    ctx.setLineWidth(ringStroke)

    // Constant frame: ring + three rim nodes merged into it, like the logo.
    ctx.strokeEllipse(in: CGRect(x: C.x - ringR, y: C.y - ringR,
                                 width: ringR * 2, height: ringR * 2))
    for a in nodeAngles {
        let p = nodePoint(a)
        ctx.fillEllipse(in: CGRect(x: p.x - nodeR, y: p.y - nodeR,
                                   width: nodeR * 2, height: nodeR * 2))
    }

    // Center glyphs.
    switch state {
    case .idle:
        break
    case .syncing:
        // Double-headed horizontal arrow: data moving between devices.
        ctx.setLineWidth(1.8)
        ctx.strokeLineSegments(between: [CGPoint(x: 8.2, y: 12), CGPoint(x: 15.8, y: 12)])
        for (tip, dir): (CGFloat, CGFloat) in [(15.8, 1), (8.2, -1)] {
            ctx.strokeLineSegments(between: [
                CGPoint(x: tip, y: 12), CGPoint(x: tip - dir * 2.0, y: 12 - 2.0),
                CGPoint(x: tip, y: 12), CGPoint(x: tip - dir * 2.0, y: 12 + 2.0),
            ])
        }
    case .paused:
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 10.0, y: 9.5), CGPoint(x: 10.0, y: 14.5)])
        ctx.strokeLineSegments(between: [CGPoint(x: 14.0, y: 9.5), CGPoint(x: 14.0, y: 14.5)])
    case .error:
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 12, y: 8.8), CGPoint(x: 12, y: 13.2)])
        ctx.fillEllipse(in: CGRect(x: 12 - 1.35, y: 16.2 - 1.35, width: 2.7, height: 2.7))
    }

    // Update badge at the lower-right node, replacing it (the plain node was
    // drawn above; the halo clear erases it before the badge disc lands).
    if update {
        let p = nodePoint(badgeAngle)
        let br: CGFloat = 4.2, halo: CGFloat = 0.9
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: p.x - br - halo, y: p.y - br - halo,
                                   width: (br + halo) * 2, height: (br + halo) * 2))
        ctx.restoreGState()
        ctx.fillEllipse(in: CGRect(x: p.x - br, y: p.y - br, width: br * 2, height: br * 2))
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.35)
        ctx.strokeLineSegments(between: [CGPoint(x: p.x, y: p.y + 2.1), CGPoint(x: p.x, y: p.y - 1.7)])
        ctx.strokeLineSegments(between: [
            CGPoint(x: p.x - 1.8, y: p.y + 0.05), CGPoint(x: p.x, y: p.y - 1.7),
            CGPoint(x: p.x, y: p.y - 1.7), CGPoint(x: p.x + 1.8, y: p.y + 0.05),
        ])
        ctx.restoreGState()
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let catalog = "Sources/Assets.xcassets"
let items: [(String, IconState, Bool)] = [
    ("StatusIdle", .idle, false),       ("StatusIdleUpdate", .idle, true),
    ("StatusSyncing", .syncing, false), ("StatusSyncingUpdate", .syncing, true),
    ("StatusPaused", .paused, false),   ("StatusPausedUpdate", .paused, true),
    ("StatusError", .error, false),     ("StatusErrorUpdate", .error, true),
]
let fm = FileManager.default
for (name, state, update) in items {
    let dir = "\(catalog)/\(name).imageset"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let base = name.lowercased()
    try! render(state, update: update, size: 18).write(to: URL(fileURLWithPath: "\(dir)/\(base).png"))
    try! render(state, update: update, size: 36).write(to: URL(fileURLWithPath: "\(dir)/\(base)@2x.png"))
    let json = "{\"images\":[{\"idiom\":\"universal\",\"filename\":\"\(base).png\",\"scale\":\"1x\"},{\"idiom\":\"universal\",\"filename\":\"\(base)@2x.png\",\"scale\":\"2x\"}],\"info\":{\"author\":\"xcode\",\"version\":1},\"properties\":{\"template-rendering-intent\":\"template\"}}"
    try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
}
print("rendered \(items.count) status-icon imagesets")
