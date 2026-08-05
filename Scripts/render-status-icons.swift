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
// - Ring GROWN 2026-08-05 (icon-lab ring trial, r95): radius 8.0 → 9.5 for
//   interior legibility — outer Ø 13.4px → 15.7px at 1x, near Bjango's
//   ~16pt circular guideline. Center glyphs scale with the interior
//   (glyphScale); ring stroke / node r / badge stay at their prior optical
//   sizes — a larger ring needs less amplification, so holding them fixed
//   drifts back toward the logo's true proportions (and keeps the badge
//   ink inside the canvas). The binding ink constraint is the LEFT node
//   (166°): ~0.4px canvas margin at 1x — do not grow the ring further.
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
//   verified acceptable at real size (and the graze shrank with the 9.5
//   ring: the badge moved outward faster than the dot). The halo now clips
//   the canvas corner — harmless, it's an eraser.
//
// Black-on-transparent so macOS renders them as templates.

import AppKit
import CoreGraphics

enum IconState { case idle, syncing, paused, error }

let C = CGPoint(x: 12, y: 12)
let ringR: CGFloat = 9.5
let ringStroke: CGFloat = 1.9
let nodeR: CGFloat = 2.2
/// Center glyphs were drawn for the original 8.0 ring (interior radius
/// 7.05); they scale with the interior so they claim the space the larger
/// ring opened up.
let glyphScale: CGFloat = (ringR - ringStroke / 2) / 7.05

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Exact node angles from the official Syncthing logo SVG (y-down, matching
/// the flipped context). The lower-right node doubles as the update badge's
/// position.
let nodeAngles: [CGFloat] = [deg(-26.4), deg(166.0), deg(49.9)]
let badgeAngle = deg(49.9)

func nodePoint(_ angle: CGFloat) -> CGPoint {
    CGPoint(x: C.x + ringR * cos(angle), y: C.y + ringR * sin(angle))
}

/// Glyph-space point: offset from center in original-ring units, scaled.
func gp(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
    CGPoint(x: C.x + dx * glyphScale, y: C.y + dy * glyphScale)
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
        ctx.setLineWidth(1.8 * glyphScale)
        ctx.strokeLineSegments(between: [gp(-3.8, 0), gp(3.8, 0)])
        for (tip, dir): (CGFloat, CGFloat) in [(3.8, 1), (-3.8, -1)] {
            ctx.strokeLineSegments(between: [
                gp(tip, 0), gp(tip - dir * 2.0, -2.0),
                gp(tip, 0), gp(tip - dir * 2.0, 2.0),
            ])
        }
    case .paused:
        ctx.setLineWidth(2.2 * glyphScale)
        ctx.strokeLineSegments(between: [gp(-2.0, -2.5), gp(-2.0, 2.5)])
        ctx.strokeLineSegments(between: [gp(2.0, -2.5), gp(2.0, 2.5)])
    case .error:
        ctx.setLineWidth(2.2 * glyphScale)
        ctx.strokeLineSegments(between: [gp(0, -3.2), gp(0, 1.2)])
        let dot = gp(0, 4.2), dr = 1.35 * glyphScale
        ctx.fillEllipse(in: CGRect(x: dot.x - dr, y: dot.y - dr, width: dr * 2, height: dr * 2))
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
