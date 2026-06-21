// render-app-mark.swift — DEV TOOL
//
// Renders the app's brand mark — the same loop + two diagonal nodes as the app
// icon and the menu-bar mark — as a small FULL-COLOR, borderless image, so the
// Settings "Syncthing Menu" card can show a color icon that pairs with the
// full-color Syncthing logo (rather than our monochrome menu-bar template).
//
// The loop is a cyan -> blue vertical gradient echoing the app icon. The two nodes
// are drawn separately as white-rimmed light radial "spheres" so they read like the
// app icon's glowing nodes — not flat dark dots. Run from the project root:
//   swift Scripts/render-app-mark.swift

import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let scale = CGFloat(size) / 24.0
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 24); ctx.scaleBy(x: 1, y: -1)   // top-left origin
    let space = CGColorSpaceCreateDeviceRGB()

    // Loop: cyan -> blue gradient-filled stroke.
    let loop = CGPath(ellipseIn: CGRect(x: 12 - 8.3, y: 12 - 8.3, width: 16.6, height: 16.6),
                      transform: nil)
    let loopOutline = loop.copy(strokingWithWidth: 2.4, lineCap: .round, lineJoin: .round,
                                miterLimit: 10)
    ctx.saveGState()
    ctx.addPath(loopOutline); ctx.clip()
    let loopColors = [CGColor(red: 0.18, green: 0.74, blue: 0.94, alpha: 1),
                      CGColor(red: 0.06, green: 0.48, blue: 0.86, alpha: 1)] as CFArray
    let loopGrad = CGGradient(colorsSpace: space, colors: loopColors, locations: [0, 1])!
    ctx.drawLinearGradient(loopGrad, start: CGPoint(x: 12, y: 0), end: CGPoint(x: 12, y: 24),
                           options: [])
    ctx.restoreGState()

    // Nodes: a white rim (cuts the loop and gives the app icon's bright outline) plus
    // a light radial sphere with a top-left highlight.
    let nodes = [CGPoint(x: 6.3, y: 6.3), CGPoint(x: 17.7, y: 17.7)]
    let sphereColors = [CGColor(red: 0.80, green: 0.96, blue: 1.00, alpha: 1),
                        CGColor(red: 0.22, green: 0.74, blue: 0.93, alpha: 1)] as CFArray
    let sphereGrad = CGGradient(colorsSpace: space, colors: sphereColors, locations: [0, 1])!
    for c in nodes {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: c.x - 3.4, y: c.y - 3.4, width: 6.8, height: 6.8))

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5.0, height: 5.0))
        ctx.clip()
        let highlight = CGPoint(x: c.x - 0.9, y: c.y - 0.9)   // toward top-left
        ctx.drawRadialGradient(sphereGrad, startCenter: highlight, startRadius: 0,
                               endCenter: c, endRadius: 3.0, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = "Sources/Assets.xcassets/AppMark.imageset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! render(size: 18).write(to: URL(fileURLWithPath: "\(dir)/appmark.png"))
try! render(size: 36).write(to: URL(fileURLWithPath: "\(dir)/appmark@2x.png"))
let json = "{\"images\":[{\"idiom\":\"universal\",\"filename\":\"appmark.png\",\"scale\":\"1x\"},{\"idiom\":\"universal\",\"filename\":\"appmark@2x.png\",\"scale\":\"2x\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
print("rendered AppMark imageset")
