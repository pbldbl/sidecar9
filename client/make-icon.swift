// Рисует иконку приложения: открытый ноутбук в стиле iOS 6 (тёмный экран, серебристый корпус,
// клавиатура, тачпад). Запуск: swift make-icon.swift → Icon-29/40/58/76/80/152.png рядом со скриптом.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func gradient(_ ctx: CGContext, _ rect: CGRect, _ from: CGColor, _ to: CGColor, vertical: Bool = true) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let g = CGGradient(colorsSpace: cs, colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: rect)
    if vertical { ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []) }
    else { ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.midY), end: CGPoint(x: rect.maxX, y: rect.midY), options: []) }
    ctx.restoreGState()
}

func draw(size: Int, to path: String) {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setShouldAntialias(true)
    // координаты: y вверх (CoreGraphics). Верх иконки = s.

    // фон: тёмно-серый металл, чтобы серебро корпуса читалось
    gradient(ctx, CGRect(x: 0, y: 0, width: s, height: s), rgb(0.30, 0.31, 0.33), rgb(0.12, 0.12, 0.13))

    // --- крышка с экраном (верхние ~55%) ---
    let lidRect = CGRect(x: s * 0.10, y: s * 0.47, width: s * 0.80, height: s * 0.47)
    let lid = CGPath(roundedRect: lidRect, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
    ctx.saveGState(); ctx.addPath(lid); ctx.clip()
    gradient(ctx, lidRect, rgb(0.88, 0.88, 0.90), rgb(0.70, 0.70, 0.73))
    ctx.restoreGState()
    // тонкий тёмный кант крышки
    ctx.addPath(lid); ctx.setStrokeColor(rgb(0.25, 0.25, 0.27)); ctx.setLineWidth(max(1, s * 0.008)); ctx.strokePath()
    // экран
    let inset = s * 0.045
    let scr = CGRect(x: lidRect.minX + inset, y: lidRect.minY + inset * 0.9, width: lidRect.width - 2 * inset, height: lidRect.height - 1.9 * inset)
    let scrPath = CGPath(roundedRect: scr, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil)
    ctx.saveGState(); ctx.addPath(scrPath); ctx.clip()
    gradient(ctx, scr, rgb(0.16, 0.17, 0.19), rgb(0.03, 0.03, 0.04))
    // отражение клавиатуры в экране: бледные ряды
    ctx.setFillColor(rgb(1, 1, 1, 0.045))
    let rrows = 4
    for r in 0..<rrows {
        let y = scr.minY + scr.height * (0.08 + CGFloat(r) * 0.11)
        let cols = 12
        let kw = scr.width * 0.06, gap = scr.width * 0.012
        for c in 0..<cols {
            let x = scr.minX + scr.width * 0.07 + CGFloat(c) * (kw + gap)
            ctx.fill(CGRect(x: x, y: y, width: kw, height: scr.height * 0.07))
        }
    }
    // блик по верхней части экрана
    gradient(ctx, CGRect(x: scr.minX, y: scr.midY, width: scr.width, height: scr.height / 2), rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0.0))
    ctx.restoreGState()
    // камера
    ctx.setFillColor(rgb(0.15, 0.15, 0.17)); ctx.fillEllipse(in: CGRect(x: s / 2 - s * 0.012, y: lidRect.maxY - inset * 0.55, width: s * 0.024, height: s * 0.024))

    // --- корпус с клавиатурой (нижние ~45%) ---
    let baseRect = CGRect(x: s * 0.06, y: s * 0.05, width: s * 0.88, height: s * 0.44)
    let base = CGPath(roundedRect: baseRect, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
    // тень под корпусом
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(base); ctx.setFillColor(rgb(0.8, 0.8, 0.82)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(base); ctx.clip()
    gradient(ctx, baseRect, rgb(0.93, 0.93, 0.95), rgb(0.72, 0.72, 0.75))
    // передняя кромка чуть темнее
    gradient(ctx, CGRect(x: baseRect.minX, y: baseRect.minY, width: baseRect.width, height: s * 0.05), rgb(0.72, 0.72, 0.75, 0), rgb(0.55, 0.55, 0.58))
    ctx.restoreGState()
    ctx.addPath(base); ctx.setStrokeColor(rgb(0.45, 0.45, 0.48)); ctx.setLineWidth(max(1, s * 0.006)); ctx.strokePath()
    // петля между крышкой и корпусом
    ctx.setFillColor(rgb(0.35, 0.35, 0.38)); ctx.fill(CGRect(x: s * 0.20, y: s * 0.465, width: s * 0.60, height: s * 0.012))

    // клавиатура
    let kbRect = CGRect(x: baseRect.minX + s * 0.05, y: baseRect.minY + s * 0.17, width: baseRect.width - s * 0.10, height: s * 0.24)
    let kbWell = CGPath(roundedRect: kbRect.insetBy(dx: -s * 0.008, dy: -s * 0.008), cornerWidth: s * 0.012, cornerHeight: s * 0.012, transform: nil)
    ctx.addPath(kbWell); ctx.setFillColor(rgb(0.62, 0.62, 0.65)); ctx.fillPath()
    let rows: [[CGFloat]] = [   // относительные ширины клавиш по рядам (сверху вниз)
        Array(repeating: 1, count: 14),
        [1.4] + Array(repeating: 1, count: 12) + [1.5],
        [1.6] + Array(repeating: 1, count: 12) + [1.3],
        [2.0] + Array(repeating: 1, count: 11) + [2.0],
        [1.2, 1.2, 1.5, 6.4, 1.5, 1.2, 1.2],
    ]
    let gap = s * 0.006
    let rowH = (kbRect.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
    for (ri, row) in rows.enumerated() {
        let total = row.reduce(0, +)
        let unit = (kbRect.width - gap * CGFloat(row.count - 1)) / total
        var x = kbRect.minX
        let y = kbRect.maxY - CGFloat(ri + 1) * rowH - CGFloat(ri) * gap
        let h = ri == 0 ? rowH * 0.7 : rowH
        for w in row {
            let key = CGRect(x: x, y: y + (rowH - h), width: unit * w, height: h)
            let kp = CGPath(roundedRect: key, cornerWidth: s * 0.006, cornerHeight: s * 0.006, transform: nil)
            ctx.saveGState(); ctx.addPath(kp); ctx.clip()
            gradient(ctx, key, rgb(0.22, 0.22, 0.24), rgb(0.08, 0.08, 0.09))
            ctx.restoreGState()
            x += unit * w + gap
        }
    }
    // тачпад
    let tp = CGRect(x: s / 2 - s * 0.14, y: baseRect.minY + s * 0.035, width: s * 0.28, height: s * 0.115)
    let tpp = CGPath(roundedRect: tp, cornerWidth: s * 0.012, cornerHeight: s * 0.012, transform: nil)
    ctx.saveGState(); ctx.addPath(tpp); ctx.clip()
    gradient(ctx, tp, rgb(0.80, 0.80, 0.83), rgb(0.86, 0.86, 0.88))
    ctx.restoreGState()
    ctx.addPath(tpp); ctx.setStrokeColor(rgb(0.58, 0.58, 0.62)); ctx.setLineWidth(max(1, s * 0.005)); ctx.strokePath()

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
for size in [29, 40, 58, 76, 80, 152, 512] {   // 512 — превью для README, в бандл не идёт
    draw(size: size, to: size == 512 ? "\(dir)/../docs/icon-preview.png" : "\(dir)/Icon-\(size).png")
}
print("иконки готовы")
