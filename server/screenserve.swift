// screenserve: отдаёт один дисплей Mac (виртуальный DeskPad) нативному клиенту на iPad.
// Захват ScreenCaptureKit, по сети идут только изменившиеся прямоугольники (raw deflate).
// Протокол (little-endian):
//   клиент -> сервер: "MSC1"
//   сервер -> клиент: 1 INFO  u16 w, u16 h, u8 bpp(2)
//                     2 RECT  u16 x, u16 y, u16 w, u16 h, u32 len, [len байт deflate XRGB1555 LE]
//   клиент -> сервер: 20 ACK  (кадр отрисован; сервер держит в полёте не больше одного кадра)
//                     3 END   (кадр целиком передан)
//                     5 CURSOR i16 x, i16 y, u8 visible
//   клиент -> сервер: 10 MOUSE u16 x, u16 y, u8 action (0 move, 1 down, 2 up, 3 click, 4 right-click)
//                     11 SCROLL u16 x, u16 y, i16 dx, i16 dy
// Запуск: screenserve [--port 8082] [--display <id|0=самый маленький>] [--fps 20]
import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import Compression
import ApplicationServices

var port: UInt16 = 8082
var wantID: UInt32 = 0
var fps: Double = 20
var debugMouse = false
var virtualW = 1024, virtualH = 768   // 0 = не создавать свой дисплей, брать самый маленький существующий
var argi = 1
let argv = CommandLine.arguments
while argi < argv.count {
    switch argv[argi] {
    case "--port": port = UInt16(argv[argi + 1]) ?? port; argi += 2
    case "--display": wantID = UInt32(argv[argi + 1]) ?? 0; argi += 2
    case "--fps": fps = Double(argv[argi + 1]) ?? fps; argi += 2
    case "--debug-mouse": debugMouse = true; argi += 1
    case "--no-virtual": virtualW = 0; virtualH = 0; argi += 1
    case "--size":
        let parts = argv[argi + 1].split(separator: "x"); if parts.count == 2 { virtualW = Int(parts[0]) ?? 1024; virtualH = Int(parts[1]) ?? 768 }
        argi += 2
    default: argi += 1
    }
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Кадровый буфер

final class FrameStore {
    let lock = NSLock()
    let cond = NSCondition()
    var width = 0, height = 0
    var pixels = [UInt8]()          // BGRA, width*4*height
    var pending: [CGRect] = []      // грязные прямоугольники с момента последней отправки
    var generation = 0
    var cursor = CGPoint.zero
    var cursorVisible = true

    static let tile = 32

    /// Сравнивает новый кадр с предыдущим плитками 32x32 и возвращает изменившиеся области
    /// (плитки одного ряда склеиваются в полосы). Пустой массив = кадр не изменился.
    func diffTiles(new base: UnsafeRawPointer, bpr: Int, w: Int, h: Int) -> [CGRect] {
        let t = FrameStore.tile
        let cols = (w + t - 1) / t, rows = (h + t - 1) / t
        var rects: [CGRect] = []
        pixels.withUnsafeBytes { oldBuf in
            let old = oldBuf.baseAddress!
            for ty in 0..<rows {
                let y0 = ty * t, th = min(t, h - y0)
                var runStart = -1
                for tx in 0...cols {
                    var changed = false
                    if tx < cols {
                        let x0 = tx * t, tw = min(t, w - x0)
                        for y in y0..<(y0 + th) {
                            if memcmp(old + (y * w + x0) * 4, base + y * bpr + x0 * 4, tw * 4) != 0 { changed = true; break }
                        }
                    }
                    if changed && runStart < 0 { runStart = tx }
                    if !changed && runStart >= 0 {
                        let x0 = runStart * t
                        rects.append(CGRect(x: x0, y: y0, width: min(tx * t, w) - x0, height: th))
                        runStart = -1
                    }
                }
            }
        }
        return rects
    }

    func update(buffer: CVPixelBuffer, dirty: [CGRect]?) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        cond.lock()
        var changedRects: [CGRect]
        if w != width || h != height {
            width = w; height = h
            pixels = [UInt8](repeating: 0, count: w * 4 * h)
            changedRects = [CGRect(x: 0, y: 0, width: w, height: h)]
        } else {
            changedRects = diffTiles(new: UnsafeRawPointer(base), bpr: bpr, w: w, h: h)
        }
        if changedRects.isEmpty { cond.unlock(); return }   // ничего не изменилось — кадр пропускаем
        // копируем только изменившиеся полосы (остальное в pixels уже актуально)
        pixels.withUnsafeMutableBytes { dst in
            for r in changedRects {
                let x0 = Int(r.minX), rw = Int(r.width)
                for y in Int(r.minY)..<Int(r.maxY) {
                    memcpy(dst.baseAddress! + (y * w + x0) * 4, base + y * bpr + x0 * 4, rw * 4)
                }
            }
        }
        pending.append(contentsOf: changedRects)
        generation += 1
        cond.signal()
        cond.unlock()
    }

    /// Ждёт новые данные, возвращает копию кадра и объединённые прямоугольники.
    func take(after gen: Int, timeout: TimeInterval) -> (Int, [UInt8], [CGRect], Int, Int)? {
        cond.lock()
        defer { cond.unlock() }
        if generation == gen {
            if !cond.wait(until: Date().addingTimeInterval(timeout)) { return nil }
            if generation == gen { return nil }
        }
        let rects = mergeRects(pending, w: width, h: height)
        pending.removeAll()
        return (generation, pixels, rects, width, height)
    }
}

/// Грубое объединение: если грязных прямоугольников много или площадь большая — весь кадр.
func mergeRects(_ rects: [CGRect], w: Int, h: Int) -> [CGRect] {
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    var out: [CGRect] = []
    var area = 0
    for r in rects {
        let c = r.integral.intersection(full)
        if c.isNull || c.isEmpty { continue }
        area += Int(c.width * c.height)
        // сливаем с пересекающимися/близкими
        var merged = false
        for i in 0..<out.count where out[i].insetBy(dx: -8, dy: -8).intersects(c) {
            out[i] = out[i].union(c); merged = true; break
        }
        if !merged { out.append(c) }
    }
    if out.count > 40 || area > w * h * 7 / 10 { return [full] }
    return out
}

// MARK: - Сжатие

func deflate(_ src: UnsafeRawBufferPointer) -> [UInt8] {
    var dst = [UInt8](repeating: 0, count: src.count + 1024)
    let n = dst.withUnsafeMutableBytes { d -> Int in
        compression_encode_buffer(d.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count,
                                  src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                                  nil, COMPRESSION_ZLIB)
    }
    if n == 0 { return [] }
    dst.removeSubrange(n...)
    return dst
}

// MARK: - Сеть

let store = FrameStore()
var displayID: CGDirectDisplayID = 0
/// Положение дисплея перечитываем каждый раз: пользователь может двигать его в настройках.
var displayOrigin: CGPoint { CGDisplayBounds(displayID).origin }
var displaySize: CGSize { CGDisplayBounds(displayID).size }

func putU16(_ b: inout [UInt8], _ v: Int) { b.append(UInt8(v & 0xff)); b.append(UInt8((v >> 8) & 0xff)) }
func putU32(_ b: inout [UInt8], _ v: Int) { for i in 0..<4 { b.append(UInt8((v >> (8 * i)) & 0xff)) } }

func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { p in write(fd, p.baseAddress! + off, bytes.count - off) }
        if n <= 0 { return false }
        off += n
    }
    return true
}

func serveClient(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    var hello = [UInt8](repeating: 0, count: 4)
    guard read(fd, &hello, 4) == 4, String(bytes: hello, encoding: .ascii) == "MSC1" else {
        log("[net] плохое приветствие"); close(fd); return
    }
    let ackSem = DispatchSemaphore(value: 0)
    var stat = (frames: 0, bytes: 0, rects: 0, t: Date())
    // читатель событий от клиента
    let reader = Thread {
        var buf = [UInt8](repeating: 0, count: 16)
        while true {
            guard read(fd, &buf, 1) == 1 else { break }
            switch buf[0] {
            case 10:
                guard read(fd, &buf, 5) == 5 else { return }
                let x = Int(buf[0]) | Int(buf[1]) << 8, y = Int(buf[2]) | Int(buf[3]) << 8
                Input.mouse(x: x, y: y, action: buf[4])
            case 20:
                ackSem.signal()
            case 11:
                guard read(fd, &buf, 8) == 8 else { return }
                let dx = Int(Int16(bitPattern: UInt16(buf[4]) | UInt16(buf[5]) << 8))
                let dy = Int(Int16(bitPattern: UInt16(buf[6]) | UInt16(buf[7]) << 8))
                Input.scroll(dx: dx, dy: dy)
            default: break
            }
        }
    }
    reader.start()

    var gen = -1
    var sentInfo = false
    var lastCursor = CGPoint(x: -1, y: -1)
    var full = true
    while true {
        if let (g, px, rects0, w, h) = store.take(after: gen, timeout: 0.05) {
            gen = g
            var out = [UInt8]()
            if !sentInfo || full {
                out.append(1); putU16(&out, w); putU16(&out, h); out.append(2); sentInfo = true
            }
            let rects = full ? [CGRect(x: 0, y: 0, width: w, height: h)] : rects0
            full = false
            for r in rects {
                let x = Int(r.minX), y = Int(r.minY), rw = Int(r.width), rh = Int(r.height)
                if rw <= 0 || rh <= 0 { continue }
                var raw = [UInt8](repeating: 0, count: rw * 2 * rh)
                px.withUnsafeBytes { src in
                    raw.withUnsafeMutableBytes { dst in
                        let s8 = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        let d16 = dst.baseAddress!.assumingMemoryBound(to: UInt16.self)
                        for row in 0..<rh {
                            var si = ((y + row) * w + x) * 4
                            var di = row * rw
                            for _ in 0..<rw {
                                let b = UInt16(s8[si]) >> 3, g = UInt16(s8[si + 1]) >> 3, r = UInt16(s8[si + 2]) >> 3
                                d16[di] = (r << 10) | (g << 5) | b
                                si += 4; di += 1
                            }
                        }
                    }
                }
                let comp = raw.withUnsafeBytes { deflate($0) }
                if comp.isEmpty { continue }
                out.append(2); putU16(&out, x); putU16(&out, y); putU16(&out, rw); putU16(&out, rh); putU32(&out, comp.count)
                out.append(contentsOf: comp)
            }
            out.append(3)
            if !sendAll(fd, out) { break }
            stat.frames += 1; stat.bytes += out.count; stat.rects += rects.count
            if Date().timeIntervalSince(stat.t) >= 10 {
                let dt = Date().timeIntervalSince(stat.t)
                log(String(format: "[net] %.1f кадров/с, %.0f КБ/с, %.1f прямоугольников/кадр, мышь %.0f,%.0f видна=%d",
                           Double(stat.frames) / dt, Double(stat.bytes) / dt / 1024, Double(stat.rects) / Double(max(1, stat.frames)),
                           lastCursor.x, lastCursor.y, lastCursor.x >= 0 ? 1 : 0))
                stat = (0, 0, 0, Date())
            }
            // ждём, пока клиент отрисует кадр (не больше одного кадра в полёте)
            if ackSem.wait(timeout: .now() + 3) == .timedOut { log("[net] клиент не подтвердил кадр за 3 с") }
        }
        // курсор: положение мыши относительно нашего дисплея
        let m = Input.mouseLocation()
        if Int(Date().timeIntervalSince1970 * 10) % 20 == 0 && debugMouse { log("[mouse] \(Int(m.x)),\(Int(m.y)) origin \(Int(displayOrigin.x)),\(Int(displayOrigin.y))") }
        let cx = m.x - displayOrigin.x, cy = m.y - displayOrigin.y
        let visible = cx >= 0 && cy >= 0 && cx < displaySize.width && cy < displaySize.height
        let cp = visible ? CGPoint(x: cx, y: cy) : CGPoint(x: -1, y: -1)
        if cp != lastCursor {
            lastCursor = cp
            var out: [UInt8] = [5]
            let ix = Int(cp.x), iy = Int(cp.y)
            out.append(UInt8(ix & 0xff)); out.append(UInt8((ix >> 8) & 0xff))
            out.append(UInt8(iy & 0xff)); out.append(UInt8((iy >> 8) & 0xff))
            out.append(visible ? 1 : 0)
            if !sendAll(fd, out) { break }
        }
    }
    log("[net] клиент отключился")
    close(fd)
}

// MARK: - Ввод (мышь на дисплее)

enum Input {
    static var buttonDown = false
    static func mouseLocation() -> CGPoint {
        // CGEvent даёт координаты в глобальной системе CoreGraphics (y вниз от верха главного дисплея)
        return CGEvent(source: nil)?.location ?? .zero
    }
    static func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.post(tap: .cghidEventTap)
    }
    static func mouse(x: Int, y: Int, action: UInt8) {
        let p = CGPoint(x: displayOrigin.x + CGFloat(x), y: displayOrigin.y + CGFloat(y))
        switch action {
        case 0: post(buttonDown ? .leftMouseDragged : .mouseMoved, p)
        case 1: buttonDown = true; post(.mouseMoved, p); post(.leftMouseDown, p)
        case 2: buttonDown = false; post(.leftMouseUp, p)
        case 3: post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p)
        case 4: post(.mouseMoved, p); post(.rightMouseDown, p, button: .right); post(.rightMouseUp, p, button: .right)
        default: break
        }
    }
    static func scroll(dx: Int, dy: Int) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - Захват

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var frames = 0
    var t0 = Date()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var dirty: [CGRect]? = nil
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let a = att.first {
            if let st = a[.status] as? Int, st != SCFrameStatus.complete.rawValue { return }
            if let dr = a[.dirtyRects] as? [Any] {
                dirty = dr.compactMap { ($0 as? NSValue)?.rectValue }
            }
        }
        store.update(buffer: pb, dirty: dirty)
        frames += 1
        if Date().timeIntervalSince(t0) >= 30 {
            log("[cap] \(Double(frames) / Date().timeIntervalSince(t0)) кадров/с от захвата")
            frames = 0; t0 = Date()
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("[cap] захват остановлен: \(error.localizedDescription)"); exit(2)
    }
}

let capture = Capture()
var keepStream: SCStream?


Task {
    // Без разрешения Screen Recording виртуальный монитор не создаём: иначе окно настроек может
    // открыться на нём, а увидеть его негде. macOS кеширует решение на время жизни процесса, поэтому
    // ждать внутри процесса бесполезно: спрашиваем один раз (маркер-файл), выходим через 30 с,
    // launchd перезапускает нас, и новый процесс уже видит включённый переключатель.
    if !CGPreflightScreenCaptureAccess() {
        let marker = NSHomeDirectory() + "/Library/Application Support/ScreenServe/prompted"
        if !FileManager.default.fileExists(atPath: marker) {
            try? FileManager.default.createDirectory(atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker, contents: nil)
            log("[cap] нет разрешения Screen Recording, запрашиваю у системы")
            _ = CGRequestScreenCaptureAccess()
        } else {
            log("[cap] нет разрешения Screen Recording: включите ScreenServe в System Settings → Privacy & Security → Screen & System Audio Recording; повторю через 30 с")
        }
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        exit(1)
    }
    if !AXIsProcessTrusted() {
        log("[input] нет разрешения Accessibility: клики с планшета работать не будут, пока не включить ScreenServe в System Settings → Privacy & Security → Accessibility и не перезапустить")
    }
    if virtualW > 0 {
        let vid = VDCreate(Int32(virtualW), Int32(virtualH), 60, 0, "iPad Screen")
        if vid == 0 {
            log("[vd] не удалось создать виртуальный дисплей, ищу существующий")
        } else {
            wantID = vid
            log("[vd] виртуальный дисплей \(vid) \(virtualW)x\(virtualH) создан")
            // даём системе секунду-две, чтобы дисплей появился в списке захвата
            var tries = 0
            while CGDisplayBounds(vid).isEmpty && tries < 40 { usleep(50_000); tries += 1 }
        }
    }
    do {
        var display: SCDisplay? = nil
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = wantID != 0
                ? content.displays.first { $0.displayID == wantID }
                : content.displays.min { $0.width * $0.height < $1.width * $1.height }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let d = display else { log("[cap] дисплей не найден"); exit(1) }
        displayID = d.displayID
        let bounds = CGDisplayBounds(d.displayID)
        let cfg = SCStreamConfiguration()
        cfg.width = d.width; cfg.height = d.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = false          // курсор рисует клиент
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 4
        let stream = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: capture)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await stream.startCapture()
        keepStream = stream
        log("[cap] дисплей \(d.displayID) \(d.width)x\(d.height) origin=\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) @\(fps)")
    } catch {
        // Чаще всего это отсутствие разрешения Screen Recording. Не выходим и не даём launchd
        // перезапускать нас в цикле (каждый перезапуск = новый системный запрос), а ждём и пробуем снова.
        log("[cap] ошибка: \(error.localizedDescription). Повтор через 60 с; выдайте screenserve разрешение в System Settings → Privacy & Security → Screen & System Audio Recording")
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        exit(1)
    }
}

// TCP-сервер
let sock = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = INADDR_ANY
let bindRes = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard bindRes == 0, listen(sock, 4) == 0 else { log("[net] не могу слушать порт \(port)"); exit(1) }
signal(SIGPIPE, SIG_IGN)
signal(SIGINT) { _ in VDDestroy(); exit(0) }
signal(SIGTERM) { _ in VDDestroy(); exit(0) }
atexit { VDDestroy() }
log("[net] слушаю tcp/\(port)")
while true {
    let fd = accept(sock, nil, nil)
    if fd < 0 { continue }
    log("[net] клиент подключился")
    Thread { serveClient(fd) }.start()
}
