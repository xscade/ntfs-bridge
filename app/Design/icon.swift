// Renders the NTFS Bridge app icon: a suspension-bridge arch over a drive slab.
// Usage: swift icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// macOS icon grid: 824pt body inset 100pt, corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + gradient body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
ctx.addPath(squircle); ctx.setFillColor(c(0.06, 0.09, 0.22)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [c(0.05, 0.10, 0.30), c(0.07, 0.33, 0.58), c(0.10, 0.70, 0.72)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 150, y: 120), end: CGPoint(x: 880, y: 920), options: [])
// Soft top glow.
let glow = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.18), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])

// Drive slab (bottom), with an activity light.
let slab = CGRect(x: 210, y: 220, width: 604, height: 150)
let slabPath = CGPath(roundedRect: slab, cornerWidth: 46, cornerHeight: 46, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: c(0, 0, 0, 0.35))
ctx.addPath(slabPath); ctx.setFillColor(c(0.93, 0.96, 1.0)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(slabPath); ctx.clip()
let slabShade = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0), c(0.55, 0.65, 0.80, 0.35)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(slabShade, start: CGPoint(x: 0, y: 370), end: CGPoint(x: 0, y: 220), options: [])
ctx.resetClip(); ctx.addPath(squircle); ctx.clip()
ctx.setFillColor(c(0.20, 0.85, 0.55)); ctx.fillEllipse(in: CGRect(x: 714, y: 278, width: 36, height: 36))
ctx.setFillColor(c(0.62, 0.70, 0.82))
for i in 0..<4 { ctx.fill(CGRect(x: 270 + CGFloat(i) * 46, y: 282, width: 24, height: 32).insetBy(dx: 0, dy: 0)) }

// Bridge: two towers, a main cable arch, deck, and hangers.
let white = c(1, 1, 1)
ctx.setStrokeColor(white); ctx.setFillColor(white); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let deckY: CGFloat = 470
let towers: [CGFloat] = [330, 694]
for x in towers { ctx.fill(CGRect(x: x - 22, y: deckY - 40, width: 44, height: 330)) }
// Main cable: span between tower tops, sagging toward the middle, plus side cables.
ctx.setLineWidth(22)
let top: CGFloat = deckY + 290
ctx.move(to: CGPoint(x: towers[0], y: top))
ctx.addQuadCurve(to: CGPoint(x: towers[1], y: top), control: CGPoint(x: 512, y: deckY - 30))
ctx.move(to: CGPoint(x: towers[0], y: top)); ctx.addQuadCurve(to: CGPoint(x: 190, y: deckY + 6), control: CGPoint(x: 250, y: deckY + 70))
ctx.move(to: CGPoint(x: towers[1], y: top)); ctx.addQuadCurve(to: CGPoint(x: 834, y: deckY + 6), control: CGPoint(x: 774, y: deckY + 70))
ctx.strokePath()
// Hangers follow the cable curve.
ctx.setLineWidth(9)
for i in 1..<8 {
    let t = CGFloat(i) / 8
    let x = (1 - t) * (1 - t) * towers[0] + 2 * (1 - t) * t * 512 + t * t * towers[1]
    let y = (1 - t) * (1 - t) * top + 2 * (1 - t) * t * (deckY - 30) + t * t * top
    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: deckY + 20))
}
ctx.strokePath()
// Deck.
ctx.fill(CGRect(x: 180, y: deckY, width: 664, height: 30))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
