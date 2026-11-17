import Foundation

// MARK: Kortets historik
// En fil per kort med vad som hänt med det: kopieringar och formateringar, en JSON-rad per händelse.
// Kortet känns igen på volymens id. shortcut: formaterar kameran om kortet får det ett nytt id och en ny historik;
// appens egen formatering för över historiken till det nya id:t.

struct CardEvent: Codable, Equatable {
    enum Kind: String, Codable { case copy, format }
    var date = Date()
    var kind: Kind
    /// Filer som kopierades och kontrollerades, och hur mycket.
    var files = 0
    var bytes: Int64 = 0
    /// Mapparna det kopierades till.
    var places: [String] = []
    var failed = 0
    /// Rapporterna som sparades bredvid kopian.
    var reports: [String]? = nil
    /// Kunden eller projektet som skrevs på kortet.
    var client: String? = nil
}

/// Volymens id för ett kort, annars mappens sökväg (när en vanlig mapp kontrolleras).
func cardKey(_ root: URL) -> String {
    (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString).flatMap { id in
        (try? root.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true ? id : nil
    } ?? root.standardizedFileURL.path
}

func historyURL(_ key: String, dir: URL = dataDir().appendingPathComponent("cards")) -> URL {
    // Sökvägar blir filnamn utan snedstreck.
    dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jsonl")
}

func loadHistory(_ url: URL) -> [CardEvent] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let dec = JSONDecoder()
    return text.split(separator: "\n").compactMap { try? dec.decode(CardEvent.self, from: Data($0.utf8)) }
}

func appendHistory(_ e: CardEvent, to url: URL) {
    guard var line = try? JSONEncoder().encode(e) else { return }
    line.append(0x0A)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}

/// Efter appens formatering har kortet ett nytt id: historiken följer med dit.
func carryHistory(from old: URL, to new: URL) {
    guard old != new, let data = try? Data(contentsOf: old) else { return }
    try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: new, options: .atomic)
}

func testHistory() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("wl-history-\(UUID().uuidString)")
    defer { try? fm.trashItem(at: dir, resultingItemURL: nil) }
    let a = historyURL("/Volumes/A", dir: dir), b = historyURL("NEW-ID", dir: dir)
    assert(a.lastPathComponent == "_Volumes_A.jsonl", a.lastPathComponent)
    assert(loadHistory(a).isEmpty, "ny historik ska vara tom")
    let copy = CardEvent(date: Date(timeIntervalSince1970: 1_000), kind: .copy, files: 3, bytes: 30, places: ["/Volumes/NAS/Coast"], failed: 1)
    appendHistory(copy, to: a)
    appendHistory(CardEvent(date: Date(timeIntervalSince1970: 2_000), kind: .format), to: a)
    let h = loadHistory(a)
    assert(h.count == 2 && h[0] == copy && h[1].kind == .format, "\(h)")
    carryHistory(from: a, to: b)
    assert(loadHistory(b) == h, "historiken ska följa med till det nya id:t")
}
