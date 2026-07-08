// render-status-icons.swift — DEV TOOL
//
// Renders the menu-bar status icons as monochrome template PNGs (1x = 18px,
// 2x = 36px) into the asset catalog. Run from the project root:
//   swift Scripts/render-status-icons.swift
//
// Design system (decided 2026-07-07):
// - Ink is binary: every stroke full-strength. Mid-alpha in template images is
//   the system's "disabled" dialect (Apple dims disabled items to ~35%), so
//   states never dim — the only dimming is the runtime `appearsDisabled` for
//   "not running".
// - The frame (loop + two diagonal peer nodes) is the constant identity;
//   idle's center is empty and every other state puts a full-strength glyph
//   there: syncing ⇄ (data moving between the peers), paused ‖, error !.
//   States must differ in center MASS — texture- or outline-level changes
//   (a dashed ring, arc gaps + arrowheads) are imperceptible at menu-bar size.
// - The update badge (disc with knocked-out up-arrow) floats on a knockout
//   halo, SF Symbols-style, instead of merging into the ring's ink. Where it
//   overlaps a center glyph it occludes cleanly (a depth cue), and glyph
//   geometry keeps every semantic carrier (arrowheads, the ! stem) visible.
//
// Black-on-transparent so macOS renders them as templates.

import AppKit
import CoreGraphics

enum IconState { case idle, syncing, paused, error }

let center = CGPoint(x: 12, y: 12)
let ringRadius: CGFloat = 8.3

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Stroke an arc ending in an arrowhead that points along the direction of
/// travel (increasing angle = visually clockwise in the flipped context).
func arcArrow(_ ctx: CGContext, radius: CGFloat, from a0: CGFloat, to a1: CGFloat, head: CGFloat) {
    let path = CGMutablePath()
    path.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
    ctx.addPath(path)
    ctx.strokePath()
    let tip = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    let t = CGPoint(x: -sin(a1), y: cos(a1))          // direction of travel
    let n = CGPoint(x: cos(a1), y: sin(a1))           // radial
    for s: CGFloat in [1, -1] {
        let wing = CGPoint(x: tip.x - head * t.x + s * head * 0.62 * n.x,
                           y: tip.y - head * t.y + s * head * 0.62 * n.y)
        ctx.strokeLineSegments(between: [tip, wing])
    }
}

func nodes(_ ctx: CGContext) {
    ctx.fillEllipse(in: CGRect(x: 6.3 - 2.7, y: 6.3 - 2.7, width: 5.4, height: 5.4))
    ctx.fillEllipse(in: CGRect(x: 17.7 - 2.7, y: 17.7 - 2.7, width: 5.4, height: 5.4))
}

func render(_ state: IconState, update: Bool, size: Int) -> Data {
    let scale = CGFloat(size) / 24.0
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 24); ctx.scaleBy(x: 1, y: -1)   // top-left origin (SVG-like)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    ctx.setStrokeColor(black); ctx.setFillColor(black)
    ctx.setLineWidth(2)

    // Constant frame: full ring + peer nodes for every state.
    ctx.strokeEllipse(in: CGRect(x: 12 - ringRadius, y: 12 - ringRadius,
                                 width: ringRadius * 2, height: ringRadius * 2))
    nodes(ctx)

    // Syncing: a small nested loop with an arrowhead riding its line —
    // progress around a cycle. Hollow, so it stays airy where solid center
    // glyphs read as a blob. The sweep starts top-right and the arrowhead
    // lands top-left, so the update badge occludes only a bare arc end.
    if state == .syncing {
        arcArrow(ctx, radius: 4.0, from: deg(-45), to: deg(255), head: 2.2)
    }

    // Condition glyphs, full strength, in the ring's empty center. Positions
    // are tuned so the update badge's halo either clears them or occludes
    // cleanly (no orphaned stubs) — check the update variants after moving.
    if state == .paused {
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 9.4, y: 9.6), CGPoint(x: 9.4, y: 14.4)])
        ctx.strokeLineSegments(between: [CGPoint(x: 13.8, y: 9.6), CGPoint(x: 13.8, y: 14.4)])
    }
    if state == .error {
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 12, y: 8.6), CGPoint(x: 12, y: 13.2)])
        ctx.fillEllipse(in: CGRect(x: 12 - 1.3, y: 16.3 - 1.3, width: 2.6, height: 2.6))
    }

    // Update badge: knockout halo, filled disc, knocked-out up-arrow.
    if update {
        let bx: CGFloat = 17.8, by: CGFloat = 7.8, br: CGFloat = 4.8, halo: CGFloat = 1.0
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: bx - br - halo, y: by - br - halo,
                                   width: (br + halo) * 2, height: (br + halo) * 2))
        ctx.restoreGState()
        ctx.fillEllipse(in: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.4)
        ctx.strokeLineSegments(between: [CGPoint(x: bx, y: by + 2.3), CGPoint(x: bx, y: by - 1.9)])
        ctx.strokeLineSegments(between: [CGPoint(x: bx - 2.0, y: by + 0.05), CGPoint(x: bx, y: by - 1.9),
                                         CGPoint(x: bx, y: by - 1.9), CGPoint(x: bx + 2.0, y: by + 0.05)])
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
