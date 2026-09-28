import AppKit
import Foundation

let destination = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.045, green: 0.06, blue: 0.055, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let main = NSBezierPath(roundedRect: NSRect(x: 206, y: 208, width: 572, height: 638), xRadius: 98, yRadius: 98)
NSColor(calibratedWhite: 0.94, alpha: 1).setStroke()
main.lineWidth = 30
main.stroke()
NSColor(calibratedRed: 1, green: 0.84, blue: 0.56, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 528, y: 154, width: 310, height: 364), xRadius: 65, yRadius: 65).fill()
NSColor(calibratedRed: 0.045, green: 0.06, blue: 0.055, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 641, y: 378, width: 82, height: 82)).fill()
NSBezierPath(roundedRect: NSRect(x: 596, y: 226, width: 171, height: 112), xRadius: 52, yRadius: 52).fill()
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 415, y: 588, width: 103, height: 103)).fill()
NSBezierPath(roundedRect: NSRect(x: 348, y: 389, width: 238, height: 150), xRadius: 73, yRadius: 73).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
