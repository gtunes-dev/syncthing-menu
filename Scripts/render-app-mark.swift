// render-app-mark.swift — DEV TOOL
//
// Renders the app's brand mark — the 2026-08-03 identity: the Syncthing
// ring + three rim nodes (exact logo angles) in Syncthing blue with the
// menu panel in the center — as a small FULL-COLOR, borderless image for
// the Settings "Syncthing Menu" card, pairing with the full-color
// Syncthing logo on the other card. Run from the project root:
//   swift Scripts/render-app-mark.swift
//
// Same geometry family as the menu-bar template icons and the app icon;
// the panel simplifies to highlight + two rows at this size.

import AppKit
import CoreGraphics

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

let nodeAngles: [CGFloat] = [deg(-26.4), deg(166.0), deg(49.9)]
let blue = CGColor(red: 0x0B / 255.0, green: 0x8E / 255.0, blue: 0xD0 / 255.0, alpha: 1)
let blueLight = CGColor(red: 0x58 / 255.0, green: 0xC5 / 255.0, blue: 0xF1 / 255.0, alpha: 1)

func render(size: Int) -> Data {
    let scale = CGFloat(size) / 24.0
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 24); ctx.scaleBy(x: 1, y: -1)   // top-left origin
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    let center = CGPoint(x: 12, y: 12)
    let R: CGFloat = 8.0

    // Ring + nodes, Syncthing blue.
    ctx.setStrokeColor(blue); ctx.setFillColor(blue)
    ctx.setLineWidth(1.9)
    ctx.strokeEllipse(in: CGRect(x: center.x - R, y: center.y - R, width: R * 2, height: R * 2))
    for a in nodeAngles {
        let p = CGPoint(x: center.x + R * cos(a), y: center.y + R * sin(a))
        ctx.fillEllipse(in: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4))
    }

    // Menu panel: white fill so it lifts off the ring on any background,
    // blue border, highlight row + two quiet rows.
    let panel = CGRect(x: 8.6, y: 8.2, width: 6.8, height: 7.6)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: 1.1, cornerHeight: 1.1,
                           transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(panelPath); ctx.fillPath()
    ctx.addPath(panelPath)
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(0.9)
    ctx.strokePath()

    let rowX = panel.minX + 1.2
    let rowW = panel.width - 2.4
    ctx.setFillColor(blue)
    ctx.fill(CGRect(x: rowX, y: panel.minY + 1.2, width: rowW, height: 1.5))
    ctx.setFillColor(blueLight)
    ctx.fill(CGRect(x: rowX, y: panel.minY + 3.6, width: rowW, height: 1.1))
    ctx.fill(CGRect(x: rowX, y: panel.minY + 5.5, width: rowW, height: 1.1))

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = "Sources/Assets.xcassets/AppMark.imageset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! render(size: 18).write(to: URL(fileURLWithPath: "\(dir)/appmark.png"))
try! render(size: 36).write(to: URL(fileURLWithPath: "\(dir)/appmark@2x.png"))
let json = "{\"images\":[{\"idiom\":\"universal\",\"filename\":\"appmark.png\",\"scale\":\"1x\"},{\"idiom\":\"universal\",\"filename\":\"appmark@2x.png\",\"scale\":\"2x\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
print("rendered AppMark imageset")
