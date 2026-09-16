#!/usr/bin/env swift
//
// Draws grrclone's app icon and writes build/AppIcon.iconset.
//
//   swift scripts/make-icon.swift
//   iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
//
// Generated in code rather than shipped as a binary blob, so the design is reviewable
// in a diff and every size is drawn from geometry instead of resampled from one bitmap.
// That matters more than it sounds: 16pt is a different design problem, not a smaller
// version of the same one, and downsampling the large icon produces mush.
//
// The mark is an angry storm cloud in rclone's own blue. The cloud says what kind of
// app this is, the palette is taken from rclone's logo so it reads as an rclone front
// end rather than a generic cloud utility, and the scowl is the point of the name.
//
// Only the colours are sampled from rclone's published logo. The shapes are original:
// this deliberately does not reproduce rclone's mark, which is someone else's artwork.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1)
}

enum Palette {
    static let skyTop    = rgb(96, 178, 226)   // rclone's mid blue, lifted
    static let skyBottom = rgb(34, 78, 130)
    static let cloud     = rgb(255, 255, 255)
    static let features  = rgb(24, 58, 98)     // brows and eyes
    static let bolt      = rgb(255, 202, 40)
}

func drawIcon(size s: CGFloat, context ctx: CGContext) {
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Below 32pt the icon is a different design. The margin tightens, the cloud grows,
    // and the bolt and eyes are dropped: at that size each is two or three pixels and
    // turns the mark into noise. The brows stay, because two heavy diagonals are the
    // only part of an expression that still reads that small.
    let compact = s <= 32

    let inset = s * (compact ? 0.05 : 0.094)
    let plate = CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let corner = plate.width * 0.2246   // the Big Sur ratio; what makes it read as a Mac icon

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                       transform: nil))
    ctx.clip()
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [Palette.skyTop, Palette.skyBottom] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    }
    ctx.restoreGState()

    // MARK: Cloud

    let w = plate.width * (compact ? 0.86 : 0.70)
    let box = CGRect(x: plate.midX - w/2,
                     y: plate.minY + plate.height * (compact ? 0.30 : 0.365),
                     width: w, height: w * 0.50)

    let cloud = CGMutablePath()
    let slab = w * 0.25
    cloud.addRoundedRect(in: CGRect(x: box.minX, y: box.minY, width: w, height: slab),
                         cornerWidth: slab*0.45, cornerHeight: slab*0.45)
    // Each lobe's centre sits low enough that its circle cuts into the slab. Circles
    // that merely touch it leave notches where the curves meet, and the silhouette
    // stops looking like a cloud.
    for (r, cx, cy) in [(0.160, 0.20, 0.160), (0.245, 0.47, 0.220), (0.180, 0.79, 0.170)] {
        let rr = w * CGFloat(r)
        cloud.addEllipse(in: CGRect(x: box.minX + w*CGFloat(cx) - rr,
                                    y: box.minY + w*CGFloat(cy) - rr,
                                    width: rr*2, height: rr*2))
    }
    ctx.saveGState()
    if !compact {
        ctx.setShadow(offset: CGSize(width: 0, height: -s*0.005), blur: s*0.018,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
    }
    ctx.setFillColor(Palette.cloud)
    ctx.addPath(cloud)
    ctx.fillPath()
    ctx.restoreGState()

    // MARK: The scowl

    let browWidth = w * (compact ? 0.32 : 0.26)
    let browHeight = w * (compact ? 0.115 : 0.075)
    let browY = box.minY + w * (compact ? 0.250 : 0.250)
    let browGap = w * (compact ? 0.030 : 0.045)
    let tilt: CGFloat = compact ? 0.52 : 0.44

    ctx.setFillColor(Palette.features)
    for side in [-1.0, 1.0] as [CGFloat] {
        ctx.saveGState()
        ctx.translateBy(x: box.midX + side * (browGap + browWidth/2), y: browY)
        ctx.rotate(by: side * tilt)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -browWidth/2, y: -browHeight/2,
                                               width: browWidth, height: browHeight),
                           cornerWidth: browHeight/2, cornerHeight: browHeight/2,
                           transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    if !compact {
        // Eyes sit clear of the brows rather than beneath them. Overlapped, the two
        // merge into one dark smear and the face loses its expression entirely.
        let eyeR = w * 0.050
        let eyeGap = w * 0.100
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.fillEllipse(in: CGRect(x: box.midX + side*eyeGap - eyeR,
                                       y: box.minY + w*0.120 - eyeR,
                                       width: eyeR*2, height: eyeR*2))
        }

        // Bolt below the cloud, for the storm.
        let bw = w * 0.20, bh = w * 0.28
        let bx = plate.midX - bw/2, by = plate.minY + plate.height * 0.135
        let bolt = CGMutablePath()
        bolt.move(to: CGPoint(x: bx + bw*0.62, y: by + bh))
        bolt.addLine(to: CGPoint(x: bx, y: by + bh*0.40))
        bolt.addLine(to: CGPoint(x: bx + bw*0.42, y: by + bh*0.40))
        bolt.addLine(to: CGPoint(x: bx + bw*0.30, y: by))
        bolt.addLine(to: CGPoint(x: bx + bw, y: by + bh*0.58))
        bolt.addLine(to: CGPoint(x: bx + bw*0.56, y: by + bh*0.58))
        bolt.closeSubpath()
        ctx.setFillColor(Palette.bolt)
        ctx.addPath(bolt)
        ctx.fillPath()
    }
}

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    drawIcon(size: CGFloat(size), context: ctx)
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                        UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: fm.currentDirectoryPath)
    .appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let image = render(size: px) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8)); exit(1)
    }
    try write(image, to: iconset.appendingPathComponent("\(name).png"))
    print("  \(name).png  \(px)x\(px)")
}
print("\nwrote \(iconset.path)")
