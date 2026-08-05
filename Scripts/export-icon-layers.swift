// export-icon-layers.swift — DEV TOOL
//
// Exports the app icon's design as SEPARATE VECTOR LAYERS (SVG) for
// assembly in Apple's Icon Composer into an AppIcon.icon document — the
// first-class macOS 26+ icon format (declared layers + real Liquid Glass
// materials, instead of the legacy-PNG compatibility heuristics that skip
// the depth treatment on our art). Run from the repo root:
//   swift Scripts/export-icon-layers.swift
// Writes into icon-lab/layers/ (untracked). Assembly steps:
// icon-lab/layers/RECIPE.md.
//
// Geometry: laid out on the FULL 1024 canvas — Icon Composer's canvas maps
// edge-to-edge to the icon field (the system supplies the squircle mask),
// so the mark scales as ring R = 0.745 × 512. All numbers derive from the
// ratios measured from the official Syncthing logo SVG. These layers are
// the geometric source of truth behind Sources/AppIcon.icon (the .icon
// package embeds copies; re-run this if the geometry ever changes).

import Foundation

func deg(_ d: Double) -> Double { d * .pi / 180 }

let center = (x: 512.0, y: 512.0)
let R = 0.745 * 512.0                    // ≈ 381.4
let ringStroke = 0.137 * R               // ≈ 52.3
let nodeR = 0.206 * R                    // ≈ 78.6
let hub = (x: center.x + 0.204 * R, y: center.y + 0.133 * R)
let nodeAngles = [deg(-26.4), deg(166.0), deg(49.9)]
let nodes = nodeAngles.map { (x: center.x + R * cos($0), y: center.y + R * sin($0)) }

// Panel: the settled 470-wide-at-R≈307 composition, rescaled to this R.
let g = R / 307.15
let panelW = 470.0 * g                   // ≈ 583.6
let f = panelW / 300.0
let topPad = 34 * f, hlH = 50 * f, quietH = 26 * f, gap = 20 * f
let panelH = topPad * 2 + hlH + 4 * (gap + quietH)
let panel = (x: center.x - panelW / 2, y: center.y - panelH / 2, w: panelW, h: panelH)
let panelCorner = 34 * f
let inset = 38 * f
let rowX = panel.x + inset
let rowW = panel.w - inset * 2

func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\">" + body + "</svg>"
}
func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double,
                 fill: String = "#FFFFFF") -> String {
    "<rect x=\"\(fmt(x))\" y=\"\(fmt(y))\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" rx=\"\(fmt(r))\" fill=\"\(fill)\"/>"
}

// Layer 1 — the white Syncthing mark (ring, spokes, hub, nodes).
var mark = "<circle cx=\"512\" cy=\"512\" r=\"\(fmt(R))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"\(fmt(ringStroke))\"/>"
for n in nodes {
    mark += "<line x1=\"\(fmt(hub.x))\" y1=\"\(fmt(hub.y))\" x2=\"\(fmt(n.x))\" y2=\"\(fmt(n.y))\" stroke=\"#FFFFFF\" stroke-width=\"\(fmt(ringStroke))\" stroke-linecap=\"round\"/>"
}
for n in nodes + [hub] {
    mark += "<circle cx=\"\(fmt(n.x))\" cy=\"\(fmt(n.y))\" r=\"\(fmt(nodeR))\" fill=\"#FFFFFF\"/>"
}

// Layer 2 — the menu panel shape (glass material applied in Icon Composer).
let panelSVG = roundedRect(panel.x, panel.y, panel.w, panel.h, panelCorner)

// Layer 3 — the highlight row.
let highlightSVG = roundedRect(rowX, panel.y + topPad, rowW, hlH, hlH * 0.32)

// Layer 4 — the four quiet rows.
var quiet = ""
for i in 0..<4 {
    let y = panel.y + topPad + hlH + gap + Double(i) * (quietH + gap)
    quiet += roundedRect(rowX, y, rowW, quietH, quietH * 0.5)
}

let outDir = "icon-lab/layers"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, body) in [("1-mark", mark), ("2-panel", panelSVG),
                     ("3-row-highlight", highlightSVG), ("4-rows-quiet", quiet)] {
    try! svg(body).write(toFile: "\(outDir)/\(name).svg", atomically: true, encoding: .utf8)
}
print("exported 4 SVG layers → \(outDir)")
