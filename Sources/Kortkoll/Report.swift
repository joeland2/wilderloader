import Foundation

// MARK: Rapport
// En HTML-fil som sparas bredvid kopian: först en översikt, sedan varje fil med storlek, xxHash-64 och vart den gick.
// Mörk på skärmen som appen, ljus när den skrivs ut. Går att skicka till en kund eller produktion.

struct ReportFile {
    let rel: String
    let size: Int64
    /// Kortfilens xxHash-64. Saknas om filen redan fanns på platsen och inte kopierades nu.
    let hash: UInt64?
    /// En rad per plats: true om kopian där är kontrollerad.
    let ok: [Bool]
}

func hex(_ h: UInt64) -> String { String(format: "%016llx", h) }

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// `thumbs`: JPEG-data för några miniatyrer.
func reportHTML(card: String, date: Date, places: [String], files: [ReportFile], thumbs: [Data] = [], version: String) -> String {
    let df = DateFormatter()
    df.locale = appLang.locale
    df.dateFormat = "d MMM yyyy HH:mm"
    let bytes = files.reduce(Int64(0)) { $0 + $1.size }
    let failed = files.filter { $0.ok.contains(false) }.count
    let gb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    let okAll = failed == 0
    let placeRows = places.enumerated().map { i, p in
        let good = files.allSatisfy { i < $0.ok.count && $0.ok[i] }
        return "<div class=\"dest \(good ? "ok" : "bad")\">\(esc(placeLabel(p, full: true)))\(good ? " ✓" : " !")</div>"
    }.joined()
    let thumbRow = thumbs.prefix(8).map { "<img src=\"data:image/jpeg;base64,\($0.base64EncodedString())\" alt=\"\">" }.joined()
    let rows = files.map { f in
        "<tr\(f.ok.contains(false) ? " class=\"bad\"" : "")><td>\(esc(f.rel))</td><td class=\"n\">\(gb(f.size))</td><td class=\"h\">\(f.hash.map(hex) ?? "—")</td><td>\(f.ok.map { $0 ? "✓" : "✗" }.joined(separator: " "))</td></tr>"
    }.joined(separator: "\n")
    return """
    <!doctype html>
    <html lang="\(appLang.rawValue)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(esc(card)) · \(esc(df.string(from: date)))</title>
    <style>
    body{margin:0;font:14px/1.5 -apple-system,Helvetica,Arial,sans-serif;background:#f6f5f2;color:#151515}
    .top{background:#0a0a0a;color:#fff;padding:32px 40px}
    h1{font:600 34px/1.1 "Bebas Neue",Impact,sans-serif;letter-spacing:.5px;margin:0}
    .sub{color:#9ca3af;margin-top:4px}
    .badge{float:right;border:1px solid;border-radius:4px;padding:4px 12px;font-weight:600}
    .ok{color:#22c55e}.bad{color:#ef4444}
    .stats{display:flex;gap:40px;margin:24px 0}
    .stats b{display:block;font-size:30px}.stats span{color:#9ca3af}
    .dest{display:inline-block;border:1px solid currentColor;border-radius:4px;padding:4px 10px;margin:0 8px 8px 0}
    .thumbs{display:flex;gap:6px;margin-top:16px}.thumbs img{height:64px;border-radius:2px}
    .list{padding:24px 40px}
    table{width:100%;border-collapse:collapse;font-size:12px}
    th{text-align:left;border-bottom:1px solid #151515;padding:4px 8px 4px 0}
    td{padding:3px 8px 3px 0;border-bottom:1px solid #e3e1dc}
    td.h{font-family:ui-monospace,Menlo,monospace}td.n{white-space:nowrap}
    tr.bad td{color:#b91c1c}
    footer{color:#777;font-size:11px;padding:0 40px 32px}
    @media print{body{background:#fff}.top{background:#fff;color:#151515;border-bottom:2px solid #151515}.sub,.stats span{color:#555}.ok{color:#15803d}}
    </style></head><body>
    <div class="top">
    <div class="badge \(okAll ? "ok" : "bad")">\(okAll ? L("✓ All checked", "✓ Allt kontrollerat") : L("\(failed) failed", "\(failed) misslyckades"))</div>
    <h1>\(esc(card))</h1>
    <div class="sub">\(L("Offload report", "Kopieringsrapport")) · \(esc(df.string(from: date)))</div>
    <div class="stats"><div><b>\(files.count)</b><span>\(L("files", "filer"))</span></div><div><b>\(gb(bytes))</b><span>\(L("copied", "kopierat"))</span></div><div><b>\(places.count)</b><span>\(L(places.count == 1 ? "destination" : "destinations", places.count == 1 ? "plats" : "platser"))</span></div><div><b>\(failed)</b><span>\(L("failed", "misslyckades"))</span></div></div>
    \(placeRows)
    <div class="thumbs">\(thumbRow)</div>
    </div>
    <div class="list"><table>
    <tr><th>\(L("File on the card", "Fil på kortet"))</th><th>\(L("Size", "Storlek"))</th><th>xxHash-64</th><th>\(places.indices.map { "\($0 + 1)" }.joined(separator: " "))</th></tr>
    \(rows)
    </table></div>
    <footer>\(L("Every copy was read back and compared with the card using xxHash-64.", "Varje kopia lästes tillbaka och jämfördes med kortet med xxHash-64.")) WilderLoader \(esc(version))</footer>
    </body></html>
    """
}

/// Sparar rapporten i varje mapp som finns. Skriver aldrig över en fil; finns namnet får det ett nummer.
@discardableResult
func writeReport(_ html: String, card: String, date: Date, to folders: [URL]) -> [URL] {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HHmm"
    let base = "WilderLoader report – \(card.replacingOccurrences(of: "/", with: "-")) – \(df.string(from: date))"
    let fm = FileManager.default
    return folders.compactMap { dir in
        var url = dir.appendingPathComponent(base + ".html")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base) \(n).html"); n += 1 }
        // withoutOverwriting: om filen hinner dyka upp emellan misslyckas skrivningen i stället.
        return (try? Data(html.utf8).write(to: url, options: .withoutOverwriting)) != nil ? url : nil
    }
}

func testReport() {
    let files = [ReportFile(rel: "DCIM/<a>.JPG", size: 10, hash: 0xabc, ok: [true, true]),
                 ReportFile(rel: "B.MOV", size: 20, hash: nil, ok: [true, false])]
    let html = reportHTML(card: "LUMIX", date: Date(), places: ["/Volumes/NAS/Coast", "/Volumes/SSD/Coast"], files: files, version: "test")
    assert(html.contains("DCIM/&lt;a&gt;.JPG") && !html.contains("<a>.JPG"), "filnamn ska escapas")
    assert(html.contains("0000000000000abc"), "hela kontrollsumman ska synas")
    assert(html.contains("tr class=\"bad\""), "misslyckad kopia ska markeras")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("wl-report-\(UUID().uuidString)")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.trashItem(at: dir, resultingItemURL: nil) }
    let d = Date()
    let a = writeReport(html, card: "LUMIX", date: d, to: [dir, dir.appendingPathComponent("missing")])
    let b = writeReport("second", card: "LUMIX", date: d, to: [dir])
    assert(a.count == 1 && b.count == 1 && a[0] != b[0], "en mapp som saknas hoppas över, och inget skrivs över")
    assert((try? String(contentsOf: a[0], encoding: .utf8)) == html, "första rapporten ska vara orörd")
}
