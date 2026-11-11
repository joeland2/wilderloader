import Foundation
import UniformTypeIdentifiers

// Filtyper från kameror, drönare och ljudinspelare. macOS känner inte igen många av dem, t.ex. BRAW och R3D.
// Ingen lista kan bli komplett, så det som inte känns igen spärrar i stället formateringen. Det får aldrig raderas i tysthet.

/// Inspelningarna: letas upp på diskarna, kontrolleras och kopieras.
let cameraMedia: Set<String> = [
    // Filmkameror
    "braw", "r3d", "ari", "arx", "crm", "rmf", "nev", "cine", "cci", "siv", "zraw", "krw", "kraw",
    "mxf", "mov", "qt", "mp4", "m4v", "dpx", "cin", "exr",
    // Övrig video
    "mts", "m2ts", "m2t", "ts", "mod", "tod", "avi", "mkv", "wmv", "asf", "mpg", "mpeg", "mpe", "m1v", "m2v", "m2p", "vob",
    "3gp", "3g2", "dv", "dif", "webm", "flv", "f4v", "ogv", "mj2", "h264", "h265", "264", "265", "hevc",
    // Action, 360 och drönare. LRV och LRF är lågupplösta kopior av klippen.
    "insv", "insp", "lrv", "lrf", "360", "osv",
    // Råbilder från stillbildskameror
    "3fr", "arw", "arq", "bay", "cap", "cr2", "cr3", "crw", "cs1", "cxi", "dc2", "dcr", "dng", "drf", "dsc", "eip", "erf", "fff", "gpr",
    "iiq", "j6i", "k25", "kc2", "kdc", "mdc", "mef", "mfw", "mos", "mrw", "nef", "nrw", "obm", "orf", "ori", "pef", "ptx", "pxn",
    "raf", "raw", "rw2", "rw3", "rwl", "rwz", "sr2", "srf", "srw", "x3f",
    // Övriga bilder
    "jpg", "jpeg", "jpe", "jfif", "mpo", "hif", "heic", "heif", "avif", "jxl", "tif", "tiff", "png", "bmp", "gif", "webp", "tga", "psd",
    // Ljud
    "wav", "wave", "bwf", "rf64", "bw64", "w64", "aif", "aiff", "aifc", "caf", "mp3", "mp2", "mpa", "m4a", "aac", "ac3",
    "flac", "ogg", "oga", "opus", "wma", "amr", "3ga", "dsf", "dff", "ape", "wv", "au", "snd",
]

/// Små filer som hör till ett klipp. Följer med vid kopiering om namnet stämmer med klippet.
let sidecarFiles: Set<String> = [
    "xml", "xmp", "srt", "thm", "smi", "bim", "ppn", "cpf", "cif", "sif", "mif", "vix", "rmd", "rtn", "sidecar",
    "ale", "edl", "cdl", "cc", "ccc", "cube", "3dl", "look", "mhl", "ascmhl", "md5", "sfv", "xxh", "csv",
    "aae", "dop", "pp3", "on1", "nksc", "zdm", "zsg", "hprj",
]

/// Kortets egna register och inställningar. Skapas av kameran, och raderas utan varning så länge de är små.
private let cardSystemFiles: Set<String> = [
    "bdm", "mpl", "cpi", "bnp", "inp", "tdt", "tid", "dat", "bup", "ifo", "sav", "bin", "ini", "cfg", "txt", "log", "nfo", "sys",
    "db", "idx", "lst", "sig", "tbl", "plist", "json",
]

/// Större än så här kan vara en inspelning, oavsett filändelse.
private let minorFileLimit: Int64 = 16 << 20

/// Bilder, video och ljud. Kamerans egna databasfiler (t.ex. PRIVATE/…/CONTENTS.B00) räknas inte.
func isMedia(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if cameraMedia.contains(ext) { return true }
    guard let t = UTType(filenameExtension: ext) else { return false }
    return t.conforms(to: .image) || t.conforms(to: .audiovisualContent)
}

struct CardContents {
    var files: [CardFile] = []
    /// Klippets sidofiler, med klippets adress som nyckel.
    var sidecars: [URL: [URL]] = [:]
    /// Filer appen inte kan kontrollera. Formatering utan varning spärras så länge de finns.
    var other: [URL] = []
    /// Små register- och sidofiler. De jämförs inte med någon kopia.
    var minor = 0
}

/// Går igenom allt på kortet och delar upp det. Dolda filer och systemmappar räknas inte.
func cardContents(_ root: URL) -> CardContents {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return CardContents() }
    let base = root.standardizedFileURL.path
    var out = CardContents()
    var small: [(url: URL, size: Int64)] = []
    for case let url as URL in e {
        if systemFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if v.isPackage == true { out.other.append(url); continue }
        guard v.isRegularFile == true else { continue }
        let size = Int64(v.fileSize ?? 0)
        if isMedia(url) {
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            out.files.append(CardFile(url: url, rel: rel, size: size, date: v.contentModificationDate ?? Date()))
        } else {
            small.append((url, size))
        }
    }
    out.files.sort { $0.rel < $1.rel }

    // Klippen per mapp och namn. RED delar långa klipp i _001, _002 medan sidofilen saknar numret, så båda namnen läggs in.
    var clips: [String: [String: [URL]]] = [:]
    for f in out.files {
        let dir = f.url.deletingLastPathComponent().path
        let stem = f.url.deletingPathExtension().lastPathComponent.lowercased()
        var names = [stem]
        if let cut = stem.range(of: #"_\d{3}$"#, options: .regularExpression) { names.append(String(stem[..<cut.lowerBound])) }
        for n in names { clips[dir, default: [:]][n, default: []].append(f.url) }
    }
    for (url, size) in small {
        let ext = url.pathExtension.lowercased()
        if sidecarFiles.contains(ext) {
            // Sony skriver C0001M01.XML till C0001.MP4, så klippets namn kan vara början på sidofilens.
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let inDir = clips[url.deletingLastPathComponent().path] ?? [:]
            var owners: [URL]?
            var n = stem.count
            while owners == nil, n >= 4 { owners = inDir[String(stem.prefix(n))]; n -= 1 }
            if let owners {
                for o in owners { out.sidecars[o, default: []].append(url) }
                out.minor += 1
                continue
            }
        }
        if size < minorFileLimit, sidecarFiles.contains(ext) || cardSystemFiles.contains(ext) { out.minor += 1 } else { out.other.append(url) }
    }
    out.other.sort { $0.path < $1.path }
    return out
}

/// "2 XYZ, 1 PDF": vilka sorters filer det är, för varningen vid formatering.
func describeKinds(_ urls: [URL]) -> String {
    var count: [String: Int] = [:]
    for u in urls { count[u.pathExtension.isEmpty ? "?" : u.pathExtension.uppercased(), default: 0] += 1 }
    let top = count.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    return top.prefix(4).map { "\($0.value) \($0.key)" }.joined(separator: ", ") + (top.count > 4 ? "…" : "")
}

/// Filer på diskarna med en viss storlek, oavsett namn. Så hittas även kopior som döpts om.
func sizeCandidates(_ sizes: Set<Int64>, disks: [Disk]) -> [Int64: [URL]] {
    var out: [Int64: [URL]] = [:]
    let wanted = sizes.subtracting([0])
    guard !wanted.isEmpty else { return out }
    for d in disks {
        guard let text = try? String(contentsOf: indexURL(d), encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").dropFirst() {
            guard let tab = line.firstIndex(of: "\t"), let size = Int64(line[..<tab]), wanted.contains(size) else { continue }
            out[size, default: []].append(d.root.appendingPathComponent(String(line[line.index(after: tab)...])))
        }
    }
    return out
}

/// Färdiga mappmallar. Tom mall lägger filerna direkt i den valda mappen.
let dateTemplate = "{date}"
let filmTemplate = "{project}/01_RAW/{camera}/{date}"

/// Mappvägen för en fil enligt mallen. Fälten kan inte ta sig ut ur den valda mappen.
func renderTemplate(_ template: String, project: String, camera: String, date: Date) -> String {
    renderTemplate(template, project: project, camera: camera, day: dayString(date))
}

func renderTemplate(_ template: String, project: String, camera: String, day: String) -> String {
    func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let path = template
        .replacingOccurrences(of: "{project}", with: clean(project))
        .replacingOccurrences(of: "{camera}", with: clean(camera))
        .replacingOccurrences(of: "{date}", with: day)
    return path.split(separator: "/").map { clean(String($0)) }
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        .joined(separator: "/")
}

/// Mallens väg i `base`. Har användaren redan valt Coast/01_RAW läggs de nivåerna inte till en gång till.
func templatePlace(_ base: URL, _ sub: String) -> URL {
    let have = base.pathComponents, want = sub.split(separator: "/").map(String.init)
    let overlap = (0...min(have.count, want.count)).last { have.suffix($0) == want.prefix($0) } ?? 0
    return want.dropFirst(overlap).reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
}

/// Hur långt en skanning har kommit, mätt mot antalet filer förra gången. Tid kvar först när takten går att lita på.
func scanEstimate(done: Int, last: Int?, elapsed: TimeInterval) -> (fraction: Double, left: TimeInterval?)? {
    guard let last, last > 0 else { return nil }
    let fraction = min(0.99, Double(done) / Double(last))
    // Fler filer än förra gången: slutet går inte att veta, så ingen tid visas.
    guard done >= 500, elapsed >= 5, done < last else { return (fraction, nil) }
    return (fraction, elapsed * Double(last - done) / Double(done))
}

/// "<1 min", "~4 min", "~2 h" kvar.
func leftLabel(_ s: TimeInterval) -> String {
    s < 60 ? L("<1 min left", "<1 min kvar") : s < 3600 ? L("~\(Int((s / 60).rounded())) min left", "~\(Int((s / 60).rounded())) min kvar") : L("~\(Int((s / 3600).rounded())) h left", "~\(Int((s / 3600).rounded())) h kvar")
}

/// Formaten ska räknas, okända filer ska synas och sidofiler ska hitta sina klipp.
func testFormats() {
    assert(scanEstimate(done: 100, last: nil, elapsed: 60) == nil, "första skanningen har inget att jämföra med")
    assert(scanEstimate(done: 10_000, last: 40_000, elapsed: 60).map { $0.fraction == 0.25 && $0.left == 180 } == true, "en fjärdedel på en minut ger tre minuter kvar")
    assert(scanEstimate(done: 300, last: 40_000, elapsed: 60)?.left == nil, "för tidigt för att gissa tid")
    assert(scanEstimate(done: 50_000, last: 40_000, elapsed: 60).map { $0.fraction == 0.99 && $0.left == nil } == true, "fler filer än förra gången")
    let raw = URL(fileURLWithPath: "/Volumes/SSD/Coast/01_RAW", isDirectory: true)
    assert(templatePlace(raw, "Coast/01_RAW/Cam A/2026-11-05").path == "/Volumes/SSD/Coast/01_RAW/Cam A/2026-11-05", "valda nivåer ska inte upprepas")
    assert(templatePlace(raw, "Other/01_RAW/Cam A").path == "/Volumes/SSD/Coast/01_RAW/Other/01_RAW/Cam A", "bara början av mallen får hoppas över")
    assert(templatePlace(raw, "").path == raw.path, "tom mall ska ge samma mapp")

    for ext in ["braw", "BRAW", "r3d", "ari", "arx", "crm", "rmf", "nev", "cine", "mxf", "insv", "lrf", "lrv", "cr3", "iiq", "x3f", "rf64", "w64", "wav", "hif"] {
        assert(isMedia(URL(fileURLWithPath: "a.\(ext)")), "\(ext) ska räknas som en inspelning")
    }
    for ext in ["xml", "xyz", "pdf", "wilderloader-part"] { assert(!isMedia(URL(fileURLWithPath: "a.\(ext)")), "\(ext) är ingen inspelning") }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wl-formats-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let dir = root.appendingPathComponent("CLIP")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("System Volume Information"), withIntermediateDirectories: true)
    func make(_ name: String, _ bytes: Int = 10) -> URL {
        let u = name.contains("/") ? root.appendingPathComponent(name) : dir.appendingPathComponent(name)
        try! Data(count: bytes).write(to: u)
        return u
    }
    let sony = make("C0001.MP4"), sonyXML = make("C0001M01.XML")
    let red = make("A001_C001_0101AB_001.R3D"), redSide = make("A001_C001_0101AB.RMD")
    let braw = make("B001.braw"), brawSide = make("B001.sidecar")
    _ = make("MEDIAPRO.XML")                                    // Sidofil utan klipp: liten, varnas inte för.
    _ = make("STATUS.BIN")                                      // Kortets register.
    _ = make("System Volume Information/x.xyz")                 // Systemmapp: räknas inte.
    let unknown = make("A.XYZ")                                 // Okänd liten fil.
    let bigSystem = make("HUGE.BIN", Int(minorFileLimit))       // Stor med registerändelse kan vara en inspelning.
    let c = cardContents(root)
    assert(Set(c.files.map(\.url.lastPathComponent)) == [sony.lastPathComponent, red.lastPathComponent, braw.lastPathComponent], "\(c.files.map(\.rel))")
    // Tillfälliga mappar kan heta /var eller /private/var, så klippen slås upp på filnamnet.
    func sides(_ clip: URL) -> [String]? { c.sidecars.first { $0.key.lastPathComponent == clip.lastPathComponent }?.value.map(\.lastPathComponent) }
    assert(sides(sony) == [sonyXML.lastPathComponent], "Sonys XML ska höra till klippet")
    assert(sides(red) == [redSide.lastPathComponent], "REDs RMD ska höra till klippet")
    assert(sides(braw) == [brawSide.lastPathComponent], "BRAW:s sidofil ska höra till klippet")
    assert(Set(c.other.map(\.lastPathComponent)) == [unknown.lastPathComponent, bigSystem.lastPathComponent], "\(c.other)")
    assert(c.minor == 5, "\(c.minor)")
    assert(describeKinds(c.other) == "1 BIN, 1 XYZ", describeKinds(c.other))

    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
    assert(renderTemplate(filmTemplate, project: "Coast", camera: "Cam A", date: day) == "Coast/01_RAW/Cam A/2026-11-05", "mallen")
    assert(renderTemplate(filmTemplate, project: "a/b", camera: "../..", date: day) == "a-b/01_RAW/..-../2026-11-05", "fälten ska inte kunna skapa mappar eller gå uppåt")
    assert(renderTemplate("../{date}/./x", project: "", camera: "", date: day) == "2026-11-05/x", "mallen ska inte kunna gå uppåt")
    assert(renderTemplate("{project}/{date}", project: "", camera: "", date: day) == "2026-11-05", "tomt fält ska inte ge en tom mapp")
    assert(renderTemplate("", project: "x", camera: "y", date: day) == "", "tom mall ska inte ge någon undermapp")

    // Omdöpta kopior: rätt storlek hittas oavsett namn, och urkopplade diskar behöver inte läsas.
    let disk = Disk(key: "selftest-\(UUID().uuidString)", name: "Test", root: root)
    try! buildIndex(disk)
    defer { try? fm.trashItem(at: indexURL(disk), resultingItemURL: nil); try? fm.trashItem(at: indexURL(disk).deletingPathExtension().appendingPathExtension("parts"), resultingItemURL: nil) }
    assert(sizeCandidates([10, 0, 999], disks: [disk])[10]?.count == 3, "\(sizeCandidates([10], disks: [disk]))")
    assert(sizeCandidates([999], disks: [disk]).isEmpty, "fel storlek ska inte ge någon träff")
    assert(sizeCandidates([0], disks: [disk]).isEmpty, "tomma filer ska inte matchas")
}
