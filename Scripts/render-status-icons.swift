// render-status-icons.swift — DEV TOOL
//
// Renders the menu-bar status icons as monochrome template PNGs (1x = 18px,
// 2x = 36px) into the asset catalog. Run from the project root:
//   swift Scripts/render-status-icons.swift
//
// One mark (loop + two diagonal peer nodes) drives every state; an update badge
// (a disc with a knocked-out up-arrow) overlays when an update is available.
// Black-on-transparent so macOS renders them as templates.

import AppKit
import CoreGraphics

enum IconState { case idle, syncing, paused, error }

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

    let dim: CGFloat = (state == .paused || state == .error) ? 0.38 : 1.0

    // Loop + two diagonal peer nodes.
    ctx.saveGState()
    ctx.setAlpha(dim)
    ctx.setLineWidth(2)
    if state == .syncing { ctx.setLineDash(phase: 0, lengths: [2.3, 2.2]) }
    ctx.strokeEllipse(in: CGRect(x: 12 - 8.3, y: 12 - 8.3, width: 16.6, height: 16.6))
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.fillEllipse(in: CGRect(x: 6.3 - 2.7, y: 6.3 - 2.7, width: 5.4, height: 5.4))
    ctx.fillEllipse(in: CGRect(x: 17.7 - 2.7, y: 17.7 - 2.7, width: 5.4, height: 5.4))
    ctx.restoreGState()

    // State overlay at full strength.
    if state == .paused {
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 10, y: 9.4), CGPoint(x: 10, y: 14.6)])
        ctx.strokeLineSegments(between: [CGPoint(x: 14, y: 9.4), CGPoint(x: 14, y: 14.6)])
    }
    if state == .error {
        ctx.setLineWidth(2.2)
        ctx.strokeLineSegments(between: [CGPoint(x: 12, y: 8.4), CGPoint(x: 12, y: 13.1)])
        ctx.fillEllipse(in: CGRect(x: 12 - 1.2, y: 16.2 - 1.2, width: 2.4, height: 2.4))
    }

    // Update badge: filled disc with a knocked-out up-arrow.
    if update {
        let bx: CGFloat = 17.6, by: CGFloat = 8.0, br: CGFloat = 5.2
        ctx.setAlpha(1)
        ctx.fillEllipse(in: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [CGPoint(x: bx, y: by + 2.5), CGPoint(x: bx, y: by - 2.1)])
        ctx.strokeLineSegments(between: [CGPoint(x: bx - 2.15, y: by - 0.05), CGPoint(x: bx, y: by - 2.1),
                                         CGPoint(x: bx, y: by - 2.1), CGPoint(x: bx + 2.15, y: by - 0.05)])
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
