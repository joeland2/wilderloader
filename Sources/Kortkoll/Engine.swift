import Foundation
import CryptoKit
import UniformTypeIdentifiers

// Ren logik utan UI, så att den kan testas från terminalen (`Kortkoll --check <mapp>`).

struct CardFile {
    let url: URL
    let rel: String
    let size: Int64
    /// Senast ändrad på kortet, vilket för kamerafiler är inspelningstiden.
    let date: Date
}

/// "2026-11-02" i lokal tid, för datummapparna.
// MARK: Språk
// Engelska som grund, svenska som val. Datorns språk avgör vad som visas första gången; reglaget i appen sparar valet.

enum Lang: String, CaseIterable {
    case en, sv
    var locale: Locale { Locale(identifier: self == .sv ? "sv_SE" : "en_US") }
}

// shortcut: global som läses av vyerna; Model.language byter den och ritar om allt.
nonisolated(unsafe) var appLang: Lang = UserDefaults.standard.string(forKey: "language").flatMap(Lang.init)
    ?? (Locale.preferredLanguages.first?.hasPrefix("sv") == true ? .sv : .en)

/// Text i appens språk: engelska först, svenska sedan.
func L(_ en: String, _ sv: String) -> String { appLang == .sv ? sv : en }

let appName = "WilderLoader"

/// Listor, loggar och val sparas här, i ~/Library/Application Support/WilderLoader.
func dataDir() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
}

/// Appen hette Kortkoll och sedan Safe to Format: flytta listorna och inställningarna hit, en gång.
func migrateFromOldNames() {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    if !fm.fileExists(atPath: dataDir().path),
       let old = ["Safe to Format", "Kortkoll"].map({ support.appendingPathComponent($0) }).first(where: { fm.fileExists(atPath: $0.path) }) {
        try? fm.moveItem(at: old, to: dataDir())
    }
    let d = UserDefaults.standard
    if let id = Bundle.main.bundleIdentifier, d.persistentDomain(forName: id)?.isEmpty ?? true,
       let prev = ["com.wildermark.safetoformat", "com.wildermark.kortkoll"].lazy.compactMap({ d.persistentDomain(forName: $0) }).first {
        d.setPersistentDomain(prev, forName: id)
    }
}

// Delad, eftersom funktionen körs för varje fil på kortet och en ny formaterare är dyr.
private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

/// Filernas index i tidsordning, delade i fotograferingar: en ny dag eller en lucka på över tre timmar börjar en ny.
func shootGroups(_ dates: [Date], gap: TimeInterval = 3 * 3600) -> [[Int]] {
    var out: [[Int]] = []
    var last: Date?
    for i in dates.indices.sorted(by: { dates[$0] < dates[$1] }) {
        if let last, dates[i].timeIntervalSince(last) <= gap, Calendar.current.isDate(dates[i], inSameDayAs: last) { out[out.count - 1].append(i) }
        else { out.append([i]) }
        last = dates[i]
    }
    return out
}

/// Slår ihop intilliggande fotograferingar tills högst `n` återstår, så att alla filer alltid får plats på raden.
func fitShoots(_ groups: [[Int]], to n: Int) -> [[Int]] {
    guard n > 0, groups.count > n else { return groups }
    let size = (groups.count + n - 1) / n
    return stride(from: 0, to: groups.count, by: size).map { Array(groups[$0..<min($0 + size, groups.count)].joined()) }
}

/// Samma form på varje mapp-URL: annars skiljer ett avslutande snedstreck två adresser till samma mapp.
func dirURL(_ u: URL) -> URL { URL(fileURLWithPath: u.standardizedFileURL.path, isDirectory: true) }

/// Mappar som NAS och system skapar själva. Inget ska landa där.
private let systemFolders: Set<String> = ["#recycle", "#snapshot", "@eaDir", "$RECYCLE.BIN", "System Volume Information"]

/// Synliga undermappar, i Finders ordning. Program och andra paket räknas inte som mappar.
func subfolders(of dir: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
    let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    return all.filter { u in
        let v = try? u.resourceValues(forKeys: Set(keys))
        return v?.isDirectory == true && v?.isPackage != true && !systemFolders.contains(u.lastPathComponent)
    }
    .map(dirURL)
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// Monterade minneskort: flyttbara volymer med en DCIM-mapp.
func mountedCards() -> [URL] {
    let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
    let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return vols.filter { url in
        let v = try? url.resourceValues(forKeys: Set(keys))
        let removable = v?.volumeIsRemovable == true || v?.volumeIsEjectable == true
        return removable && FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
    }
}

func listFiles(_ root: URL) -> [CardFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    let base = root.standardizedFileURL.path
    var out: [CardFile] = []
    for case let url as URL in e {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, isMedia(url) else { continue }
        let path = url.standardizedFileURL.path
        let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
        out.append(CardFile(url: url, rel: rel, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? Date()))
    }
    return out.sorted { $0.rel < $1.rel }
}

/// Bilder, video och ljud. Kamerans egna databasfiler (t.ex. PRIVATE/…/CONTENTS.B00) räknas inte.
func isMedia(_ url: URL) -> Bool {
    guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
    return t.conforms(to: .image) || t.conforms(to: .audiovisualContent)
}

/// Slår upp filnamn i Spotlight, i omgångar. Returnerar namn -> sökvägar.
// shortcut: hittar bara kopior med samma filnamn på indexerade diskar; omdöpta kopior räknas som saknade (säkert håll: de kopieras igen).
func spotlight(names: Set<String>) -> [String: [URL]] {
    var out: [String: [URL]] = [:]
    let all = Array(names)
    for start in stride(from: 0, to: all.count, by: 150) {
        let query = all[start..<min(start + 150, all.count)]
            .map { "kMDItemFSName == \"\(mdEscape($0))\"" }
            .joined(separator: " || ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-0", query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { continue }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for path in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            let u = URL(fileURLWithPath: String(path))
            out[u.lastPathComponent, default: []].append(u)
        }
    }
    return out
}

/// Spotlight (färskt men täcker inte allt) + diskregistret (täcker allt, även NAS, men kan vara några timmar gammalt).
func candidates(of files: [CardFile]) -> [String: [URL]] {
    let names = Set(files.map { $0.url.lastPathComponent })
    // Spotlight behövs bara som snabbsvar för diskar som inte har en lista än; med många namn tar den tid.
    let needSpotlight = indexableDisks().contains { $0.spotlight && indexInfo($0) == nil }
    var out = needSpotlight ? spotlight(names: names) : [:]
    for (name, urls) in indexedCandidates(files) {
        for u in urls where !(out[name] ?? []).contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) {
            out[name, default: []].append(u)
        }
    }
    return out
}

// MARK: Diskregister
// En lista per disk över alla bilder och filmer, sparad i ~/Library/Application Support/Kortkoll.
// Format: första raden "# <antal>", sedan "<storlek>\t<sökväg från diskens rot>" per fil.

struct Disk {
    let key: String
    let name: String
    let root: URL
    /// Spotlight har ett index här, så filnamnen kan sökas direkt redan innan disken är skannad.
    /// Disken får ändå en egen lista, eftersom Spotlight kan ligga efter eller ha undantagna mappar.
    var spotlight = false
    /// Urkopplad: bara listan finns kvar. Filerna matchas på namn och storlek mot den, som för vilken disk som helst.
    var offline = false
    var network = false
}

/// Hemmappen plus alla inkopplade diskar och nätverksdiskar, utom minneskort.
func indexableDisks() -> [Disk] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Den inbyggda diskens Spotlight-index visade sig nästan tomt, så hemmappen får alltid en egen lista.
    var out = [Disk(key: "home", name: L("This Mac", "Den här Macen"), root: home)]
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey]
    let cards = Set(mountedCards().map(\.path))
    for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
        guard let rv = try? v.resourceValues(forKeys: Set(keys)), rv.volumeIsRootFileSystem != true, !cards.contains(v.path) else { continue }
        let name = rv.volumeName ?? v.lastPathComponent
        // NAS:er svarar inte på Spotlight-sökningar via nätverket, så de får alltid en lista.
        out.append(Disk(key: rv.volumeUUIDString ?? name, name: name, root: v, spotlight: rv.volumeIsLocal == true && spotlightIndexed(v),
                        network: rv.volumeIsLocal == false))
    }
    rememberDisks(out.filter { $0.key != "home" })
    return out
}

// MARK: Kända diskar
// Varje disk som har varit inkopplad sparas: "<nyckel>\t<namn>\t<sökväg>\t<nätverk 0/1>". Så kan en urkopplad
// disk visas och räknas med via sin lista, för den som bara har en port och byter diskar.

func knownDisksURL() -> URL {
    dataDir().appendingPathComponent("disks.txt")
}

private func readKnownDisks() -> [Disk] {
    ((try? String(contentsOf: knownDisksURL(), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4 else { return nil }
        return Disk(key: p[0], name: p[1], root: URL(fileURLWithPath: p[2]), offline: true, network: p[3] == "1")
    }
}

private func rememberDisks(_ mounted: [Disk]) {
    var all = Dictionary(readKnownDisks().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    for d in mounted { all[d.key] = d }
    let text = all.values.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.name)\t\($0.root.path)\t\($0.network ? 1 : 0)\n" }.joined()
    if text != (try? String(contentsOf: knownDisksURL(), encoding: .utf8)) {
        try? FileManager.default.createDirectory(at: knownDisksURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: knownDisksURL(), atomically: true, encoding: .utf8)
    }
}

/// Diskar som har en lista men inte sitter i just nu.
func offlineDisks(mounted: [Disk]) -> [Disk] {
    let on = Set(mounted.map(\.key))
    return readKnownDisks().filter { !on.contains($0.key) && indexInfo($0) != nil }
}

/// Inkopplade diskar plus urkopplade som har en lista.
func allDisks() -> [Disk] {
    let mounted = indexableDisks()
    return mounted + offlineDisks(mounted: mounted)
}

/// Kör diskutil och returnerar utskriften, eller felet som text.
func diskutil(_ args: [String]) -> (ok: Bool, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return (false, L("diskutil could not be started", "diskutil kunde inte startas")) }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus == 0, out)
}

/// Raderar kortet med samma filsystem och namn som det har, så att kameran känner igen det.
/// Bara för flyttbara kort; anroparen har kontrollerat det och fått användarens bekräftelse.
/// Svarar med enhetens id, som till skillnad från sökvägen gäller även efter formateringen.
@discardableResult
func formatVolume(_ volume: URL) throws -> String {
    let info = diskutil(["info", volume.path])
    guard info.ok, let line = info.out.split(separator: "\n").first(where: { $0.contains("File System Personality:") }),
          let fs = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !fs.isEmpty
    else { throw CopyError(L("Could not find the card's file system.", "Hittade inte kortets filsystem.")) }
    guard let idLine = info.out.split(separator: "\n").first(where: { $0.contains("Device Identifier:") }),
          let device = idLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !device.isEmpty
    else { throw CopyError(L("Could not find the card's device.", "Hittade inte kortets enhet.")) }
    let r = diskutil(["eraseVolume", fs, volume.lastPathComponent, volume.path])
    guard r.ok else { throw CopyError(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return device
}

/// Matar ut enheten och svarar med felet om det inte gick. Spotlight kan hålla ett nyformaterat kort en stund, så det görs några försök.
func ejectDevice(_ device: String) -> String? {
    var last = ""
    for attempt in 0..<5 {
        if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
        let r = diskutil(["eject", device])
        if r.ok { return nil }
        last = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return last
}

/// Formaterar och matar ut en tillfällig diskavbild, aldrig en riktig disk.
private func testFormatAndEject() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wl-format-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let name = "WLTEST\(ProcessInfo.processInfo.processIdentifier)"
    let image = dir.appendingPathComponent("t.dmg").path
    func hdiutil(_ args: [String]) { let p = try! Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: args + ["-quiet"]); p.waitUntilExit(); assert(p.terminationStatus == 0, "hdiutil \(args[0])") }
    hdiutil(["create", "-size", "20m", "-fs", "ExFAT", "-volname", name, image])
    hdiutil(["attach", "-nobrowse", image])
    let volume = URL(fileURLWithPath: "/Volumes/\(name)")
    let dcim = volume.appendingPathComponent("DCIM")
    try! FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
    let device = try! formatVolume(volume)
    assert(!FileManager.default.fileExists(atPath: dcim.path), "formateringen ska tömma kortet")
    assert(ejectDevice(device) == nil, "kortet ska gå att mata ut")
    assert(!FileManager.default.fileExists(atPath: volume.path), "kortet ska vara borta efter utmatningen")
}

func spotlightIndexed(_ volume: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
    p.arguments = ["-s", volume.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.contains("Indexing enabled")
}

func indexURL(_ d: Disk) -> URL {
    let dir = dataDir()
    let safe = d.key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    return dir.appendingPathComponent("\(safe).idx")
}

/// Antal filer och när listan gjordes, eller nil om disken aldrig skannats.
func indexInfo(_ d: Disk) -> (count: Int, date: Date)? {
    let url = indexURL(d)
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let first = String(decoding: (try? h.read(upToCount: 32)) ?? Data(), as: UTF8.self).split(separator: "\n").first ?? ""
    guard first.hasPrefix("# "), let n = Int(first.dropFirst(2)),
          let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
    return (n, date)
}

/// Går igenom hela disken och sparar listan. Anropas med låg prioritet så att macOS bromsar läsningen när datorn behöver kraften.
@discardableResult
func buildIndex(_ d: Disk, progress: (Int) -> Void = { _ in }) throws -> Int {
    let base = d.root.standardizedFileURL.path
    let skipDir = d.key == "home" ? base + "/Library" : nil
    // fts läser namn och storlek i samma svep som katalogen, som `find`. Det är många gånger snabbare än
    // FileManager, särskilt mot NAS:en där varje extra fråga är en tur över nätverket.
    // Paketmappar gås igenom, eftersom t.ex. Photos-bibliotek har originalen inuti.
    let rootC = strdup(base)
    defer { free(rootC) }
    var roots: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
    guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { throw CocoaError(.fileReadUnknown) }
    defer { fts_close(fts) }
    var mediaExt: [String: Bool] = [:]
    var lines = ""
    var n = 0
    while let ent = fts_read(fts) {
        if Task.isCancelled { throw CancellationError() }
        let info = Int32(ent.pointee.fts_info)
        guard info == FTS_D || info == FTS_F else { continue }
        let path = String(cString: ent.pointee.fts_path)
        let name = path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...]
        if info == FTS_D {
            // Dolda mappar, Synologys papperskorg, miniatyrmappar och programpaket (deras ikoner) räknas inte som säkerhetskopior.
            if ent.pointee.fts_level > 0 && (name.hasPrefix(".") || name == "#recycle" || name == "@eaDir" || name.hasSuffix(".app") || path == skipDir) {
                fts_set(fts, ent, FTS_SKIP)
            }
            continue
        }
        guard !name.hasPrefix("."), let dot = name.lastIndex(of: ".") else { continue }
        let ext = name[name.index(after: dot)...].lowercased()
        if mediaExt[ext] == nil { mediaExt[ext] = isMedia(URL(fileURLWithPath: "x.\(ext)")) }
        guard mediaExt[ext] == true, path.hasPrefix(base + "/"), !path.contains("\n"), !path.contains("\t") else { continue }
        lines += "\(ent.pointee.fts_statp.pointee.st_size)\t\(path.dropFirst(base.count + 1))\n"
        n += 1
        if n % 500 == 0 { progress(n) }
    }
    let url = indexURL(d)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Filer som fanns i förra listan men inte nu har tagits bort eller flyttats; spara var de låg.
    if let old = try? String(contentsOf: url, encoding: .utf8) {
        let now = Set(lines.split(separator: "\n"))
        let gone = old.split(separator: "\n").dropFirst().filter { !now.contains($0) }
        logGone(gone.compactMap { line -> String? in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            return "\(line[..<tab])\t\(base)/\(line[line.index(after: tab)...])"
        })
    }
    try Data("# \(n)\n\(lines)".utf8).write(to: url, options: .atomic)
    return n
}

/// Mappar på disken (enligt dess lista) som heter något av `names`, t.ex. "BLF 26 2" på både MA 2 TB och Wildermark.
func foldersNamed(_ names: Set<String>, on d: Disk) -> [URL] {
    guard !names.isEmpty, let text = try? String(contentsOf: indexURL(d), encoding: .utf8) else { return [] }
    var found = Set<String>()
    for line in text.split(separator: "\n").dropFirst() {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let parts = line[line.index(after: tab)...].split(separator: "/").dropLast()
        for (k, p) in parts.enumerated() where names.contains(String(p)) { found.insert(parts[...k].joined(separator: "/")) }
    }
    return found.sorted().map { d.root.appendingPathComponent($0) }
}

/// Filer som försvunnit mellan två skanningar: "<sekunder sedan 1970>\t<storlek>\t<sökväg>", samma format som kopieringsloggen.
func goneLogURL() -> URL {
    dataDir().appendingPathComponent("gone.log")
}

func logGone(_ sizeAndPath: [String], log: URL = goneLogURL()) {
    guard !sizeAndPath.isEmpty else { return }
    let now = Int(Date().timeIntervalSince1970)
    let text = sizeAndPath.map { "\(now)\t\($0)\n" }.joined()
    if let h = try? FileHandle(forWritingTo: log) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(text.utf8))
    } else {
        try? Data(text.utf8).write(to: log)
    }
}

/// Slår upp filnamnen i listorna för de diskar som är inkopplade nu.
/// Listan har storleken, så bara filer med samma namn och samma storlek som på kortet tas med.
/// Det sparar en uppslagning per kandidat, vilket är sekunder mot NAS:en när kameran återanvänder filnamn.
func indexedCandidates(_ files: [CardFile], disks: [Disk] = allDisks()) -> [String: [URL]] {
    var wanted: [String: Set<Int64>] = [:]
    for f in files { wanted[f.url.lastPathComponent, default: []].insert(f.size) }
    var out: [String: [URL]] = [:]
    for d in disks {
        guard let text = try? String(contentsOf: indexURL(d), encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").dropFirst() {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let rel = line[line.index(after: tab)...]
            let name = String(rel[(rel.lastIndex(of: "/").map { rel.index(after: $0) } ?? rel.startIndex)...])
            if let sizes = wanted[name], let size = Int64(line[..<tab]), sizes.contains(size) {
                out[name, default: []].append(d.root.appendingPathComponent(String(rel)))
            }
        }
    }
    return out
}

/// Lägger till nykopierade filer i listan för disken de hamnade på, så att nästa koll hittar dem direkt.
/// Oskannade diskar hoppas över; de får allt vid första skanningen. Listans datum behålls, så att den vanliga uppdateringen ändå sker.
func addToIndex(_ urls: [URL], disks: [Disk] = indexableDisks()) {
    for d in disks {
        let base = d.root.standardizedFileURL.path + "/"
        let url = indexURL(d)
        guard let text = try? String(contentsOf: url, encoding: .utf8), let nl = text.firstIndex(of: "\n"),
              let n = Int(text[..<nl].dropFirst(2)) else { continue }
        var added = ""
        var count = n
        for u in urls {
            let path = u.standardizedFileURL.path
            guard path.hasPrefix(base), !path.contains("\n"), !path.contains("\t") else { continue }
            let rel = path.dropFirst(base.count)
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let line = "\(size)\t\(rel)\n"
            if text.contains("\n" + line) || added.contains(line) { continue }
            added += line
            count += 1
        }
        guard !added.isEmpty else { continue }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try? Data("# \(count)\(text[nl...])\(added)".utf8).write(to: url, options: .atomic)
        if let date { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }
}

/// `Kortkoll --selftest`: kontrollerar addToIndex på en låtsasdisk i en tillfällig mapp.
// MARK: Kopieringslogg
// En rad per kopia: "<sekunder sedan 1970>\t<storlek>\t<sökväg dit>". Loggen rensas aldrig, så att appen
// kan säga vart en fil kopierades även när kopian senare har tagits bort eller disken inte är inkopplad.

func copyLogURL() -> URL {
    dataDir().appendingPathComponent("copies.log")
}

func logCopies(_ urls: [URL], log: URL = copyLogURL()) {
    guard !urls.isEmpty else { return }
    let now = Int(Date().timeIntervalSince1970)
    let lines = urls.compactMap { u -> String? in
        guard let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return "\(now)\t\(size)\t\(u.path)\n"
    }.joined()
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: log) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(lines.utf8))
    } else {
        try? Data(lines.utf8).write(to: log)
    }
}

struct CopyRecord: Equatable {
    let dest: URL
    let date: Date
    /// true: Kortkoll kopierade dit. false: en skanning såg att filen hade försvunnit därifrån.
    var copied = true
}

/// Senaste händelsen per kortfil, matchad på namn och storlek: en kopia från Kortkoll eller en fil som försvunnit från en disk.
func copyHistory(_ files: [CardFile], logs: [(URL, Bool)] = [(copyLogURL(), true), (goneLogURL(), false)]) -> [URL: CopyRecord] {
    var latest: [String: CopyRecord] = [:]
    for (log, copied) in logs {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3, let t = Double(parts[0]) else { continue }
            let dest = URL(fileURLWithPath: String(parts[2]))
            let key = "\(dest.lastPathComponent)\t\(parts[1])"
            let rec = CopyRecord(dest: dest, date: Date(timeIntervalSince1970: t), copied: copied)
            if (latest[key]?.date ?? .distantPast) <= rec.date { latest[key] = rec }
        }
    }
    var out: [URL: CopyRecord] = [:]
    for f in files { out[f.url] = latest["\(f.url.lastPathComponent)\t\(f.size)"] }
    return out
}

// MARK: Rensade
// Filer du själv har sagt att du har rensat bort, en rad per fil: "<namn>\t<storlek>".
// Så räknas de som hanterade även nästa gång kortet sitter i.

func discardedURL() -> URL {
    dataDir().appendingPathComponent("discarded.txt")
}

func discardKey(_ f: CardFile) -> String { "\(f.url.lastPathComponent)\t\(f.size)" }

func discardedKeys(_ store: URL = discardedURL()) -> Set<String> {
    Set(((try? String(contentsOf: store, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
}

func setDiscarded(_ files: [CardFile], _ on: Bool, store: URL = discardedURL()) {
    var keys = discardedKeys(store)
    for f in files { if on { keys.insert(discardKey(f)) } else { keys.remove(discardKey(f)) } }
    try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? (keys.sorted().map { $0 + "\n" }.joined()).write(to: store, atomically: true, encoding: .utf8)
}

func runSelfTest() {
    testCopyVerified()
    testFormatAndEject()
    let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
    let shots = [0.0, 1, 2, 3, 7, 8].map { noon.addingTimeInterval($0 * 3600) } + [noon.addingTimeInterval(86400)]
    assert(shootGroups(shots) == [[0, 1, 2, 3], [4, 5], [6]], "fyra timmars lucka och ny dag ska ge nya fotograferingar")
    assert(shootGroups(shots.reversed()).first == [6, 5, 4, 3], "ordningen avgörs av tiden")
    let merged = fitShoots((0..<10).map { [$0] }, to: 3)
    assert(merged.count <= 3 && merged.joined().count == 10, "sammanslagning får inte tappa filer")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kortkoll-test-\(UUID().uuidString)")
    let d = Disk(key: "selftest-\(UUID().uuidString)", name: "Test", root: root)
    let fm = FileManager.default
    try! fm.createDirectory(at: root.appendingPathComponent("P/2026-11-01"), withIntermediateDirectories: true)
    let a = root.appendingPathComponent("P/2026-11-01/A.JPG")
    try! Data(count: 10).write(to: a)
    try! buildIndex(d)
    try! fm.createDirectory(at: root.appendingPathComponent("#recycle"), withIntermediateDirectories: true)
    assert(subfolders(of: root).map(\.lastPathComponent) == ["P"], "bara vanliga mappar ska listas")
    assert(subfolders(of: root.appendingPathComponent("P/2026-11-01")).isEmpty, "filer är inte mappar")
    let b = root.appendingPathComponent("P/2026-11-01/B.JPG")
    try! Data(count: 20).write(to: b)
    addToIndex([a, b, b, URL(fileURLWithPath: "/elsewhere/C.JPG")], disks: [d])
    let text = try! String(contentsOf: indexURL(d), encoding: .utf8)
    try? fm.trashItem(at: indexURL(d), resultingItemURL: nil)
    try? fm.trashItem(at: root, resultingItemURL: nil)
    assert(text == "# 2\n10\tP/2026-11-01/A.JPG\n20\tP/2026-11-01/B.JPG\n", text)

    // Loggen: samma namn med annan storlek får inte matcha, och den senaste kopian vinner.
    let logRoot = fm.temporaryDirectory.appendingPathComponent("kortkoll-log-\(UUID().uuidString)")
    try! fm.createDirectory(at: logRoot.appendingPathComponent("x"), withIntermediateDirectories: true)
    let first = logRoot.appendingPathComponent("A.JPG"), second = logRoot.appendingPathComponent("x/A.JPG")
    try! Data(count: 10).write(to: first)
    try! Data(count: 10).write(to: second)
    let log = logRoot.appendingPathComponent("copies.log")
    logCopies([first], log: log)
    logCopies([second], log: log)
    let card = [CardFile(url: URL(fileURLWithPath: "/k/A.JPG"), rel: "A.JPG", size: 10, date: Date()),
                CardFile(url: URL(fileURLWithPath: "/k/B/A.JPG"), rel: "B/A.JPG", size: 11, date: Date())]
    let hist = copyHistory(card, logs: [(log, true)])
    let store = logRoot.appendingPathComponent("discarded.txt")
    setDiscarded(card, true, store: store)
    setDiscarded([card[1]], false, store: store)
    assert(discardedKeys(store) == ["A.JPG\t10"], "\(discardedKeys(store))")
    let goneLog = logRoot.appendingPathComponent("gone.log")
    logGone(["10\t/Volumes/X/P/A.JPG"], log: goneLog)
    let goneHist = copyHistory(card, logs: [(log, true), (goneLog, false)])
    assert(goneHist[card[0].url]?.copied == false && goneHist[card[0].url]?.dest.path == "/Volumes/X/P/A.JPG", "\(goneHist)")
    try? fm.trashItem(at: logRoot, resultingItemURL: nil)
    assert(hist[card[0].url]?.dest == second && hist[card[1].url] == nil, "\(hist)")
    print(text == "# 2\n10\tP/2026-11-01/A.JPG\n20\tP/2026-11-01/B.JPG\n" && hist[card[0].url]?.dest == second ? "OK" : "FEL:\n\(text)\n\(hist)")
}

/// `Kortkoll --index`: skannar alla diskar och skriver ut hur det gick.
/// `Kortkoll --index [disknamn …]`: skannar alla diskar, eller bara de som nämns, och skriver ut hur det gick.
func runIndex(_ only: [String] = []) {
    for d in indexableDisks() where only.isEmpty || only.contains(d.name) {
        let start = Date()
        do {
            let n = try buildIndex(d)
            print("\(d.name): \(n) filer på \(Int(Date().timeIntervalSince(start))) s")
        } catch { print("\(d.name): FEL \(error.localizedDescription)") }
    }
}

func mdEscape(_ s: String) -> String {
    var r = ""
    for c in s {
        if c == "\\" || c == "\"" || c == "*" { r.append("\\") }
        r.append(c)
    }
    return r
}

/// En kopia räknas bara om innehållet är identiskt (SHA-256), aldrig på namn.
func findBackup(of file: CardFile, among candidates: [URL], cardRoot: URL) -> URL? {
    verifyBackup(of: file, among: sameSize(as: file, among: candidates, cardRoot: cardRoot))
}

/// Steg 1, snabbt: kandidater med samma namn och exakt samma storlek, utanför kortet och papperskorgar.
/// Räcker för att rita kartan, men inte för att kalla filen säkrad.
func sameSize(as file: CardFile, among candidates: [URL], cardRoot: URL) -> [URL] {
    let card = cardRoot.standardizedFileURL.path + "/"
    return candidates.filter { c in
        let path = c.standardizedFileURL.path
        if path.hasPrefix(card) || path.contains("/.Trash/") || path.contains("/.Trashes/") || path.contains("/#recycle/") { return false }
        return (try? c.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) == file.size } ?? false
    }
}

/// Stickprov: tre bitar på 128 kB (början, mitten, slutet) måste vara identiska. Tar millisekunder även mot NAS:en,
/// och skiljer i praktiken alltid på olika bilder, proxyer och filer med återanvända filnummer.
func samplesMatch(_ a: URL, _ b: URL, size: Int64) -> Bool {
    guard let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
    defer { try? ha.close(); try? hb.close() }
    let chunk = 128 << 10
    for offset in Set([0, max(0, size / 2 - Int64(chunk) / 2), max(0, size - Int64(chunk))]) {
        guard (try? ha.seek(toOffset: UInt64(offset))) != nil, (try? hb.seek(toOffset: UInt64(offset))) != nil,
              let da = try? ha.read(upToCount: chunk), let db = try? hb.read(upToCount: chunk), da == db else { return false }
    }
    return true
}

/// Steg 2: jämför innehållet byte för byte (SHA-256). Kortet och första kandidaten läses samtidigt,
/// eftersom de ligger på olika enheter. `progress` får antal lästa byte från kortet.
func verifyBackup(of file: CardFile, among candidates: [URL], progress: ((Int) -> Void)? = nil) -> URL? {
    guard let first = candidates.first else { return nil }
    var cardHash: SHA256.Digest?, firstHash: SHA256.Digest?
    DispatchQueue.concurrentPerform(iterations: 2) { k in
        if k == 0 { cardHash = try? sha256(file.url, progress: progress) } else { firstHash = try? sha256(first) }
    }
    guard let h = cardHash else { return nil }
    if firstHash == h { return first }
    return candidates.dropFirst().first { (try? sha256($0)) == h }
}

func sha256(_ url: URL, progress: ((Int) -> Void)? = nil) throws -> SHA256.Digest {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let d = try h.read(upToCount: 8 << 20), !d.isEmpty {
        hasher.update(data: d)
        progress?(d.count)
    }
    return hasher.finalize()
}

/// Jämför två filer. De läses samtidigt, eftersom de oftast ligger på olika enheter och väntar på varsin.
func sameContent(_ a: URL, _ b: URL) throws -> Bool {
    var ha: Result<SHA256.Digest, Error>!, hb: Result<SHA256.Digest, Error>!
    DispatchQueue.concurrentPerform(iterations: 2) { k in
        if k == 0 { ha = Result { try sha256(a) } } else { hb = Result { try sha256(b) } }
    }
    return try ha.get() == hb.get()
}

/// Kopierar och kontrollerar att kopian är identisk. Skriver aldrig över en befintlig fil.
func copyVerified(_ src: URL, to dst: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: dst.path) {
        guard try sameContent(src, dst) else { throw CopyError(L("A different file with the same name is already there", "En annan fil med samma namn finns redan där")) }
        return
    }
    // Filen får sitt riktiga namn först när den är kontrollerad, så en avbruten kopia ser aldrig ut som en färdig fil.
    // Filändelsen är inte media, så en kvarlämnad del räknas inte som en fil av appen.
    let part = dst.deletingLastPathComponent().appendingPathComponent("\(dst.lastPathComponent).\(UUID().uuidString.prefix(8)).wilderloader-part")
    do {
        try copyStreaming(src, to: part)
        guard try sameContent(src, part) else { throw CopyError(L("The copy did not come out identical", "Kopian blev inte identisk")) }
        try fm.moveItem(at: part, to: dst)  // Misslyckas om filen hunnit dyka upp, så inget skrivs över.
    } catch {
        // shortcut: går papperskorgen inte att nå (vanligt på NAS) blir delen kvar, och användaren får ta bort den.
        try? fm.trashItem(at: part, resultingItemURL: nil)
        throw error
    }
}

/// Läser och skriver samtidigt, med en liten kö emellan, så att den långsammaste enheten sätter farten och inte summan av båda.
private func copyStreaming(_ src: URL, to dst: URL) throws {
    let input = try FileHandle(forReadingFrom: src)
    defer { try? input.close() }
    let fd = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)  // O_EXCL: skriver aldrig över.
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dst.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]) }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    // Utan cache måste kontrollen läsa kopian från disken, inte från Macens minne.
    _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
    _ = fcntl(fd, F_NOCACHE, 1)

    let lock = NSLock()
    var queue: [Data?] = []
    var failure: Error?
    let free = DispatchSemaphore(value: 4), ready = DispatchSemaphore(value: 0)
    func fail(_ e: Error) { lock.lock(); if failure == nil { failure = e }; lock.unlock() }
    func failed() -> Bool { lock.lock(); defer { lock.unlock() }; return failure != nil }
    func push(_ d: Data?) { lock.lock(); queue.append(d); lock.unlock(); ready.signal() }

    DispatchQueue.concurrentPerform(iterations: 2) { k in
        if k == 0 {
            // Läsaren avslutar alltid kön med nil, och skrivaren tömmer den även efter ett fel. Så kan ingen av dem fastna.
            defer { push(nil) }
            do {
                while !failed() {
                    free.wait()
                    guard let d = try input.read(upToCount: 8 << 20), !d.isEmpty else { return }
                    push(d)
                }
            } catch { fail(error) }
        } else {
            while true {
                ready.wait()
                lock.lock(); let next = queue.removeFirst(); lock.unlock()
                free.signal()
                guard let d = next else { return }
                if failed() { continue }
                do { try output.write(contentsOf: d) } catch { fail(error) }
            }
        }
    }
    do { try output.synchronize(); try output.close() } catch { fail(error) }
    if let failure { throw failure }

    // Datumen avgör vilken fotografering filen hör till, så de sätts även om övrig metadata inte går att föra över.
    _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_METADATA))
    let dates = try FileManager.default.attributesOfItem(atPath: src.path).filter { $0.key == .modificationDate || $0.key == .creationDate }
    try FileManager.default.setAttributes(dates, ofItemAtPath: dst.path)
}

/// Kopian ska bli identisk med samma datum, aldrig skriva över och inte fastna eller lämna en falsk fil när disken blir full.
private func testCopyVerified() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("wl-copy-\(UUID().uuidString)")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let src = dir.appendingPathComponent("a.mov"), dst = dir.appendingPathComponent("ut/a.mov")
    var bytes = Data(count: 40 << 20)
    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
    try! bytes.write(to: src)
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    try! fm.setAttributes([.modificationDate: old], ofItemAtPath: src.path)

    try! copyVerified(src, to: dst)
    assert(try! Data(contentsOf: dst) == bytes, "kopian ska vara identisk")
    assert((try! fm.attributesOfItem(atPath: dst.path)[.modificationDate] as! Date) == old, "datumet ska följa med")
    assert(try! fm.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path) == ["a.mov"], "inga delar ska bli kvar")
    assert(!isMedia(URL(fileURLWithPath: "a.MOV.1234.wilderloader-part")), "en del ska inte räknas som en fil")

    let taken = dir.appendingPathComponent("ut/b.mov")
    try! Data("annan".utf8).write(to: taken)
    assert((try? copyVerified(src, to: taken)) == nil, "en annan fil med samma namn ska ge fel")
    assert(try! Data(contentsOf: taken) == Data("annan".utf8), "befintlig fil ska inte skrivas över")
    assert((try? copyVerified(dir.appendingPathComponent("finns-inte.mov"), to: dir.appendingPathComponent("ut/c.mov"))) == nil, "saknad källa ska ge fel")
    assert(!fm.fileExists(atPath: dir.appendingPathComponent("ut/c.mov").path), "misslyckad kopia ska inte få riktigt namn")

    // Full disk: 40 MB till en avbild på 10 MB.
    let name = "WLCOPY\(ProcessInfo.processInfo.processIdentifier)", image = dir.appendingPathComponent("t.dmg").path
    func hdiutil(_ args: [String]) { let p = try! Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: args + ["-quiet"]); p.waitUntilExit(); assert(p.terminationStatus == 0, "hdiutil \(args[0])") }
    hdiutil(["create", "-size", "10m", "-fs", "APFS", "-volname", name, image])
    hdiutil(["attach", "-nobrowse", image])
    defer { hdiutil(["detach", "/Volumes/\(name)", "-force"]) }
    let full = URL(fileURLWithPath: "/Volumes/\(name)/a.mov")
    assert((try? copyVerified(src, to: full)) == nil, "full disk ska ge fel")
    assert(!fm.fileExists(atPath: full.path), "full disk ska inte ge en falsk fil")
}

struct CopyError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

/// `Kortkoll --copy <kort> <projektmapp>`: kopierar saknade filer till datummappar, som appen gör.
func runCopy(_ card: String, _ project: String) {
    let root = URL(fileURLWithPath: card)
    let files = listFiles(root)
    let cands = candidates(of: files)
    var copied: [URL] = []
    for f in files where findBackup(of: f, among: cands[f.url.lastPathComponent] ?? [], cardRoot: root) == nil {
        let target = URL(fileURLWithPath: project).appendingPathComponent(dayString(f.date)).appendingPathComponent(f.url.lastPathComponent)
        do { try copyVerified(f.url, to: target); copied.append(target); print("KOPIERAD \(f.rel) -> \(target.path)") }
        catch { print("FEL      \(f.rel): \(error.localizedDescription)") }
    }
    addToIndex(copied)
    logCopies(copied)
}

/// `Kortkoll --check <mapp>`: skriver ut status per fil, för test utan UI.
/// `Kortkoll --check <mapp> [--full]`: snabbkoll som i appen, eller full kontroll byte för byte.
func runCheck(_ path: String, full: Bool = false) {
    let root = URL(fileURLWithPath: path)
    let files = listFiles(root)
    let cands = candidates(of: files)
    let offline = offlineDisks(mounted: indexableDisks()).map { $0.root.standardizedFileURL.path + "/" }
    for f in files {
        let same = sameSize(as: f, among: cands[f.url.lastPathComponent] ?? [], cardRoot: root)
        let hit = full ? verifyBackup(of: f, among: same) : same.first { samplesMatch(f.url, $0, size: f.size) }
        let away = (cands[f.url.lastPathComponent] ?? []).first { u in offline.contains { u.standardizedFileURL.path.hasPrefix($0) } }
        print(hit.map { "FINNS   \(f.rel) -> \($0.path)" } ?? away.map { "LISTA   \(f.rel) -> \($0.path) (urkopplad)" } ?? "SAKNAS  \(f.rel)")
    }
}
