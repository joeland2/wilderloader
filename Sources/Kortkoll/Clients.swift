import Foundation

// MARK: Kund eller projekt
// Man skriver kunden på kortet. Varje kopiering sparar kunden i kortets historik, så nästa gång
// kan appen visa var den kunden har hamnat förut. Mappar på diskarna med kundens namn räknas också.

/// En tidigare kopiering för en kund: kunden, mappen och när.
struct ClientPlace: Equatable {
    let client: String
    let place: String
    let date: Date
}

/// En föreslagen mapp på en disk. `cards` är 0 för en mapp som bara hittades på namnet.
struct ClientHit: Equatable {
    let url: URL
    var last: Date?
    var cards = 0
}

func sameText(_ a: String, contains b: String) -> Bool {
    a.range(of: b, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Alla kopieringar med en kund, från alla kortens historik.
func loadClientPlaces(dir: URL = dataDir().appendingPathComponent("cards")) -> [ClientPlace] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "jsonl" }.flatMap { f in
        loadHistory(f).flatMap { e -> [ClientPlace] in
            guard e.kind == .copy, let c = e.client, !c.isEmpty else { return [] }
            return e.places.map { ClientPlace(client: c, place: $0, date: e.date) }
        }
    }
}

/// De senast använda kunderna, nyast först.
func recentClients(_ places: [ClientPlace], max: Int = 3) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for p in places.sorted(by: { $0.date > $1.date }) where seen.insert(p.client.lowercased()).inserted {
        out.append(p.client)
        if out.count == max { break }
    }
    return out
}

/// Mapparna i en disks lista, som vägar från roten. Listan har bara mediafiler, så tomma mappar syns inte.
func indexedFolders(_ d: Disk) -> [String] {
    guard let text = try? String(contentsOf: indexURL(d), encoding: .utf8) else { return [] }
    var dirs = Set<Substring>()
    for line in text.split(separator: "\n").dropFirst() {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let rel = line[line.index(after: tab)...]
        if let slash = rel.lastIndex(of: "/") { dirs.insert(rel[..<slash]) }
    }
    return dirs.map(String.init)
}

/// Mappar vars namn innehåller texten. Bara den översta mappen med namnet räknas, inte allt under den.
func folderHits(_ q: String, folders: [String]) -> [String] {
    var out = Set<String>()
    for f in folders {
        let parts = f.split(separator: "/")
        if let k = parts.firstIndex(where: { sameText(String($0), contains: q) }) {
            out.insert(parts[...k].joined(separator: "/"))
        }
    }
    return out.sorted { ($0.split(separator: "/").count, $0.count, $0) < ($1.split(separator: "/").count, $1.count, $1) }
}

/// Förslagen för en kund på en disk: först där kunden har kopierats förut, nyast först, sedan mappar med namnet.
func clientHits(_ q: String, root: URL, places: [ClientPlace], folders: [String], max: Int = 3) -> [ClientHit] {
    let q = q.trimmingCharacters(in: .whitespaces)
    guard q.count >= 2 else { return [] }
    let base = dirURL(root).path
    var byPlace: [String: ClientHit] = [:]
    for p in places where sameText(p.client, contains: q) && inside(p.place, base) {
        var h = byPlace[p.place] ?? ClientHit(url: dirURL(URL(fileURLWithPath: p.place)))
        h.cards += 1
        h.last = Swift.max(h.last ?? .distantPast, p.date)
        byPlace[p.place] = h
    }
    var out = byPlace.values.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    for f in folderHits(q, folders: folders) where out.count < max {
        let u = dirURL(URL(fileURLWithPath: base).appendingPathComponent(f))
        if !out.contains(where: { $0.url.path == u.path }) { out.append(ClientHit(url: u)) }
    }
    return Array(out.prefix(max))
}

/// En ny kund: mappen där andra kunder brukar ligga på disken, så att den nya hamnar bredvid dem.
func clientsHome(root: URL, places: [ClientPlace]) -> URL? {
    let base = dirURL(root).path
    var count: [String: Int] = [:]
    for p in places where inside(p.place, base) && p.place != base {
        count[URL(fileURLWithPath: p.place).deletingLastPathComponent().standardizedFileURL.path, default: 0] += 1
    }
    return count.max { $0.value < $1.value }.map { dirURL(URL(fileURLWithPath: $0.key)) }
}

func testClients() {
    let d = { (s: Double) in Date(timeIntervalSince1970: s) }
    let places = [
        ClientPlace(client: "Nordljus", place: "/Volumes/NAS/Kunder/Nordljus", date: d(100)),
        ClientPlace(client: "Nordljus", place: "/Volumes/NAS/Kunder/Nordljus", date: d(300)),
        ClientPlace(client: "nordljus event", place: "/Volumes/NAS/Kunder/Nordljus/Event", date: d(200)),
        ClientPlace(client: "Kafé Linné", place: "/Volumes/NAS/Kunder/Kafé Linné", date: d(400)),
        ClientPlace(client: "Nordljus", place: "/Volumes/SSD/Backup", date: d(50)),
    ]
    assert(recentClients(places) == ["Kafé Linné", "Nordljus", "nordljus event"], "\(recentClients(places))")
    let folders = ["Arkiv/2025/Nordljus Film/RAW", "Arkiv/2025/Nordljus Film/RAW/A", "Kunder/Nordljus/Event", "Annat"]
    assert(folderHits("NORDLJUS", folders: folders) == ["Kunder/Nordljus", "Arkiv/2025/Nordljus Film"], "\(folderHits("NORDLJUS", folders: folders))")
    assert(folderHits("kafe", folders: ["Kunder/Kafé Linné/x"]) == ["Kunder/Kafé Linné"], "accenter ska inte spela roll")
    let hits = clientHits("nordljus", root: URL(fileURLWithPath: "/Volumes/NAS"), places: places, folders: folders)
    assert(hits.map(\.url.path) == ["/Volumes/NAS/Kunder/Nordljus", "/Volumes/NAS/Kunder/Nordljus/Event", "/Volumes/NAS/Arkiv/2025/Nordljus Film"], "\(hits.map(\.url.path))")
    assert(hits[0].cards == 2 && hits[0].last == d(300) && hits[2].cards == 0)
    assert(clientHits("n", root: URL(fileURLWithPath: "/Volumes/NAS"), places: places, folders: folders).isEmpty, "en bokstav ger inga förslag")
    assert(clientsHome(root: URL(fileURLWithPath: "/Volumes/NAS"), places: places)?.path == "/Volumes/NAS/Kunder")
    assert(clientsHome(root: URL(fileURLWithPath: "/Volumes/Tom"), places: places) == nil)
}
