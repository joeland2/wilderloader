import SwiftUI
import AppKit
import QuickLookThumbnailing

@main
enum Main {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-demo" {
            MainActor.assumeIsolated { Demo.render(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
            return
        }
        #endif
        migrateFromOldNames()
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--check" {
            runCheck(args[2], full: args.contains("--full"))
            return
        }
        if args.count >= 2, args[1] == "--index" {
            runIndex(Array(args.dropFirst(2)))
            return
        }
        if args.count == 2, args[1] == "--disks" {
            for d in indexableDisks() { print("\(d.name): \(d.spotlight ? "söks direkt" : "behöver lista")") }
            return
        }
        if args.count == 2, args[1] == "--selftest" {
            runSelfTest()
            return
        }
        if args.count == 4, args[1] == "--copy" {
            runCopy(args[2], args[3])
            return
        }
        KortkollApp.main()
    }
}

struct KortkollApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup(appName) {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 940, minHeight: 500)
                .onAppear { NSApp.activate() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Status: Equatable {
    /// `verifying`: en fil med samma namn och storlek finns, men innehållet är inte jämfört än.
    /// `discarded`: finns bara på kortet, men du har sagt att du har rensat bort den.
    case checking, verifying(URL), found(URL), missing, discarded, copied(URL), failed(String)
}

struct DiskRow: Identifiable {
    let disk: Disk
    var count: Int?
    var date: Date?
    /// Antal filer hittills medan disken skannas, annars nil.
    var progress: Int?
    /// Hur full disken är, 0–1.
    var fill: Double?
    var id: String { disk.key }
}

struct Item: Identifiable {
    let id = UUID()
    let file: CardFile
    var status: Status = .checking
    /// Alla kopior som hittades, inte bara den som visas; så vet kabeln vilka som redan finns på måldisken.
    var copies: [URL] = []
}

/// En kabel mellan två diskar: kortfiler som finns på `from` kopieras från kortet vidare till `folder` på `to`.
struct Forward: Equatable {
    enum Layout: String { case mirror, byDay, flat }
    let from: String
    let to: String
    let folder: URL
    let layout: Layout
    /// Kopiera även filer som redan finns någonstans på måldisken, t.ex. till en ny projektmapp.
    var includeExisting = false
}

@MainActor
final class Model: ObservableObject {
    @Published var card: URL?
    @Published var items: [Item] = []
    /// Tidigare kopior av filer som nu bara finns på kortet, från kopieringsloggen.
    @Published var history: [URL: CopyRecord] = [:]
    @Published var checked = 0
    @Published var busy = false
    @Published var language: Lang = appLang {
        didSet {
            appLang = language
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            refreshDisks()
        }
    }
    @Published var copyingTo: URL?
    /// Full kontroll jämför allt byte för byte. Annars räcker namn, storlek och stickprov, vilket tar sekunder.
    @Published var fullCheck = UserDefaults.standard.bool(forKey: "fullCheck") {
        didSet {
            UserDefaults.standard.set(fullCheck, forKey: "fullCheck")
            guard let card, copyingTo == nil else { return }
            // Av: snabbkollen är redan gjord för allt, så det som väntar på byte-jämförelse räknas som hittat direkt.
            if !fullCheck, !items.isEmpty, !items.contains(where: { $0.status == .checking }) {
                task?.cancel()
                for i in items.indices { if case .verifying(let u) = items[i].status { items[i].status = .found(u) } }
                checked = items.count
                bytesDone = 0
                bytesTotal = 0
                busy = false
            } else { scan(card) }
        }
    }
    /// Förlopp i byte för kontroll eller kopiering, för stapeln och tid kvar.
    @Published var bytesDone: Int64 = 0
    @Published var bytesTotal: Int64 = 0
    @Published var progressStart = Date()
    @Published var thumbs: [NSImage] = []
    /// De första bilderna på kortet, så att man ser vilket jobb det är.
    /// Kortets filer delade i fotograferingar, som index i `items`.
    @Published var shoots: [[Int]] = []
    @Published var disks: [DiskRow] = []
    private var task: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    /// `demo`: inga riktiga diskar eller kort, för bilderna till webbsidan.
    init(demo: Bool = false) {
        guard !demo else { return }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let before = self.card
                self.lookForCard(); self.refreshDisks(); self.autoIndex()
                // En annan disk kopplades in: kolla kortet igen mot den, så att man kan byta diskar i en och samma port.
                if let card = self.card, card == before { self.recheck() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisks()
                guard let self, let card = self.card, !FileManager.default.fileExists(atPath: card.path) else { return }
                self.task?.cancel()
                self.card = nil
                self.items = []; self.shoots = []
            }
            // En annan disk togs ut: kolla kortet igen, så att linjerna till den disken försvinner.
            Task { @MainActor in self?.recheck() }
        }
        refreshDisks()
        autoIndex()
        // `--card <mapp>` öppnar en mapp som kort direkt, för test.
        if let i = CommandLine.arguments.firstIndex(of: "--card"), i + 1 < CommandLine.arguments.count {
            scan(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        } else {
            lookForCard()
        }
    }

    var missing: [Item] { items.filter { $0.status == .missing } }
    /// Filerna i en fotografering. Vyer kan ritas med gamla index strax efter att listan bytts, så de som inte finns längre hoppas över.
    func items(in group: [Int]) -> [Item] { group.filter(items.indices.contains).map { items[$0] } }
    /// Av de valda kopiorna: de som har minst en kopia till på en annan, inkopplad disk (kortet räknas inte).
    /// Bara de får läggas i papperskorgen, så att det alltid finns kvar en kopia utöver kortet.
    func duplicates(_ urls: Set<URL>) -> [(url: URL, other: URL)] {
        let card = self.card.map { $0.standardizedFileURL.path + "/" } ?? "\u{0}"
        let roots = disks.map { $0.disk.root.standardizedFileURL.path + "/" }
        func root(_ u: URL) -> String? { let p = u.standardizedFileURL.path; return roots.first { p.hasPrefix($0) } }
        var out: [(URL, URL)] = []
        for it in items {
            for u in it.copies where urls.contains(u) {
                let other = it.copies.first { o in
                    o != u && root(o) != root(u) && !o.standardizedFileURL.path.hasPrefix(card) && FileManager.default.fileExists(atPath: o.path)
                }
                if let other { out.append((u, other)) }
            }
        }
        return out
    }

    /// Lägger kopiorna i papperskorgen; aldrig radering för gott. Om en disk saknar papperskorg (som vissa NAS:er) blir filen kvar och felet visas.
    func trash(_ urls: [URL]) {
        var errors: [String] = []
        for u in urls {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        if !errors.isEmpty {
            let a = NSAlert()
            a.messageText = L("\(errors.count) files could not be moved to the Trash", "\(errors.count) filer kunde inte läggas i papperskorgen")
            a.informativeText = L("They are untouched.", "De är orörda.") + "\n\n" + errors.prefix(8).joined(separator: "\n")
            a.runModal()
        }
        recheck()
    }

    /// Filer som bara hittades på en urkopplad disk, alltså bara mot listan.
    var awayOnly: Int {
        let roots = disks.filter(\.disk.offline).map { $0.disk.root.standardizedFileURL.path + "/" }
        return items.filter { if case .found(let u) = $0.status { return roots.contains { u.standardizedFileURL.path.hasPrefix($0) } }; return false }.count
    }
    var discarded: [Item] { items.filter { $0.status == .discarded } }

    /// Markerar kortfiler som rensade, eller ångrar det. Sparas, så att de känns igen nästa gång.
    func markDiscarded(_ urls: Set<URL>, _ on: Bool) {
        let from: Status = on ? .missing : .discarded
        let picked = items.indices.filter { items[$0].status == from && urls.contains(items[$0].file.url) }
        setDiscarded(picked.map { items[$0].file }, on)
        for i in picked { items[i].status = on ? .discarded : .missing }
    }
    var failed: [Item] { items.filter { if case .failed = $0.status { return true }; return false } }
    var allSafe: Bool { !busy && !items.isEmpty && missing.isEmpty && failed.isEmpty }
    /// Mapparna på disken där filerna redan ligger, med hur många i varje.
    func homes(of files: [CardFile], on disk: Disk) -> [URL: Int] {
        let want = Set(files.map(\.url)), root = dirURL(disk.root).path + "/"
        var out: [URL: Int] = [:]
        for it in items where want.contains(it.file.url) {
            var all = it.copies
            if case .found(let u) = it.status { all.append(u) }
            if case .copied(let u) = it.status { all.append(u) }
            let dirs = Set(all.filter { $0.standardizedFileURL.path.hasPrefix(root) }.map { dirURL($0.deletingLastPathComponent()) })
            for d in dirs { out[d, default: 0] += 1 }
        }
        return out
    }

    /// Hur många av kortets filer från samma dagar som finns i varje mapp på disken.
    /// Ligger de i en datummapp räknas mappen ovanför, eftersom datumet läggs till vid kopieringen.
    private func sameDayFolders(of files: [CardFile], on disk: Disk) -> [URL: Int] {
        let days = Set(files.map { dayString($0.date) }), root = dirURL(disk.root).path + "/"
        var out: [URL: Int] = [:]
        for it in items where days.contains(dayString(it.file.date)) {
            for u in it.copies where u.standardizedFileURL.path.hasPrefix(root) {
                var dir = dirURL(u.deletingLastPathComponent())
                if days.contains(dir.lastPathComponent) { dir = dirURL(dir.deletingLastPathComponent()) }
                out[dir, default: 0] += 1
            }
        }
        return out
    }

    /// Mappen där väljaren öppnas: den där kortets filer från samma dagar redan ligger, annars diskens rot.
    func likelyFolder(for files: [CardFile], on disk: Disk) -> URL {
        sameDayFolders(of: files, on: disk).max { $0.value < $1.value }?.key ?? dirURL(disk.root)
    }

    /// Diskarna filer kan kopieras till: inkopplade och inte den som kontrolleras.
    var copyTargets: [Disk] {
        disks.map(\.disk).filter { !$0.offline && dirURL($0.root) != card.map(dirURL) }
    }

    /// Disken med flest av kortets filer från samma dagar, så att det nya hamnar bredvid det gamla.
    func likelyDisk(for files: [CardFile]) -> Disk? {
        copyTargets.map { ($0, sameDayFolders(of: files, on: $0).values.reduce(0, +)) }.max { $0.1 < $1.1 }?.0
    }

    func lookForCard() {
        if card == nil, let first = mountedCards().first { scan(first) }
    }

    func scan(_ root: URL) {
        task?.cancel()
        card = root
        items = []
        shoots = []
        history = [:]
        forward = nil
        checked = 0
        copyingTo = nil
        busy = true
        bytesDone = 0
        bytesTotal = 0
        task = Task.detached(priority: .utility) { [weak self] in
            let files = listFiles(root)
            await MainActor.run {
                guard let self else { return }
                self.items = files.map { Item(file: $0) }
                self.shoots = shootGroups(files.map(\.date))
            }
            // Steg 1: namn, storlek och stickprov. Kartan ritas på sekunder, med svaga linjer tills allt är jämfört.
            let cands = candidates(of: files)
            // shortcut: om en annan disk med samma namn sitter i på samma plats räknas filerna där som inkopplade; namnet avgör.
            let offline = offlineDisks(mounted: indexableDisks()).map { $0.root.standardizedFileURL.path + "/" }
            let isOffline = { (u: URL) in let p = u.standardizedFileURL.path; return offline.contains { p.hasPrefix($0) } }
            let gone = discardedKeys()
            let none = { (f: CardFile) -> Status in gone.contains(discardKey(f)) ? .discarded : .missing }
            let full = await MainActor.run { () -> Bool in self?.progressStart = Date(); return self?.fullCheck ?? false }
            var matches: [[URL]] = []
            var pending: [(Int, Status, [URL])] = []
            for (i, f) in files.enumerated() {
                if Task.isCancelled { return }
                let m = sameSize(as: f, among: cands[f.url.lastPathComponent] ?? [], cardRoot: root).filter { samplesMatch(f.url, $0, size: f.size) }
                // Urkopplade diskar: listan har redan samma namn och storlek, mer går inte att läsa förrän disken sitter i.
                let away = (cands[f.url.lastPathComponent] ?? []).filter(isOffline)
                matches.append(m)
                let st: Status = m.first.map { full ? .verifying($0) : .found($0) } ?? away.first.map { .found($0) } ?? none(f)
                pending.append((i, st, m + away))
                // Uppdatera kartan i omgångar, så att en stor disk fylls på medan man tittar.
                if pending.count == 25 || i == files.count - 1 {
                    let batch = pending
                    pending = []
                    await MainActor.run {
                        guard let self else { return }
                        for (j, st, c) in batch where j < self.items.count { self.items[j].status = st; self.items[j].copies = c }
                        self.checked = i + 1
                    }
                }
            }
            let hist = copyHistory(zip(files, matches).filter { $0.1.isEmpty }.map(\.0))
            await MainActor.run {
                guard let self else { return }
                self.history = hist
                if full { self.checked = 0 }
                self.bytesTotal = full ? zip(files, matches).filter { !$0.1.isEmpty }.reduce(0) { $0 + $1.0.size } : 0
                self.progressStart = Date()
            }
            // Steg 2, bara vid full kontroll: byte för byte.
            for (i, f) in files.enumerated() where full && !matches[i].isEmpty {
                // shortcut: avbrott märks först mellan filer, så en stor film läses klart först.
                if Task.isCancelled { return }
                let hit = verifyBackup(of: f, among: matches[i]) { n in Task { @MainActor in self?.bytesDone += Int64(n) } }
                await MainActor.run {
                    guard let self, i < self.items.count else { return }
                    self.items[i].status = hit.map { .found($0) } ?? none(f)
                    self.checked += 1
                }
            }
            await MainActor.run { self?.busy = false }
        }
    }

    /// Kopierar de valda filerna som bara finns på kortet till `folder`, med eller utan en undermapp per inspelningsdag.
    /// `anyStatus`: kopierar även filer som redan finns på en annan disk, när du själv har dragit dem hit.
    func copyMissing(_ only: Set<URL>, to folder: URL, byDate: Bool, withCable: Bool = true, anyStatus: Bool = false) {
        // shortcut: kamerans undermappar plattas ut; om två filer hamnar på samma ställe med samma namn markeras den andra som misslyckad i stället för att skrivas över.
        let todo = items.enumerated().filter { (anyStatus || $0.element.status == .missing) && only.contains($0.element.file.url) }.map { i, it in
            (i, it.file, (byDate ? folder.appendingPathComponent(dayString(it.file.date)) : folder).appendingPathComponent(it.file.url.lastPathComponent))
        }
        runCopies(todo + (withCable && !anyStatus ? forwardJobs() : []), showing: folder)
    }

    /// Kabeln mellan två diskar, och fönstret som öppnas när den släpps.
    @Published var forward: Forward?
    @Published var cable: (from: String, to: String)?
    /// Valen i bubblan, sparade här så att de finns kvar om bubblan stängs medan mappväljaren är öppen.
    @Published var cableFolder: URL?
    @Published var cableLayout: Forward.Layout = .mirror
    @Published var cableInclude = false

    /// Kortfiler som finns både på `from` och på `to`: kopian på `from` och den på `to`.
    func overlap(from: Disk, to: Disk) -> [(src: URL, dst: URL)] {
        let a = from.root.standardizedFileURL.path + "/", b = to.root.standardizedFileURL.path + "/"
        return items.compactMap { it in
            guard let s = it.copies.first(where: { $0.standardizedFileURL.path.hasPrefix(a) }),
                  let d = it.copies.first(where: { $0.standardizedFileURL.path.hasPrefix(b) }) else { return nil }
            return (s, d)
        }
    }
    @Published var copyDone = 0
    @Published var copyTotal = 0

    /// Kortfiler vars kopia ligger på kabelns källdisk men som inte finns någonstans på måldisken.
    /// Kopieras från kortet, som är originalet, till platsen kabeln anger.
    func forwardJobs(_ f: Forward? = nil) -> [(Int, CardFile, URL)] {
        guard let f = f ?? forward,
              let src = disks.first(where: { $0.id == f.from })?.disk, let dst = disks.first(where: { $0.id == f.to })?.disk else { return [] }
        let srcRoot = src.root.standardizedFileURL.path + "/", dstRoot = dst.root.standardizedFileURL.path + "/"
        return items.enumerated().compactMap { i, it in
            guard case .found(let u) = it.status, u.standardizedFileURL.path.hasPrefix(srcRoot),
                  f.includeExisting || !it.copies.contains(where: { $0.standardizedFileURL.path.hasPrefix(dstRoot) }) else { return nil }
            let sub: String
            switch f.layout {
            case .mirror: sub = String(u.deletingLastPathComponent().standardizedFileURL.path.dropFirst(srcRoot.count))
            case .byDay: sub = dayString(it.file.date)
            case .flat: sub = ""
            }
            let dir = sub.isEmpty ? f.folder : f.folder.appendingPathComponent(sub)
            return (i, it.file, dir.appendingPathComponent(u.lastPathComponent))
        }
    }

    func copyForward() {
        guard let f = forward else { return }
        runCopies(forwardJobs(), showing: f.folder)
    }

    /// Kopierar med kontroll. Saknade filer blir kopierade eller misslyckade; filer som kopieras vidare
    /// finns redan säkert på en disk, så de behåller sin status och ett fel visas i stället efteråt.
    private func runCopies(_ todo: [(Int, CardFile, URL)], showing folder: URL) {
        guard !todo.isEmpty else { return }
        busy = true
        copyingTo = folder
        thumbs = []
        bytesDone = 0
        bytesTotal = todo.reduce(0) { $0 + $1.1.size }
        copyDone = 0
        copyTotal = todo.count
        progressStart = Date()
        loadThumbs(todo.prefix(12).map { $0.1.url }) { self.thumbs.append($0) }
        // Användaren väntar på kopieringen. Med lägre prioritet stryper macOS läsningen.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var copied: [URL] = []
            var forwardErrors: [String] = []
            // Även vid avbrott ska det som hann kopieras in i disklistan.
            defer { addToIndex(copied); logCopies(copied); Task { @MainActor in self?.refreshDisks() } }
            for (i, f, target) in todo {
                if Task.isCancelled { return }
                var error: String?
                do { try copyVerified(f.url, to: target); copied.append(target) }
                catch let e { error = e.localizedDescription }
                let ok = error == nil
                let isMissing = await MainActor.run { () -> Bool in
                    guard let self, i < self.items.count else { return false }
                    let missing = self.items[i].status == .missing
                    if missing { self.items[i].status = error.map { .failed($0) } ?? .copied(target) }
                    else if ok { self.items[i].copies.append(target) }
                    self.bytesDone += f.size
                    self.copyDone += 1
                    return missing
                }
                if let error, !isMissing { forwardErrors.append("\(f.url.lastPathComponent): \(error)") }
            }
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                self.copyingTo = nil
                if self.forward != nil && self.forwardJobs().isEmpty { self.forward = nil }
                if !forwardErrors.isEmpty {
                    let a = NSAlert()
                    a.messageText = L("\(forwardErrors.count) files could not be copied along the cable", "\(forwardErrors.count) filer kunde inte kopieras längs kabeln")
                    a.informativeText = L("They are still on the card and on the source disk.\n\n", "De finns fortfarande kvar på kortet och på källdisken.\n\n") + forwardErrors.prefix(8).joined(separator: "\n")
                    a.runModal()
                }
            }
        }
    }

    /// Miniatyrer för kortet och för linjen medan filerna kopieras.
    func loadThumbs(_ urls: [URL], add: @escaping (NSImage) -> Void) {
        Task {
            for url in urls {
                let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                    add(rep.nsImage)
                }
            }
        }
    }

    // MARK: Diskregister

    var indexing: Bool { disks.contains { $0.progress != nil } }

    func refreshDisks() {
        let running = Dictionary(uniqueKeysWithValues: disks.compactMap { r in r.progress.map { (r.id, $0) } })
        disks = allDisks().map { d in
            let info = indexInfo(d)
            let cap = try? d.root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let fill = cap?.volumeTotalCapacity.flatMap { total in
                cap?.volumeAvailableCapacity.map { total > 0 ? 1 - Double($0) / Double(total) : 0 }
            }
            return DiskRow(disk: d, count: info?.count, date: info?.date, progress: running[d.key], fill: fill)
        }
    }

    /// Alla diskar får en lista; Spotlight används bara som snabbsvar medan listorna saknas.
    var listDisks: [DiskRow] { disks.filter { !$0.disk.offline } }

    /// Skannar diskarna samtidigt; de är olika enheter (t.ex. Macen och NAS:en) och stör inte varandra.
    /// `active`: du tryckte själv på knappen, så skanningen får gå i normal takt i stället för att bromsas av macOS.
    func index(_ list: [Disk], active: Bool = false) {
        guard indexTask == nil, !list.isEmpty else { return }
        let priority: TaskPriority = active ? .utility : .background
        indexTask = Task.detached(priority: priority) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for d in list {
                    group.addTask(priority: priority) {
                        await MainActor.run { self?.setProgress(d.key, 0) }
                        _ = try? buildIndex(d) { n in Task { @MainActor in self?.setProgress(d.key, n) } }
                        await MainActor.run { self?.setProgress(d.key, nil); self?.refreshDisks() }
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.indexTask = nil
                // Nya listor kan hitta filer som saknades nyss, så kolla kortet igen.
                if let card = self.card, !self.busy { self.scan(card) }
            }
        }
    }

    /// Uppdaterar i bakgrunden de listor som är äldre än 12 timmar. Diskar som aldrig skannats väntar på knappen.
    func autoIndex() {
        index(listDisks.filter { $0.date.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? false }.map(\.disk))
    }

    private func setProgress(_ key: String, _ n: Int?) {
        if let i = disks.firstIndex(where: { $0.id == key }) { disks[i].progress = n }
    }

    /// Kortet eller disken är en hel volym under /Volumes, inte en vald mapp, och kan matas ut.
    var canEject: Bool {
        guard let card, card.path.hasPrefix("/Volumes/") else { return false }
        return (try? card.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// Kör om kollen av kortet när en disk kommit eller gått, men aldrig mitt i en kopiering eller formatering.
    func recheck() {
        guard let card, copyingTo == nil, !formatting, FileManager.default.fileExists(atPath: card.path) else { return }
        scan(card)
    }

    /// Bara hela flyttbara kort (SD-kort och liknande), aldrig interna diskar, vanliga USB-diskar, mappar eller NAS.
    var canFormat: Bool {
        guard canEject, let card, copyingTo == nil, !formatting,
              let v = try? card.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey]) else { return false }
        return v.volumeIsInternal != true && v.volumeIsRemovable == true && v.volumeIsLocal == true
    }
    @Published var formatting = false

    /// Formaterar kortet. Det enda i appen som tar bort något för gott, så vyn kräver en bekräftelse först.
    /// Sedan matas kortet ut, så att det inte kommer in i appen igen.
    func formatCard() {
        guard let card, canFormat else { return }
        task?.cancel()
        busy = false
        formatting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try formatVolume(card) }
            let ejectError = (try? result.get()).flatMap(ejectDevice)
            DispatchQueue.main.async {
                self.formatting = false
                if case .success = result {
                    self.card = nil
                    self.items = []; self.shoots = []
                    if let ejectError {
                        let a = NSAlert()
                        a.messageText = L("\(card.lastPathComponent) is formatted but was not ejected", "\(card.lastPathComponent) är formaterat men matades inte ut")
                        a.informativeText = L("Eject it in Finder before you take it out.\n\n\(ejectError)", "Mata ut det i Finder innan du tar ut det.\n\n\(ejectError)")
                        a.runModal()
                    }
                }
                if case .failure(let error) = result {
                    let a = NSAlert()
                    a.messageText = L("Could not format \(card.lastPathComponent)", "Kunde inte formatera \(card.lastPathComponent)")
                    a.informativeText = L("The card is unchanged unless stated below. Is the card locked with the switch on its side?\n\n\(error.localizedDescription)", "Kortet är oförändrat om inget annat sägs nedan. Är kortet låst med spärren på sidan?\n\n\(error.localizedDescription)")
                    a.runModal()
                    self.scan(card)
                }
            }
        }
    }

    /// Matar ut kortet. Kollen stoppas först så att appen inte håller filer öppna; vyn töms när macOS meddelar att det är utmatat.
    func eject() {
        guard let card, canEject, copyingTo == nil else { return }
        task?.cancel()
        busy = false
        DispatchQueue.global(qos: .userInitiated).async {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: card) }
            catch {
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = L("Could not eject \(card.lastPathComponent)", "Kunde inte mata ut \(card.lastPathComponent)")
                    a.informativeText = L("An app is using the card. Quit it and try again.\n\n\(error.localizedDescription)", "Något program använder kortet. Stäng det och försök igen.\n\n\(error.localizedDescription)")
                    a.runModal()
                }
            }
        }
    }

    func pickFolder(in dir: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = dir
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose", "Välj")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseCardFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = L("Check", "Kolla")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }
}
