#if DEBUG
import SwiftUI
import AppKit
import CoreText

// `Kortkoll --render-demo <mapp>` ritar appens riktiga vyer till bilder för webbsidan.
// Allt är påhittat, så att inga riktiga kund- eller mappnamn hamnar på en publik sida.
// Finns bara i debug-bygget och rör aldrig några riktiga diskar.

@MainActor
enum Demo {
    static let size = CGSize(width: 1180, height: 740)

    static func render(to out: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        appLang = .en
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/Fonts/BebasNeue-Regular.ttf") as CFURL, .process, nil)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Sista mappnamnet känner placeLabel igen och visar som /Volumes.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("stf-render-\(UUID().uuidString)/stf-demo")
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let fm = FileManager.default
        func tree(_ paths: [String]) { for p in paths { try? fm.createDirectory(at: base.appendingPathComponent(p), withIntermediateDirectories: true) } }
        tree(["LUMIX/DCIM/100_PANA",
              "Wildermark NAS/2026/Coast Film/01_RAW/Cam A", "Wildermark NAS/2026/Coast Film/01_RAW/Cam B",
              "Wildermark NAS/2026/Coast Film/02_AUDIO", "Wildermark NAS/2026/Coast Film/03_EDIT",
              "Wildermark NAS/2026/Ridge Wedding/RAW", "Wildermark NAS/2026/Studio Portraits/RAW",
              "Wildermark NAS/2025/Harbor Spot", "Wildermark NAS/Archive", "Wildermark NAS/LUTs", "Wildermark NAS/Music",
              "Backup SSD/Projects/Coast Film/01_RAW", "Backup SSD/Projects/Coast Film/02_SELECTS",
              "Backup SSD/Projects/Harbor Spot/RAW", "Backup SSD/Projects/Studio Portraits", "Backup SSD/Exports", "Backup SSD/Temp",
              "MM 2/Footage/2025", "MM 2/Footage/2024", "MM 2/Sound"])

        let card = dirURL(base.appendingPathComponent("LUMIX"))
        let nas = Disk(key: "nas", name: "Wildermark NAS", root: base.appendingPathComponent("Wildermark NAS"), network: true)
        let ssd = Disk(key: "ssd", name: "Backup SSD", root: base.appendingPathComponent("Backup SSD"))
        let mm2 = Disk(key: "mm2", name: "MM 2", root: base.appendingPathComponent("MM 2"))
        let coast = dirURL(ssd.root.appendingPathComponent("Projects/Coast Film/01_RAW"))
        let camA = dirURL(nas.root.appendingPathComponent("2026/Coast Film/01_RAW/Cam A"))

        struct Plan { let n: Int; let day: Int; let from: Double; let to: Double; let homes: [URL] }
        let plans = [
            Plan(n: 300, day: 12, from: 9.2, to: 11.8, homes: [camA]),
            Plan(n: 176, day: 12, from: 15.3, to: 17.7, homes: [dirURL(nas.root.appendingPathComponent("2026/Coast Film/01_RAW/Cam B"))]),
            Plan(n: 112, day: 13, from: 10, to: 13, homes: [dirURL(nas.root.appendingPathComponent("2026/Studio Portraits/RAW")),
                                                            dirURL(ssd.root.appendingPathComponent("Projects/Studio Portraits"))]),
            Plan(n: 652, day: 14, from: 8, to: 17, homes: []),
        ]

        let m = Model(demo: true)
        m.card = card
        var all: [(file: CardFile, homes: [URL])] = []
        var groups: [[Int]] = []
        for (g, p) in plans.enumerated() {
            let start = all.count
            for i in 0..<p.n {
                let hour = p.from + (p.to - p.from) * Double(i) / Double(max(p.n - 1, 1))
                let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: p.day, hour: Int(hour), minute: Int(hour * 60) % 60))!
                let video = i % 12 == 11
                let name = String(format: "P%07d.%@", 1000 + all.count, video ? "MOV" : "JPG")
                let url = card.appendingPathComponent("DCIM/100_PANA/\(name)")
                let f = CardFile(url: url, rel: "DCIM/100_PANA/\(name)", size: video ? 1_380_000_000 : 24_500_000, date: date)
                if i == p.n / 2 { try? picture(g).write(to: url) }
                all.append((f, p.homes.map { $0.appendingPathComponent(name) }))
            }
            groups.append(Array(start..<all.count))
        }
        func foundItem(_ a: (file: CardFile, homes: [URL])) -> Item {
            var it = Item(file: a.file, status: a.homes.first.map { .found($0) } ?? .missing)
            it.copies = a.homes
            it.verified = true
            return it
        }

        m.disks = [DiskRow(disk: nas, count: 48_210, date: Date(), fill: 0.64),
                   DiskRow(disk: ssd, count: 9_874, date: Date(), fill: 0.41),
                   DiskRow(disk: mm2, count: 3_120, date: Date(), fill: 0.78)]
        // Fotograferingarna pekar in i items, så filerna måste finnas först.
        m.items = all.map(foundItem)
        m.shoots = groups

        let shot = Shooter(out: out)
        let main = NSHostingView(rootView: AnyView(ContentView().environmentObject(m).preferredColorScheme(.dark).frame(width: size.width, height: size.height)))
        let window = shot.window(main, size)

        // Fotograferingsrutorna ska tåla att filerna försvinner medan de ritas. Det kraschade appen förut.
        shot.spin(0.4)
        let stale = m.items
        m.items = []
        shot.spin(0.4)
        m.items = stale
        print("stale shoots ok")

        // 1. Letar: hälften av filerna är kollade.
        m.busy = true
        m.items = all.enumerated().map { i, a in i < 744 ? foundItem(a) : Item(file: a.file) }
        m.checked = 744
        shot.save(main, "looking", settle: 1.5)

        // 2. Klart: 652 filer saknas.
        m.busy = false
        m.items = all.map(foundItem)
        m.checked = all.count
        shot.save(main, "missing", settle: 1)
        print("flow frame size", main.bounds.size)

        // 3. Väljaren när filerna ska kopieras.
        let missing = m.missing.map(\.file)
        shot.sheet(AnyView(LandingSheet(files: missing, disk: ssd, start: coast, anyStatus: true).environmentObject(m).preferredColorScheme(.dark)), "sheet-copy")
        // 4. Väljaren när filerna redan finns: gröna mappar.
        shot.sheet(AnyView(LandingSheet(files: groups[0].map { all[$0].file }, disk: nas, start: camA, extra: true, anyStatus: true).environmentObject(m).preferredColorScheme(.dark)), "sheet-already")

        // Två diskar samtidigt, med filmmallen.
        let savedTemplate = UserDefaults.standard.object(forKey: "folderTemplate"), savedProject = UserDefaults.standard.object(forKey: "folderProject"), savedCamera = UserDefaults.standard.object(forKey: "folderCamera")
        UserDefaults.standard.set(filmTemplate, forKey: "folderTemplate")
        UserDefaults.standard.set("Coast Film", forKey: "folderProject")
        UserDefaults.standard.set("Cam A", forKey: "folderCamera")
        shot.sheet(AnyView(LandingSheet(files: missing, disk: ssd, start: coast, second: nas, secondFolder: dirURL(nas.root)).environmentObject(m).preferredColorScheme(.dark)), "sheet-two-disks")
        for (k, v) in [("folderTemplate", savedTemplate), ("folderProject", savedProject), ("folderCamera", savedCamera)] { UserDefaults.standard.set(v, forKey: k) }

        // 5. Kopierar: en bildruta var 8:e sekund, med riktig tid så att miniatyrerna rör sig längs linjen.
        let target = coast.appendingPathComponent("2026-10-14")
        let todo = m.items.indices.filter { m.items[$0].status == .missing }
        m.thumbs = (0..<6).compactMap { NSImage(data: picture($0)) }
        m.busy = true
        m.copyingTo = target
        m.copyTotal = todo.count
        m.bytesTotal = todo.reduce(0) { $0 + m.items[$1].file.size }
        m.progressStart = Date().addingTimeInterval(-90)
        let frames = 28
        var done = 0, doneBytes: Int64 = 0
        for f in 0..<frames {
            let until = Int(Double(todo.count) * Double(f) / Double(frames - 1) * 0.97)
            while done < until {
                let i = todo[done]
                m.items[i].status = .copied(target.appendingPathComponent(m.items[i].file.url.lastPathComponent))
                doneBytes += m.items[i].file.size
                done += 1
            }
            m.copyDone = done
            m.bytesDone = doneBytes
            m.checkBytes = doneBytes
            shot.save(main, String(format: "copy-%02d", f), settle: 0.125, jpeg: true)
        }

        // 6. Allt finns: säkert att formatera.
        for i in todo { m.items[i].status = .copied(target.appendingPathComponent(m.items[i].file.url.lastPathComponent)) }
        m.copyingTo = nil
        m.busy = false
        m.bytesTotal = 0
        m.thumbs = []
        shot.save(main, "safe", settle: 1)

        shot.sheet(AnyView(FormatSheet().environmentObject(m).preferredColorScheme(.dark)), "sheet-format")

        // Allt finns, men en del bara i listan för en urkopplad disk och en del bara efter snabbkollen. Formatering ska då inte erbjudas utan varning.
        assert(m.formatReady && m.unverified == 0, "kontrollerade filer ska kunna formateras")
        let checkedItems = m.items
        for i in groups[0] { m.items[i].status = .listed(all[i].homes[0]); m.items[i].verified = false }
        for i in groups[1] { m.items[i].verified = false }
        assert(m.allSafe && !m.formatReady, "okontrollerade filer ska inte räknas som klara")
        assert(m.awayOnly == groups[0].count && m.unverified == groups[0].count + groups[1].count, "\(m.awayOnly) \(m.unverified)")
        assert(m.tiles.first { $0.id == "nas" }?.listed == groups[0].count, "linjen ska veta vad som bara finns i listan")
        m.leftovers = [nas.root.appendingPathComponent("2026/A001.MOV.1a2b3c4d.wilderloader-part")]
        shot.save(main, "unverified", settle: 1)
        shot.sheet(AnyView(FormatSheet().environmentObject(m).preferredColorScheme(.dark)), "sheet-format-unverified")
        m.leftovers = []
        m.items = checkedItems

        // Filer appen inte kan kontrollera får aldrig raderas i tysthet, även om allt annat är klart.
        assert(m.formatReady, "allt kontrollerat")
        m.otherFiles = [card.appendingPathComponent("A001.XYZ"), card.appendingPathComponent("A002.XYZ")]
        m.minorFiles = 12
        assert(!m.formatReady, "okända filer ska spärra")
        shot.save(main, "other-files", settle: 1)
        // Skanning: NAS:en mäts mot förra listan, MM 2 skannas för första gången.
        let rows = m.disks
        m.disks[0].progress = 19_000; m.disks[0].scanStart = Date().addingTimeInterval(-60)
        m.disks[2].count = nil; m.disks[2].date = nil; m.disks[2].progress = 1_500; m.disks[2].scanStart = Date()
        shot.save(main, "scanning", settle: 1)
        m.disks = rows
        shot.sheet(AnyView(FormatSheet().environmentObject(m).preferredColorScheme(.dark)), "sheet-format-other")
        m.otherFiles = []
        m.minorFiles = 0

        // Kartan från pluppen. Saknade filer ingår inte, och en fotografering kan ligga i flera mappar.
        let map = m.diskMap(nas.root)
        assert(map.fileCount == m.items.filter { $0.copies.contains { $0.path.hasPrefix(nas.root.path + "/") } }.count, "kartan ska räkna filerna på disken")
        assert(map.folders.count == Set(map.links.map(\.folder)).count && !map.folders.isEmpty, "varje mapp ska finnas en gång")
        assert(m.diskMap(mm2.root).links.isEmpty, "en disk utan kortets filer ska ge en tom karta")
        shot.sheet(AnyView(DiskMapSheet(disk: nas) {}.environmentObject(m).preferredColorScheme(.dark)), "sheet-map")
        window.orderOut(nil)
    }

    /// Påhittade bilder till miniatyrerna, ritade här så att inga riktiga foton används.
    static func picture(_ seed: Int) -> Data {
        let w = 960, h = 640
        let looks: [([CGFloat], [CGFloat], [CGFloat])] = [
            ([0.98, 0.62, 0.30], [0.25, 0.20, 0.34], [0.07, 0.09, 0.14]),
            ([0.95, 0.42, 0.34], [0.20, 0.14, 0.30], [0.05, 0.05, 0.10]),
            ([0.72, 0.80, 0.86], [0.36, 0.48, 0.60], [0.10, 0.16, 0.22]),
            ([0.60, 0.74, 0.62], [0.18, 0.32, 0.28], [0.04, 0.10, 0.08]),
            ([0.90, 0.78, 0.55], [0.46, 0.35, 0.28], [0.12, 0.09, 0.08]),
            ([0.55, 0.66, 0.90], [0.22, 0.26, 0.48], [0.06, 0.07, 0.15]),
        ]
        let (top, mid, low) = looks[seed % looks.count]
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorSpace: cs, colorComponents: mid + [1] + top + [1], locations: [0, 1], count: 2)!
        c.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: CGFloat(h) * 0.35), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        c.setFillColor(red: 1, green: 0.96, blue: 0.85, alpha: 0.9)
        let sx = CGFloat(180 + seed * 137 % 600)
        c.fillEllipse(in: CGRect(x: sx, y: 330, width: 74, height: 74))
        for layer in 0..<4 {
            let t = CGFloat(layer) / 3
            let color = (0..<3).map { mid[$0] * (1 - t) + low[$0] * t }
            c.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
            let base = 340 - CGFloat(layer) * 85
            let f = CGFloat(seed + 2)
            let path = CGMutablePath()
            path.move(to: .zero)
            for x in stride(from: 0, through: w, by: 6) {
                let v = CGFloat(x) / 96
                let y = base + 52 * sin(v * (0.7 + t * 0.4) + f + CGFloat(layer) * 2.1) + 24 * sin(v * 2.3 + f * 1.7) + 9 * sin(v * 6.1 + f)
                path.addLine(to: CGPoint(x: CGFloat(x), y: y))
            }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            c.addPath(path)
            c.fillPath()
        }
        return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    }
}

/// Fönster utanför skärmen, som ritas till filer i dubbel upplösning.
@MainActor
final class Shooter {
    let out: URL
    private var keep: [NSWindow] = []
    init(out: URL) { self.out = out }

    func window(_ view: NSView, _ size: CGSize) -> NSWindow {
        let w = TwoXWindow(contentRect: CGRect(origin: CGPoint(x: -8000, y: -8000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.orderBack(nil)
        keep.append(w)
        return w
    }

    func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func save(_ v: NSView, _ name: String, settle: TimeInterval, jpeg: Bool = false) {
        spin(settle)
        v.layoutSubtreeIfNeeded()
        let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])! : rep.representation(using: .png, properties: [:])!
        try? data.write(to: out.appendingPathComponent(name + (jpeg ? ".jpg" : ".png")))
    }

    func sheet(_ view: AnyView, _ name: String) {
        let host = NSHostingView(rootView: view)
        let w = window(host, host.fittingSize)
        spin(0.3)
        w.setContentSize(host.fittingSize)
        save(host, name, settle: 1)
        print(name, host.bounds.size)
        w.orderOut(nil)
    }
}

/// Fönstret ritar i dubbel upplösning även på en skärm som inte är retina.
private final class TwoXWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}
#endif
