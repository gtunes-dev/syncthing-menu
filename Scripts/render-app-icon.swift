// render-app-icon.swift — DEV TOOL
//
// Renders the app icon (AppIcon.appiconset, all ten renditions) AND the
// Settings-card mark (AppMark.imageset — a true miniature of the icon).
// Run from the project root:
//   swift Scripts/render-app-icon.swift
//
// Design (settled 2026-08-04 after eight icon-lab rounds with Greg):
// - Backdrop: the Syncthing app icon reproduced EXACTLY — squircle with the
//   logo SVG's own vertical gradient (#26B6DB → #0882C8) and the white mark
//   at the SVG's measured proportions (ring R = 0.745 × content/2, stroke
//   0.137·R, node/hub r 0.206·R, hub at (+0.204R, +0.133R), spokes at ring
//   weight, node angles −26.4° / +166.0° / +49.9° y-down).
// - Centerpiece: a macOS-style GLASS menu panel, 470 units wide (its
//   corners break the ring — deliberate; the ring reads through the glass).
//   Real frosted effect: the backdrop gaussian-blurs through a grey tint at
//   48% ("t48" — chosen over 38%/58%), white "text" rows (one highlight +
//   quiet rows), a dark rim hairline with a faint specular along the inner
//   top edge, and a soft drop shadow. A WHITE edge is wrong — it blends
//   into the white ring family (settled round 7).
// - Small renditions simplify per size class: ≤64 px uses three chunkier
//   rows and a heavier mark; 16 px two rows, no spokes. AppMark renders at
//   the tiny class regardless of pixel density (18 pt is 18 pt).
//
// The previous white-plate inverted icon is preserved in git history
// (commit 74af335) if a revert is ever wanted.

import AppKit
import CoreGraphics
import CoreImage

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let nodeAngles: [CGFloat] = [deg(-26.4), deg(166.0), deg(49.9)]

enum SizeClass {
    case full   // ≥128 px: exact proportions, five menu rows
    case small  // 64/32 px: heavier mark, three rows
    case tiny   // 16 px (and AppMark): heaviest, two rows, no spokes

    static func forPixels(_ px: Int) -> SizeClass {
        px <= 16 ? .tiny : (px <= 64 ? .small : .full)
    }
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    let output = filter.outputImage!.cropped(to: input.extent)
    return CIContext(options: nil).createCGImage(output, from: input.extent)!
}

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(px) / 1024.0
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)   // y-down 1024 space
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    return ctx
}

/// Draw a full-canvas CGImage in the flipped 1024 space (double-flip so it
/// lands upright).
func drawCanvasImage(_ ctx: CGContext, _ image: CGImage) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

/// THE PLATE SHAPE MUST BE THE CANONICAL APPLE ICON-GRID SQUIRCLE, EXACTLY
/// (root-caused live 2026-08-04): macOS 26+ shape-matches an icon's alpha
/// against the canonical grid. A match is scaled to fill the icon field
/// natively; ANY deviation — a circular-corner approximation of the
/// continuous-curvature corner, full-bleed art — gets the shrunken
/// silver-tray "legacy" treatment. Verified empirically: canonical-grid art
/// in our own appiconset renders natively; both approximations trayed.
/// `icon-grid-mask.png` is the canonical silhouette (pure alpha, Apple's
/// standard template shape — the 824-in-1024 squircle), and the plate is
/// clipped to it rather than to any hand-math shape.
let contentRect = CGRect(x: 100, y: 100, width: 824, height: 824)

let gridMask: CGImage = {
    guard let img = NSImage(contentsOfFile: "Scripts/icon-grid-mask.png"),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Scripts/icon-grid-mask.png missing — run from the repo root")
    }
    return cg
}()

/// The reproduced Syncthing icon (weights amplified in the small classes so
/// the mark survives the shrink; the FULL class is exact).
func drawBackdrop(_ ctx: CGContext, sizeClass: SizeClass) {
    let content = contentRect
    ctx.saveGState()
    // clip(to:mask:) in the flipped context: the mask is vertically
    // symmetric, so orientation is irrelevant.
    ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 1024), mask: gridMask)
    // Gradient stops sampled from Syncthing's APP ICON art (not the logo
    // SVG, whose ramp is brighter and more cyan — the mismatch read as
    // washed-out next to the real icon; measured 2026-08-04).
    let plate = [CGColor(red: 0x25 / 255.0, green: 0xA8 / 255.0, blue: 0xD3 / 255.0, alpha: 1),
                 CGColor(red: 0x10 / 255.0, green: 0x6E / 255.0, blue: 0xBC / 255.0, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: plate,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: content.minY),
                           end: CGPoint(x: 512, y: content.maxY), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let R: CGFloat = 0.745 * content.width / 2      // ≈ 307
    let strokeFactor: CGFloat
    let nodeFactor: CGFloat
    switch sizeClass {
    case .full: strokeFactor = 0.137; nodeFactor = 0.206   // exact
    case .small: strokeFactor = 0.18; nodeFactor = 0.25
    case .tiny: strokeFactor = 0.24; nodeFactor = 0.30
    }
    let nodeRadius = nodeFactor * R
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.setStrokeColor(white); ctx.setFillColor(white)
    ctx.setLineWidth(strokeFactor * R)
    ctx.strokeEllipse(in: CGRect(x: center.x - R, y: center.y - R, width: R * 2, height: R * 2))
    let nodes = nodeAngles.map {
        CGPoint(x: center.x + R * cos($0), y: center.y + R * sin($0))
    }
    let hub = CGPoint(x: center.x + 0.204 * R, y: center.y + 0.133 * R)
    if sizeClass != .tiny {
        for p in nodes {
            ctx.strokeLineSegments(between: [hub, p])
        }
    }
    for p in (sizeClass == .tiny ? nodes : nodes + [hub]) {
        ctx.fillEllipse(in: CGRect(x: p.x - nodeRadius, y: p.y - nodeRadius,
                                   width: nodeRadius * 2, height: nodeRadius * 2))
    }
}

func renderIcon(px: Int, sizeClass: SizeClass) -> Data {
    // Pass 1: backdrop at device resolution; its blur is the frosted layer.
    let backdropCtx = makeContext(px)
    drawBackdrop(backdropCtx, sizeClass: sizeClass)
    let backdrop = backdropCtx.makeImage()!

    // All panel geometry was tuned in the lab against ring R ≈ 307 (the
    // 824-grid plate); `g` rescales it to the full-bleed plate's ring so
    // the settled composition is preserved exactly.
    let R = 0.745 * contentRect.width / 2
    let g = R / 307.15
    let blurred = gaussianBlur(backdrop, radius: 30 * g * CGFloat(px) / 1024.0)

    // Pass 2: composite.
    let ctx = makeContext(px)
    drawCanvasImage(ctx, backdrop)

    // Panel: 470·g wide, centered both axes; row layout per size class.
    let panelW: CGFloat = 470 * g
    let topPad: CGFloat, hlH: CGFloat, quietH: CGFloat, gap: CGFloat
    let corner: CGFloat, inset: CGFloat, quietRows: Int, edgeW: CGFloat
    switch sizeClass {
    case .full:
        // The lab's 300-wide layout scaled to the panel width.
        let f: CGFloat = panelW / 300.0
        topPad = 34 * f; hlH = 50 * f; quietH = 26 * f; gap = 20 * f
        corner = 34 * f; inset = 38 * f; quietRows = 4; edgeW = 3 * f
    case .small:
        topPad = 60 * g; hlH = 110 * g; quietH = 78 * g; gap = 46 * g
        corner = 64 * g; inset = 64 * g; quietRows = 2; edgeW = 8 * g
    case .tiny:
        topPad = 70 * g; hlH = 150 * g; quietH = 110 * g; gap = 60 * g
        corner = 80 * g; inset = 70 * g; quietRows = 1; edgeW = 12 * g
    }
    let panelH = topPad * 2 + hlH + CGFloat(quietRows) * (gap + quietH)
    let panel = CGRect(x: 512 - panelW / 2, y: 512 - panelH / 2, width: panelW, height: panelH)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: corner, cornerHeight: corner,
                           transform: nil)

    // Shadow via an OPAQUE slab fill — NEVER a clear pass. The earlier
    // fill-then-clear trick punched a hairline ring of partial alpha along
    // the panel outline (clear-AA × clip-AA), and macOS 26's shape detector
    // reads interior alpha holes as "custom shape" → the legacy tray
    // (root-caused 2026-08-04). The opaque backdrop beneath plus an opaque
    // slab keeps interior alpha at exactly 1; the blurred glass fully
    // covers the slab inside the clip below.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -25 * g), blur: 75 * g,
                  color: CGColor(red: 0.01, green: 0.10, blue: 0.18, alpha: 0.40))
    ctx.setFillColor(CGColor(red: 0.42, green: 0.46, blue: 0.51, alpha: 1))
    ctx.addPath(panelPath); ctx.fillPath()
    ctx.restoreGState()

    // Glass: blurred backdrop through the panel + grey tint (t48) + top
    // sheen.
    ctx.saveGState()
    ctx.addPath(panelPath); ctx.clip()
    drawCanvasImage(ctx, blurred)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.46, blue: 0.51, alpha: 0.48))
    ctx.fill(CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height))
    let sheen = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray
    let sheenGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen,
                               locations: [0, 1])!
    ctx.drawLinearGradient(sheenGrad, start: CGPoint(x: 512, y: panel.minY),
                           end: CGPoint(x: 512, y: panel.minY + panel.height * 0.45),
                           options: [])
    ctx.restoreGState()

    // Rim edge: dark hairline + faint specular along the inner top edge.
    ctx.addPath(panelPath)
    ctx.setStrokeColor(CGColor(red: 0.16, green: 0.19, blue: 0.22, alpha: 0.55))
    ctx.setLineWidth(edgeW)
    ctx.strokePath()
    if sizeClass == .full {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: panel.minX, y: panel.minY,
                            width: panel.width, height: panel.height * 0.22))
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: edgeW + 2, dy: edgeW + 2),
                           cornerWidth: corner - edgeW, cornerHeight: corner - edgeW,
                           transform: nil))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.38))
        ctx.setLineWidth(edgeW * 0.8)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Rows: white "text" — a strong highlight row, then quieter rows.
    let rowX = panel.minX + inset
    let rowW = panel.width - inset * 2
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fill(CGPath(roundedRect: CGRect(x: rowX, y: panel.minY + topPad, width: rowW, height: hlH),
                    cornerWidth: hlH * 0.32, cornerHeight: hlH * 0.32, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.62))
    for i in 0..<quietRows {
        let y = panel.minY + topPad + hlH + gap + CGFloat(i) * (quietH + gap)
        ctx.fill(CGPath(roundedRect: CGRect(x: rowX, y: y, width: rowW, height: quietH),
                        cornerWidth: quietH * 0.5, cornerHeight: quietH * 0.5, transform: nil))
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

extension CGContext {
    func fill(_ path: CGPath) {
        addPath(path)
        fillPath()
    }
}

// MARK: - Output

let fm = FileManager.default

let iconDir = "Sources/Assets.xcassets/AppIcon.appiconset"
try? fm.createDirectory(atPath: iconDir, withIntermediateDirectories: true)
let renditions: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in renditions {
    // Size class follows the POINT size (the name), not pixel density: a
    // 16 pt icon at 2x is still a 16 pt icon.
    let points = Int(name.split(separator: "x")[1].split(separator: "@")[0])!
    try! renderIcon(px: px, sizeClass: .forPixels(points))
        .write(to: URL(fileURLWithPath: "\(iconDir)/\(name).png"))
}
print("rendered AppIcon.appiconset (\(renditions.count) renditions)")

// AppMark: the Settings card's chip is a true miniature of the icon —
// 18 pt, so the tiny class at both densities.
let markDir = "Sources/Assets.xcassets/AppMark.imageset"
try? fm.createDirectory(atPath: markDir, withIntermediateDirectories: true)
try! renderIcon(px: 18, sizeClass: .tiny).write(to: URL(fileURLWithPath: "\(markDir)/appmark.png"))
try! renderIcon(px: 36, sizeClass: .tiny).write(to: URL(fileURLWithPath: "\(markDir)/appmark@2x.png"))
let markJSON = "{\"images\":[{\"idiom\":\"universal\",\"filename\":\"appmark.png\",\"scale\":\"1x\"},{\"idiom\":\"universal\",\"filename\":\"appmark@2x.png\",\"scale\":\"2x\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try! markJSON.write(toFile: "\(markDir)/Contents.json", atomically: true, encoding: .utf8)
print("rendered AppMark imageset")
