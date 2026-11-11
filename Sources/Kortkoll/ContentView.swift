import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Design: skiss 10 "Kontrollrum". Kortet överst, alla diskar i en rad under, lysande linjer emellan.

// Wildermarks profil: nästan svart, vitt, grått och bärnsten för det som kräver något av en.
private let bg = Color(red: 0.039, green: 0.039, blue: 0.039)
private let fg = Color.white
private let mute = Color(red: 0.612, green: 0.639, blue: 0.686)
private let panel = Color(red: 0.067, green: 0.067, blue: 0.067)
private let panelLine = Color(red: 0.149, green: 0.149, blue: 0.149)
private let cardFill = Color(red: 0.078, green: 0.078, blue: 0.078)
private let cardLine = Color(red: 0.180, green: 0.180, blue: 0.180)
private let ok = Color.white
/// Filerna finns redan på disken: linjen dit och ramen runt disken.
private let safe = Color(red: 0.133, green: 0.773, blue: 0.369)
private let accent = Color(red: 0.984, green: 0.749, blue: 0.141)
private let miss = accent
private let copy = Color(red: 0.961, green: 0.620, blue: 0.043)
private let fail = Color(red: 0.937, green: 0.267, blue: 0.267)
private let idle = Color(red: 0.612, green: 0.639, blue: 0.686).opacity(0.2)
private let onOk = Color(red: 0.039, green: 0.039, blue: 0.039)
/// Rubriktypsnittet, inbyggt i appen (Resources/Fonts). Faller tillbaka på systemtypsnittet om det saknas.
private func display(_ size: CGFloat) -> Font { .custom("Bebas Neue", size: size) }

enum LinkKind { case found, listed, verifying, missing, copying, failed, idle }

/// "BOSS 14TB / Hus" för /Volumes/BOSS 14TB/Hus, "Den här Macen / Documents" för hemmappen.
func placeLabel(_ dir: String, full: Bool = false) -> String {
    #if DEBUG
    // Demodiskarna ligger i en tillfällig mapp men ska se ut som riktiga diskar.
    if let r = dir.range(of: "/stf-demo/") { return placeLabel("/Volumes/" + dir[r.upperBound...], full: full) }
    #endif
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let disk: String
    let parts: [Substring]
    if dir.hasPrefix("/Volumes/") {
        let p = dir.dropFirst(9).split(separator: "/")
        disk = p.first.map(String.init) ?? dir
        parts = Array(p.dropFirst())
    } else {
        disk = L("This Mac", "Den här Macen")
        parts = (dir.hasPrefix(home) ? dir.dropFirst(home.count) : Substring(dir)).split(separator: "/")
    }
    return ([disk] + (full ? parts : parts.suffix(2)).map(String.init)).joined(separator: " / ")
}

/// En ruta i raden längst ner: en disk, eller en plats för filer som saknas eller misslyckades.
struct Tile: Identifiable {
    enum Kind { case disk, missing, discarded, failed }
    let id: String
    let kind: Kind
    let name: String
    let icon: String
    var row: DiskRow?
    var found = 0
    /// Den del av `found` som bara finns i listan för en urkopplad disk.
    var listed = 0
    var copying = 0
    var verifying = 0
    var count = 0
    /// Kortets filer som hör till rutan: kopiorna på disken, eller filerna på kortet för det som saknas.
    var urls: [URL] = []
    /// Sökvägarna i detaljrutan visas från här.
    var root: URL?
}

extension Model {
    /// Rutorna och linjerna från kortet till dem.
    var tiles: [Tile] {
        let source = card?.standardizedFileURL.path
        var out = disks.filter { $0.disk.root.standardizedFileURL.path != source }.map { r in
            Tile(id: r.id, kind: .disk, name: r.disk.name, icon: diskIcon(r.disk), row: r, root: r.disk.root)
        }
        // Filer på ett ställe som inte är en egen disk, t.ex. en tillfällig mapp.
        var other = Tile(id: "other", kind: .disk, name: L("Other place", "Annan plats"), icon: "folder")
        var missing = Tile(id: "?", kind: .missing, name: L("No place yet", "Ingen plats än"), icon: "questionmark", root: card)
        var culled = Tile(id: "-", kind: .discarded, name: L("Culled", "Rensade"), icon: "eye.slash", root: card)
        var failed = Tile(id: "!", kind: .failed, name: L("Could not be copied", "Kunde inte kopieras"), icon: "exclamationmark.triangle", root: card)
        let roots = out.map { $0.row!.disk.root.standardizedFileURL.path + "/" }
        func index(of u: URL) -> Int? { let p = u.standardizedFileURL.path; return roots.firstIndex { p.hasPrefix($0) } }

        for it in items {
            switch it.status {
            case .checking: continue
            case .found(let u), .copied(let u):
                // Varje disk med en kopia räknas, så att en fil som finns på två diskar syns på båda.
                var seen = Set<Int>()
                for c in [u] + it.copies {
                    if let i = index(of: c) { if seen.insert(i).inserted { out[i].found += 1; out[i].urls.append(c) } }
                }
                if seen.isEmpty { other.found += 1; other.urls.append(u) }
            case .listed(let u):
                var seen = Set<Int>()
                for c in [u] + it.copies {
                    if let i = index(of: c), seen.insert(i).inserted { out[i].found += 1; out[i].listed += 1; out[i].urls.append(c) }
                }
                if seen.isEmpty { other.found += 1; other.listed += 1; other.urls.append(u) }
            case .verifying(let u):
                if let i = index(of: u) { out[i].verifying += 1; out[i].urls.append(u) } else { other.verifying += 1; other.urls.append(u) }
            case .missing:
                if let to = copyingTo, let i = index(of: to) {
                    out[i].copying += 1
                    if let also = copyingAlso, let k = index(of: also), k != i { out[k].copying += 1 }
                } else { missing.count += 1; missing.urls.append(it.file.url) }
            case .discarded: culled.count += 1; culled.urls.append(it.file.url)
            case .failed: failed.count += 1; failed.urls.append(it.file.url)
            }
        }
        if other.found + other.verifying > 0 { out.append(other) }
        if card != nil && (missing.count > 0 || (copyingTo == nil && !busy && !items.isEmpty)) { out.append(missing) }
        if culled.count > 0 { out.append(culled) }
        if failed.count > 0 { out.append(failed) }
        return out
    }

    func diskIcon(_ d: Disk) -> String {
        if d.key == "home" { return "desktopcomputer" }
        if d.offline || d.network { return d.network ? "server.rack" : "externaldrive" }
        let local = try? d.root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
        return local == false ? "server.rack" : "externaldrive"
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var asking = false
    @State private var formatting = false
    @State private var why = false
    @State private var fullInfo = false
    @State private var cleaning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !m.listDisks.isEmpty && m.listDisks.allSatisfy({ $0.count == nil && $0.progress == nil }) { firstScan.padding(.bottom, 16) }
            Flow(tiles: m.tiles, thumbs: m.thumbs, animating: m.copyingTo != nil) { cardView }
                .frame(maxHeight: .infinity)
            footer.padding(.top, 18)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
        .ignoresSafeArea()
        .foregroundStyle(fg)
        .id(m.language)
        .sheet(isPresented: $asking) { CopyChooser(files: m.missing.map(\.file)).environmentObject(m) }
        .sheet(isPresented: $formatting) { FormatSheet().environmentObject(m) }

    }

    private var header: some View {
        let scanned = m.listDisks.filter { $0.count != nil }.count
        return HStack(spacing: 8) {
            Text(L("IN", "IN")).font(display(15)).tracking(1.5).foregroundStyle(mute)
            Spacer()
            if !m.leftovers.isEmpty && m.copyingTo == nil {
                Button { cleaning = true } label: {
                    Label(L("\(m.leftovers.count) unfinished \(m.leftovers.count == 1 ? "copy" : "copies")", "\(m.leftovers.count) \(m.leftovers.count == 1 ? "avbruten kopia" : "avbrutna kopior")"), systemImage: "trash")
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(miss)
                .padding(.trailing, 10)
                .help(L("Leftovers from interrupted copies. They take up space but are not usable files.", "Rester från avbrutna kopior. De tar plats men är inga användbara filer."))
                .confirmationDialog(L("Move \(m.leftovers.count) unfinished \(m.leftovers.count == 1 ? "copy" : "copies") to the Trash?", "Lägga \(m.leftovers.count) \(m.leftovers.count == 1 ? "avbruten kopia" : "avbrutna kopior") i papperskorgen?"), isPresented: $cleaning) {
                    Button(L("Move to Trash", "Lägg i papperskorgen"), role: .destructive) { m.trashLeftovers() }
                    Button(L("Cancel", "Avbryt"), role: .cancel) {}
                } message: {
                    Text(m.leftovers.prefix(5).map(\.lastPathComponent).joined(separator: "\n"))
                }
            }
            Toggle(L("Full check", "Full kontroll"), isOn: $m.fullCheck)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11, weight: .medium)).foregroundStyle(mute)
                .help(L("Compares every file byte by byte. Safest, but reads the whole card and every copy.", "Jämför varje fil byte för byte. Säkrast, men läser hela kortet och alla kopior."))
            Button { fullInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(mute)
                .help(L("What is Full check?", "Vad är Full kontroll?"))
                .accessibilityLabel(L("What is Full check?", "Vad är Full kontroll?"))
                .popover(isPresented: $fullInfo) { FullCheckInfo() }
                .padding(.trailing, 10)
            Text(L("Disks · \(scanned) of \(m.disks.count) scanned", "Diskar · \(scanned) av \(m.disks.count) skannade")).font(.system(size: 11, weight: .medium)).foregroundStyle(mute)
            Button { why.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.plain).foregroundStyle(mute)
                .help(L("How to read WilderLoader", "Så läser du WilderLoader"))
                .accessibilityLabel(L("How to read WilderLoader", "Så läser du WilderLoader"))
                .popover(isPresented: $why) { HelpGuide() }
            Picker(L("Language", "Språk"), selection: $m.language) {
                Text("EN").tag(Lang.en)
                Text("SV").tag(Lang.sv)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            .help(L("Language", "Språk"))
            if !m.indexing && scanned > 0 {
                Button(L("Rescan all", "Skanna om alla")) { m.index(m.listDisks.map(\.disk), active: true) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(ok)
                    .help(L("Rebuild the lists for all disks from scratch", "Gör om listorna för alla diskar från grunden"))
            }
        }
        .padding(.bottom, 12)
    }

    /// Visas tills någon disk har skannats: första skanningen gör varje koll snabb sedan.
    private var firstScan: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 22)).foregroundStyle(ok)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Start by scanning your disks", "Börja med att skanna dina diskar")).font(.system(size: 14, weight: .bold))
                Text(L("WilderLoader makes a list of every photo and video on each disk. It takes a while the first time; after that, checking a card takes seconds.", "WilderLoader gör en lista över alla bilder och filmer på varje disk. Det tar en stund första gången, sedan går kollen av ett kort på några sekunder."))
                    .font(.system(size: 12)).foregroundStyle(mute).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { m.index(m.listDisks.map(\.disk), active: true) } label: {
                Text(L("Scan all disks", "Skanna alla diskar")).font(.system(size: 13, weight: .bold)).foregroundStyle(onOk)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 4).fill(ok))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 5).fill(ok.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(ok.opacity(0.35)))
    }

    @ViewBuilder private var cardView: some View {
        if let card = m.card {
            let dirs = Set(m.items.map { ($0.file.rel as NSString).deletingLastPathComponent }).filter { !$0.isEmpty }
            let place = dirs.count == 1 ? (dirs.first! as NSString).lastPathComponent : dirs.isEmpty ? L("The card", "Kortet") : L("\(dirs.count) folders", "\(dirs.count) mappar")
            let ring = !m.failed.isEmpty ? fail : !m.missing.isEmpty ? miss : m.busy ? mute : ok
            HStack(spacing: 14) {
                Image(systemName: m.disks.contains { $0.disk.root.standardizedFileURL.path == card.standardizedFileURL.path } ? "externaldrive" : "sdcard")
                    .font(.system(size: 24, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.lastPathComponent).font(display(23)).tracking(0.8).lineLimit(1)
                    Text(m.busy && m.copyingTo == nil ? (m.bytesTotal > 0 ? L("Checking byte by byte…", "Kontrollerar byte för byte…") : L("Looking…", "Letar…")) : L("\(place) · \(m.items.count) files", "\(place) · \(m.items.count) filer"))
                        .font(.system(size: 12)).foregroundStyle(mute).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 8)
                SourceMenu { Text(L("Change…", "Byt…")).font(.system(size: 11, weight: .semibold)) }
                if m.canEject {
                    Button { m.eject() } label: { Image(systemName: "eject.fill").font(.system(size: 12)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(fg)
                        .disabled(m.copyingTo != nil)
                        .help(m.copyingTo != nil ? L("Wait until copying is done", "Vänta tills kopieringen är klar") : L("Eject \(m.card?.lastPathComponent ?? "the card")", "Mata ut \(m.card?.lastPathComponent ?? "kortet")"))
                        .accessibilityLabel(L("Eject", "Mata ut"))
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 400, height: 68)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(card) }
            .help(L("Open \(card.lastPathComponent) in Finder", "Öppna \(card.lastPathComponent) i Finder"))
            .background(RoundedRectangle(cornerRadius: 4).fill(cardFill))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ring.opacity(0.7), lineWidth: 1.2))
        } else {
            VStack(spacing: 5) {
                Text(L("Insert a memory card", "Stoppa i ett minneskort")).font(display(22)).tracking(0.8)
                SourceMenu {
                    Text(L("…or check a disk or folder  ⌄", "…eller kolla en disk eller mapp  ⌄")).font(.system(size: 12))
                }
            }
            .frame(width: 320, height: 68)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(cardLine, style: .init(lineWidth: 1.2, dash: [5, 4])))
        }
    }

    private var footer: some View {
        let (text, color) = status()
        return VStack(alignment: .leading, spacing: 10) {
            if m.busy && m.copyingTo == nil && m.bytesTotal == 0 && m.items.count > 0 {
                progressBar(color, done: Double(m.checked), total: Double(m.items.count), label: L("\(m.checked.formatted()) of \(m.items.count.formatted()) files", "\(m.checked.formatted()) av \(m.items.count.formatted()) filer"))
            } else if m.busy && m.bytesTotal > 0 {
                let gb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
                progressBar(color, done: Double(m.bytesDone), total: Double(m.bytesTotal), label: L("\(gb(m.bytesDone)) of \(gb(m.bytesTotal))", "\(gb(m.bytesDone)) av \(gb(m.bytesTotal))"))
            }
            footerRow(text, color)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(panelLine).frame(height: 1) }
    }

    private func progressBar(_ color: Color, done: Double, total: Double, label: String) -> some View {
        let f = min(1, done / max(total, 1))
        let elapsed = Date().timeIntervalSince(m.progressStart)
        let left = f > 0.02 && elapsed > 3 ? elapsed / f - elapsed : nil
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(idle)
                    Capsule().fill(color).frame(width: g.size.width * f)
                }
            }
            .frame(height: 6)
            HStack {
                Text(label).monospacedDigit()
                Spacer()
                if let left { Text(L("about \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left", "ca \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) kvar")).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(mute)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(L("\(Int(f * 100)) percent", "\(Int(f * 100)) procent"))
    }

    private func footerRow(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color == mute ? fg : color)
            Spacer()
            let fwd = m.busy || m.forward == nil ? 0 : m.forwardJobs().count
            let total = m.missing.count + fwd
            if fwd > 0, let f = m.forward {
                Text(L("+ \(fwd.formatted()) also to \(m.disks.first { $0.id == f.to }?.disk.name ?? "")", "+ \(fwd.formatted()) även till \(m.disks.first { $0.id == f.to }?.disk.name ?? "")"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ok)
            }
            if !m.busy && total > 0 {
                Button { if m.missing.isEmpty { m.copyForward() } else { asking = true } } label: {
                    Text(L("Copy \(total.formatted()) \(total == 1 ? "file" : "files")", "Kopiera \(total.formatted()) \(total == 1 ? "fil" : "filer")")).font(.system(size: 13, weight: .bold)).foregroundStyle(onOk)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ok))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            if m.formatting {
                ProgressView().controlSize(.small)
                Text(L("Formatting…", "Formaterar…")).font(.system(size: 13, weight: .semibold))
            } else if m.formatReady && m.canFormat {
                Button { formatting = true } label: {
                    Text(L("✓ Format the card…", "✓ Formatera kortet…")).font(.system(size: 13, weight: .bold)).foregroundStyle(ok)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ok))
                }
                .buttonStyle(.plain)
                .help(L("Everything on the card is on another disk and fully checked", "Allt på kortet finns på en annan disk och är fullt kontrollerat"))
            } else if m.formatReady {
                Text(L("✓ Safe to format", "✓ Kan formateras")).font(.system(size: 13, weight: .bold)).foregroundStyle(ok)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ok))
            } else {
                if m.allSafe && m.unverified > m.awayOnly {
                    Button { m.fullCheck = true } label: {
                        Text(L("Run Full check", "Kör Full kontroll")).font(.system(size: 13, weight: .bold)).foregroundStyle(ok)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ok))
                    }
                    .buttonStyle(.plain)
                    .help(L("Compares every file with its copy before you format", "Jämför varje fil med kopian innan du formaterar"))
                }
                if !m.busy && !m.otherFiles.isEmpty {
                    Button(L("Show them", "Visa dem")) { NSWorkspace.shared.activateFileViewerSelecting(m.otherFiles) }
                        .buttonStyle(.borderless).foregroundStyle(miss).font(.system(size: 12, weight: .semibold))
                }
                if !m.busy && m.canFormat && (!m.items.isEmpty || !m.otherFiles.isEmpty) {
                    Button(L("Format anyway…", "Formatera ändå…")) { formatting = true }
                        .buttonStyle(.borderless).foregroundStyle(mute).font(.system(size: 12))
                        .help(L("Not everything is confirmed to be on another disk", "Allt är inte bekräftat på en annan disk"))
                }
            }
        }
        .frame(minHeight: 36)
    }

    private func status() -> (String, Color) {
        let total = m.items.count
        if m.card == nil { return (L("Waiting for a memory card", "Väntar på ett minneskort"), mute) }
        if let to = m.copyingTo {
            return (L("Copying \(min(m.copyDone + 1, m.copyTotal)) of \(m.copyTotal) → \(placeLabel(to.path))", "Kopierar \(min(m.copyDone + 1, m.copyTotal)) av \(m.copyTotal) → \(placeLabel(to.path))"), copy)
        }
        if m.busy && m.bytesTotal > 0 { return (L("Full check · \(m.checked) of \(m.items.count { if case .verifying = $0.status { return true }; return false } + m.checked) files", "Full kontroll · \(m.checked) av \(m.items.count { if case .verifying = $0.status { return true }; return false } + m.checked) filer"), ok) }
        if m.busy { return (L("Looking for the files on other disks…", "Letar efter filerna på andra diskar…"), mute) }
        if !m.failed.isEmpty { return (L("\(m.failed.count) files could not be copied", "\(m.failed.count) filer kunde inte kopieras"), fail) }
        if !m.missing.isEmpty {
            // En oskannad disk kan ha filerna, så säg det hellre än att låta det se säkert ut.
            let unscanned = m.listDisks.filter { $0.count == nil }.count
            let note = unscanned > 0 ? L(" · \(unscanned) \(unscanned == 1 ? "disk" : "disks") not scanned", " · \(unscanned) \(unscanned == 1 ? "disk" : "diskar") inte skannade") : ""
            return (L("\(m.missing.count) \(m.missing.count == 1 ? "file has" : "files have") no place yet\(note)", "\(m.missing.count) \(m.missing.count == 1 ? "fil" : "filer") har ingen plats än\(note)"), miss)
        }
        if !m.otherFiles.isEmpty {
            let kinds = describeKinds(m.otherFiles)
            return (L("Other files on the card can't be checked: \(kinds)", "Andra filer på kortet går inte att kontrollera: \(kinds)"), miss)
        }
        if total == 0 { return (L("The card is empty", "Kortet är tomt"), mute) }
        if m.awayOnly > 0 { return (L("\(m.awayOnly) \(m.awayOnly == 1 ? "file is" : "files are") only listed on a disconnected disk · connect it to check", "\(m.awayOnly) \(m.awayOnly == 1 ? "fil finns" : "filer finns") bara i listan för en urkopplad disk · koppla in den för att kontrollera"), miss) }
        if m.unverified > 0 { return (L("Everything is there · name, size and samples match · not fully checked", "Allt finns · namn, storlek och stickprov stämmer · inte fullt kontrollerat"), ok) }
        return (L("Everything is there and fully checked", "Allt finns och är fullt kontrollerat"), ok)
    }

}

/// En fotografering under kortet: miniatyr, datum och hur mycket som saknas. Klick visar filerna markerade i Finder.
struct ShootStack: View {
    let group: [Int]
    let all: [[Int]]
    @EnvironmentObject var m: Model
    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        let files = m.items(in: group)
        let dates = files.map(\.file.date)
        let first = dates.min() ?? Date(), last = dates.max() ?? first
        let missing = files.count { $0.status == .missing }
        // Flera fotograferingar samma dag får samma datum, så tiden skiljer dem åt.
        let sameDay = all.contains { $0 != group && m.items(in: $0).first.map { Calendar.current.isDate($0.file.date, inSameDayAs: first) } == true }
        Button { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.file.url)) } label: {
            VStack(spacing: 2) {
                Group {
                    if let thumb { Image(nsImage: thumb).resizable().scaledToFill() } else { cardFill }
                }
                .frame(maxWidth: .infinity).frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(hovering ? fg : missing > 0 ? miss : panelLine, lineWidth: hovering || missing > 0 ? 1.5 : 1))
                .padding(.bottom, 3)
                Text(shootDate(first, last)).font(display(18)).tracking(0.6).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(missing > 0 ? miss : fg)
                Text(sameDay ? "\(shootTime(first))–\(shootTime(last)) · \(count(missing))" : count(missing))
                    .font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(missing > 0 ? miss : mute)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Show these \(group.count) files in Finder", "Visa de här \(group.count) filerna i Finder"))
        .task(id: group.first) {
            thumb = nil
            let files = m.items(in: group)
            guard !files.isEmpty else { return }
            m.loadThumbs([files[files.count / 2].file.url]) { thumb = $0 }
        }
    }

    private func count(_ missing: Int) -> String {
        missing > 0 ? L("\(missing) missing", "\(missing) saknas") : L("\(group.count) files", "\(group.count) filer")
    }

    private func shootTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH"
        return f.string(from: d)
    }

    private func shootDate(_ a: Date, _ b: Date) -> String {
        let f = DateFormatter()
        f.locale = appLang.locale
        f.dateFormat = "d MMM"
        return Calendar.current.isDate(a, inSameDayAs: b) ? f.string(from: a) : "\(f.string(from: a))–\(f.string(from: b))"
    }
}

/// En kabel från en port. Som Shape animeras slutpunkten när kabeln drar sig tillbaka.
private struct Cable: Shape {
    let start: CGPoint
    var end: CGPoint
    /// Riktningen kabeln går in i slutpunkten: -1 uppifrån, 1 underifrån.
    let endBend: CGFloat
    var animatableData: CGPoint.AnimatableData {
        get { end.animatableData }
        set { end.animatableData = newValue }
    }
    func path(in _: CGRect) -> Path {
        // Böjen krymper med längden, så att kabeln blir till en punkt när den är hemma.
        let bend = min(60, hypot(end.x - start.x, end.y - start.y) / 2)
        var p = Path()
        p.move(to: start)
        p.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y + endBend * bend))
        return p
    }
}

/// Kortet överst, rutorna längst ner och linjerna emellan.
struct Flow<Card: View>: View {
    let tiles: [Tile]
    let thumbs: [NSImage]
    let animating: Bool
    @ViewBuilder let card: () -> Card
    @EnvironmentObject var m: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragFrom: Int?
    @State private var pulse = false
    @State private var dragPoint: CGPoint = .zero
    @State private var dragShoot: Int?
    @State private var shootCopy: ShootCopy?
    @State private var mapTile: Tile?
    @State private var copyAfterMap: Disk?
    @State private var retracting = false
    /// Nollställs av systemet även när ett drag avbryts, till exempel av ett högerklick, då onEnded aldrig körs.
    @GestureState private var liveDrag = false

    /// Filerna från en fotografering som har dragits till en disk.
    private struct ShootCopy: Identifiable {
        let id = UUID()
        let files: [CardFile]
        let disk: Disk
        let extra: Bool
        let start: URL
    }

    private let cardH: CGFloat = 68, tileH: CGFloat = 112, gap: CGFloat = 12, cableH: CGFloat = 70
    /// Luckan under kortet, själva fotograferingen och utrymmet ner till porten.
    private let shootGap: CGFloat = 16, shootBody: CGFloat = 98, shootH: CGFloat = 16 + 98 + 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // shortcut: rutorna delar på bredden; med väldigt många diskar blir de smala, byt då till en rullbar rad.
            let n = CGFloat(max(tiles.count, 1)), tw = (w - gap * (n - 1)) / n
            let tileX = { (i: Int) in CGFloat(i) * (tw + gap) + tw / 2 }
            let ports = m.card != nil && !m.busy && !m.items.isEmpty
            let shown = fitShoots(m.shoots, to: Int(w / 76))
            let shootW = min(120, w / CGFloat(max(shown.count, 1)))
            let shootX = { (k: Int) in w / 2 + (CGFloat(k) - CGFloat(shown.count - 1) / 2) * shootW }
            let shootY = cardH + (shown.isEmpty ? 0 : shootH)
            let tileTop = h - tileH - (ports ? cableH : 0)
            let portY = tileTop + tileH
            let origin = dragFrom.map { CGPoint(x: tileX($0), y: portY) } ?? dragShoot.map { CGPoint(x: shootX($0), y: shootY) }
            // Disken vars plupp en punkt är nära nog att fästa i.
            let plug = { (p: CGPoint) -> Int? in
                guard p.y > tileTop - 40, p.y < tileTop + tileH else { return nil }
                return tiles.indices.first { abs(p.x - tileX($0)) < tw / 2 + gap / 2 && tiles[$0].kind == .disk && tiles[$0].row?.disk.offline == false }
            }
            let pending = m.cable.flatMap { c in
                tiles.firstIndex { $0.id == c.from }.flatMap { i in tiles.firstIndex { $0.id == c.to }.map { (i, $0) } }
            }
            let fwd = m.forward.flatMap { f in
                tiles.firstIndex { $0.id == f.from }.flatMap { i in tiles.firstIndex { $0.id == f.to }.map { (f, i, $0) } }
            }

            let routes = linkList().flatMap { l in sources(of: l, in: shown).map { ($0, l) } }

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: !animating || reduceMotion)) { tl in
                    Canvas { ctx, _ in
                        for (k, l) in routes {
                            let a = CGPoint(x: shown.isEmpty ? w / 2 : shootX(k), y: shootY)
                            let b = CGPoint(x: tileX(l.tile) + (l.kind == .copying ? 18 : 0), y: tileTop)
                            let mid = (a.y + b.y) / 2
                            var path = Path()
                            path.move(to: a)
                            path.addCurve(to: b, control1: CGPoint(x: a.x, y: mid), control2: CGPoint(x: b.x, y: mid))
                            let (color, style) = look(l.kind)
                            ctx.stroke(path, with: .color(color), style: style)

                            // Miniatyrer som åker längs linjen medan filerna kopieras.
                            guard l.kind == .copying, animating, !reduceMotion else { continue }
                            let time = tl.date.timeIntervalSinceReferenceDate
                            for j in 0..<3 {
                                let t = CGFloat((time * 0.42 + Double(j) / 3).truncatingRemainder(dividingBy: 1))
                                let pt = bezier(a, CGPoint(x: a.x, y: mid), CGPoint(x: b.x, y: mid), b, t)
                                let rect = CGRect(x: pt.x - 15, y: pt.y - 11, width: 30, height: 22)
                                var c = ctx
                                c.opacity = Double(min(1, min(t, 1 - t) * 6))
                                let shape = Path(roundedRect: rect, cornerRadius: 4)
                                c.stroke(shape, with: .color(.white), lineWidth: 2)
                                c.clip(to: shape)
                                let cycle = Int(time * 0.42 + Double(j) / 3)
                                if thumbs.isEmpty { c.fill(shape, with: .color(copy.opacity(0.6))) }
                                else { c.draw(Image(nsImage: thumbs[(cycle * 3 + j) % thumbs.count]).resizable(), in: rect) }
                            }
                        }
                    }
                }
                .accessibilityHidden(true)

                card()
                    .frame(width: w, height: cardH)

                ForEach(Array(shown.enumerated()), id: \.offset) { k, group in
                    ShootStack(group: group, all: shown)
                        .frame(width: shootW - 10, height: shootBody)
                        .position(x: shootX(k), y: cardH + shootGap + shootBody / 2)
                }

                Text(L("OUT", "UT")).font(display(15)).tracking(1.5).foregroundStyle(mute)
                    .offset(y: tileTop - 24)

                ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                    TileView(tile: t)
                        .frame(width: tw, height: tileH)
                        .offset(x: tileX(i) - tw / 2, y: tileTop)
                }

                if ports {
                    // Kabeln under rutorna: samma bildspråk som linjerna ovanför, speglat nedåt.
                    Canvas { ctx, _ in
                        func cable(_ a: CGPoint, _ b: CGPoint) -> Path {
                            var p = Path()
                            p.move(to: a)
                            p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + 52), control2: CGPoint(x: b.x, y: b.y + 52))
                            return p
                        }
                        let style = StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        if let (_, i, j) = fwd {
                            let p = cable(CGPoint(x: tileX(i), y: portY), CGPoint(x: tileX(j), y: portY))
                            ctx.stroke(p, with: .color(accent), style: style)
                        }
                        if let (i, j) = pending, fwd.map({ $0.1 != i || $0.2 != j }) ?? true {
                            ctx.stroke(cable(CGPoint(x: tileX(i), y: portY), CGPoint(x: tileX(j), y: portY)),
                                       with: .color(copy), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    let target = dragShoot != nil && !retracting ? plug(dragPoint) : nil
                    // Pluppar ovanpå diskarna, där en kabel från kortet fäster.
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                        if t.kind == .disk, t.row?.disk.offline == false {
                            let on = target == i
                            Circle()
                                .fill(on ? accent : bg)
                                .overlay(Circle().stroke(dragShoot != nil ? accent : mute, lineWidth: 1.5))
                                .frame(width: on ? 14 : 10, height: on ? 14 : 10)
                                .padding(6)
                                .contentShape(Circle())
                                .position(x: tileX(i), y: tileTop)
                                .onTapGesture { if t.found > 0 { mapTile = t } }
                                .help(t.found > 0 ? L("See where the card's files are on \(t.name)", "Se var kortets filer ligger på \(t.name)") : "")
                                .accessibilityLabel(L("Plug on \(t.name)", "Plupp på \(t.name)"))
                                .accessibilityAddTraits(.isButton)
                        }
                    }

                    if let origin {
                        Cable(start: origin, end: target.map { CGPoint(x: tileX($0), y: tileTop) } ?? dragPoint, endBend: dragShoot != nil ? -1 : 1)
                            .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: w, height: h)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                        if t.kind == .disk && t.row != nil {
                            let lit = fwd.map { $0.1 == i || $0.2 == i } ?? false || dragFrom == i
                            let hint = m.forward == nil && dragFrom == nil && t.found > 0 && !reduceMotion
                            Circle()
                                .fill(lit ? accent : bg)
                                .background(Circle().stroke(accent, lineWidth: 1.5).scaleEffect(pulse ? 2.4 : 1).opacity(hint ? (pulse ? 0 : 0.8) : 0))
                                .overlay(Circle().stroke(lit ? accent : mute, lineWidth: 1.5))
                                .frame(width: 12, height: 12)
                                .padding(8)
                                .contentShape(Circle())
                                .position(x: tileX(i), y: portY)
                                .help(t.found > 0 ? L("Drag to another disk to put these \(t.found) files there too", "Dra till en annan disk för att lägga de här \(t.found) filerna där också") : L("Drag here from a disk that has files from the card", "Dra hit från en disk som har filer från kortet"))
                                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("flow"))
                                    .updating($liveDrag) { _, live, _ in live = true }
                                    .onChanged { v in
                                        guard t.found > 0, !retracting else { return }
                                        dragFrom = i
                                        dragPoint = v.location
                                    }
                                    .onEnded { v in
                                        guard t.found > 0, !retracting else { return }
                                        if v.location.y > tileTop - 10,
                                           let j = tiles.indices.first(where: { abs(v.location.x - tileX($0)) < tw / 2 + gap / 2 }),
                                           j != i, tiles[j].kind == .disk, let row = tiles[j].row, !row.disk.offline {
                                            m.cableFolder = nil
                                            m.cableLayout = .mirror
                                            m.cableInclude = false
                                            m.cable = (t.id, tiles[j].id)
                                            dragFrom = nil
                                        } else { retract(to: CGPoint(x: tileX(i), y: portY)) }
                                    })
                                .accessibilityLabel(L("Port on \(t.name)", "Port på \(t.name)"))
                        }
                    }

                    ForEach(Array(shown.enumerated()), id: \.offset) { k, group in
                        let hasMissing = m.items(in: group).contains { $0.status == .missing }
                        Circle()
                            .fill(hasMissing || dragShoot == k ? accent : bg)
                            .overlay(Circle().stroke(hasMissing || dragShoot == k ? accent : mute, lineWidth: 1.5))
                            .frame(width: 12, height: 12)
                            .padding(8)
                            .contentShape(Circle())
                            .position(x: shootX(k), y: shootY)
                            .help(L("Drag to a disk to copy these files there", "Dra till en disk för att kopiera de här filerna dit"))
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("flow"))
                                .updating($liveDrag) { _, live, _ in live = true }
                                .onChanged { v in
                                    guard !retracting else { return }
                                    dragShoot = k
                                    dragPoint = v.location
                                }
                                .onEnded { v in
                                    guard !retracting else { return }
                                    if let j = plug(v.location), let row = tiles[j].row {
                                        shootCopy = shootCopy(group, to: row.disk)
                                        dragShoot = nil
                                    } else { retract(to: CGPoint(x: shootX(k), y: shootY)) }
                                })
                            .accessibilityLabel(L("Port on the shoot", "Port på fotograferingen"))
                    }

                    if fwd == nil && pending == nil && dragFrom == nil && tiles.contains(where: { $0.found > 0 }) {
                        Label(L("Drag from the dot under a disk to another disk to put its files there too", "Dra från pricken under en disk till en annan disk för att lägga filerna där också"), systemImage: "hand.draw")
                            .font(.system(size: 11)).foregroundStyle(mute)
                            .fixedSize()
                            // Under kabelns lägsta punkt (ca 40 pt under portarna), så att linjen aldrig går genom texten.
                            .position(x: w / 2, y: portY + 58)
                            .allowsHitTesting(false)
                            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
                    }
                    if let (i, j) = pending, let from = tiles[i].row, let to = tiles[j].row {
                        Color.clear.frame(width: 1, height: 1)
                            .position(x: (tileX(i) + tileX(j)) / 2, y: portY + 40)
                            .popover(isPresented: Binding(get: { m.cable != nil }, set: { if !$0 { m.cable = nil } }), arrowEdge: .bottom) {
                                ForwardBubble(from: from, to: to) { m.cable = nil }.environmentObject(m)
                            }
                    }
                    if let (f, i, j) = fwd {
                        let n = m.forwardJobs().count
                        HStack(spacing: 6) {
                            Button { m.cableFolder = f.folder; m.cableLayout = f.layout; m.cableInclude = f.includeExisting; m.cable = (f.from, f.to) } label: {
                                Text(L("\(tiles[i].name) → \(tiles[j].name) · \(n.formatted()) \(n == 1 ? "file" : "files")", "\(tiles[i].name) → \(tiles[j].name) · \(n.formatted()) \(n == 1 ? "fil" : "filer")"))
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(ok)
                            }
                            .buttonStyle(.plain)
                            .help(L("Change where the files go", "Ändra vart filerna hamnar"))
                            Button { m.forward = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(mute) }
                                .buttonStyle(.plain)
                                .help(L("Remove the cable", "Ta bort kabeln"))
                                .accessibilityLabel(L("Remove the cable", "Ta bort kabeln"))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(bg))
                        .overlay(Capsule().stroke(ok, lineWidth: 1))
                        .fixedSize()
                        .position(x: (tileX(i) + tileX(j)) / 2, y: portY + 40)
                    }
                }
            }
            .coordinateSpace(name: "flow")
            .onChange(of: liveDrag) { _, live in
                if !live, let origin { retract(to: origin) }
            }
            .sheet(item: $mapTile, onDismiss: {
                if let d = copyAfterMap { copyAfterMap = nil; shootCopy = shootCopy(Array(m.items.indices), to: d) }
            }) { t in
                if let disk = t.row?.disk { DiskMapSheet(disk: disk) { copyAfterMap = disk }.environmentObject(m) }
            }
            .sheet(item: $shootCopy) { c in
                LandingSheet(files: c.files, disk: c.disk, start: c.start, extra: c.extra, anyStatus: true).environmentObject(m)
            }
        }
        .frame(minHeight: cardH + shootH + tileH + 120 + cableH)
    }

    /// Kabeln som inte fäste någonstans åker tillbaka till sin port.
    private func retract(to port: CGPoint) {
        guard !retracting else { return }
        guard !reduceMotion else { dragFrom = nil; dragShoot = nil; return }
        retracting = true
        withAnimation(.spring(duration: 0.35, bounce: 0.2), completionCriteria: .logicallyComplete) {
            dragPoint = port
        } completion: {
            dragFrom = nil
            dragShoot = nil
            retracting = false
        }
    }

    /// Det som ännu inte finns på disken. Finns allt redan där gäller draget en extra kopia av hela fotograferingen.
    private func shootCopy(_ group: [Int], to disk: Disk) -> ShootCopy {
        let root = disk.root.standardizedFileURL.path + "/"
        let on = { (u: URL) in u.standardizedFileURL.path.hasPrefix(root) }
        let items = m.items(in: group)
        let away = items.filter { it in
            if case .copied(let u) = it.status, on(u) { return false }
            return !it.copies.contains(where: on)
        }
        return ShootCopy(files: (away.isEmpty ? items : away).map(\.file), disk: disk, extra: away.isEmpty,
                         // Finns allt redan där öppnas väljaren där filerna ligger, så att du ser platsen.
                         start: away.isEmpty ? m.homes(of: items.map(\.file), on: disk).max { $0.value < $1.value }?.key ?? disk.root
                                             : m.likelyFolder(for: items.map(\.file), on: disk))
    }

    private struct Link { let tile: Int; let kind: LinkKind }

    /// Fotograferingarna en linje utgår från: de med filer som hör till linjen. Tomma linjer går från mitten.
    private func sources(of l: Link, in shown: [[Int]]) -> [Int] {
        let here = Set(tiles[l.tile].urls)
        let belongs = { (it: Item) -> Bool in
            switch (l.kind, it.status) {
            case (.found, .found(let u)), (.found, .copied(let u)), (.listed, .listed(let u)): return here.contains(u) || it.copies.contains(where: here.contains)
            case (.verifying, .verifying(let u)): return here.contains(u)
            case (.missing, .missing), (.copying, .missing), (.failed, .failed): return true
            default: return false
            }
        }
        let out = shown.indices.filter { k in m.items(in: shown[k]).contains(where: belongs) }
        return out.isEmpty ? [shown.count / 2] : out
    }

    private func linkList() -> [Link] {
        guard tiles.contains(where: { $0.found + $0.copying + $0.count > 0 }) || tiles.contains(where: { $0.kind == .missing }) else {
            return []
        }
        var out: [Link] = []
        for (i, t) in tiles.enumerated() {
            switch t.kind {
            case .missing: out.append(.init(tile: i, kind: t.count > 0 ? .missing : .idle))
            case .failed: out.append(.init(tile: i, kind: .failed))
            case .discarded: out.append(.init(tile: i, kind: .idle))
            case .disk:
                if t.found > t.listed { out.append(.init(tile: i, kind: .found)) }
                if t.listed > 0 { out.append(.init(tile: i, kind: .listed)) }
                if t.verifying > 0 { out.append(.init(tile: i, kind: .verifying)) }
                if t.copying > 0 { out.append(.init(tile: i, kind: .copying)) }
                if t.found + t.verifying + t.copying == 0 { out.append(.init(tile: i, kind: .idle)) }
            }
        }
        return out
    }

    private func look(_ k: LinkKind) -> (Color, StrokeStyle) {
        switch k {
        case .found: return (safe, .init(lineWidth: 2.5, lineCap: .round))
        case .listed: return (ok.opacity(0.8), .init(lineWidth: 2.5, lineCap: .round, dash: [0.5, 6]))
        case .verifying: return (safe.opacity(0.45), .init(lineWidth: 2, lineCap: .round, dash: [4, 4]))
        case .copying: return (copy, .init(lineWidth: 2.5, lineCap: .round, dash: [8, 6]))
        case .missing: return (miss, .init(lineWidth: 2, lineCap: .round, dash: [6, 5]))
        case .failed: return (fail, .init(lineWidth: 2, lineCap: .round, dash: [6, 5]))
        case .idle: return (idle, .init(lineWidth: 1.2, lineCap: .round, dash: [2, 5]))
        }
    }

    private func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
        let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        return CGPoint(x: x, y: y)
    }
}

/// Förklaring av reglaget Full kontroll.
struct FullCheckInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Full check", "Full kontroll")).font(display(22)).tracking(0.8)
            Text(L("Sets how carefully WilderLoader compares a file on the card with the copy it finds.", "Bestämmer hur noga WilderLoader jämför en fil på kortet med kopian den hittar."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                column(on: false, title: L("Off · default", "Av · standard"), time: L("Seconds", "Sekunder"),
                       what: L("Name, file type, exact size and three samples of the content: start, middle and end.", "Namn, filtyp, exakt storlek och tre stickprov ur innehållet: början, mitten och slutet."),
                       when: L("Everyday use. Tells apart different photos, proxies and reused file numbers.", "Vardag. Skiljer olika bilder, proxyer och återanvända filnummer åt."))
                column(on: true, title: L("On", "På"), time: L("Minutes", "Minuter"),
                       what: L("The same, plus the whole file byte by byte on the card and on the copy.", "Samma, plus hela filen byte för byte på kortet och på kopian."),
                       when: L("Before formatting an important card, or if a copy may be damaged.", "Innan du formaterar ett viktigt kort, eller om en kopia kan vara skadad."))
            }
            Text(L("With Full check the map still appears right away. Lines stay faint until the files are checked, and a bar shows the time left.", "Med Full kontroll syns kartan ändå direkt. Linjerna är svaga tills filerna är kontrollerade, och en stapel visar hur lång tid som är kvar."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 420)
    }

    private func column(on: Bool, title: String, time: String, what: String, when: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                Label(time, systemImage: "clock").font(.system(size: 11)).foregroundStyle(on ? miss : ok)
            }
            Text(what).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(when).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
    }
}

/// Liten bildguide till vyn: vad rutorna, prickarna, stapeln och linjerna betyder.
struct HelpGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("How to read WilderLoader", "Så läser du WilderLoader")).font(display(22)).tracking(0.8)

                section(L("The disk tiles", "Diskrutorna"))
                row({ Text(L("41,325 files · 29 min", "41 325 filer · 29 min")).font(.system(size: 11)).monospacedDigit() },
                    L("How many photos and videos WilderLoader has listed for the disk, and how long ago it was scanned.", "Så många bilder och filmer WilderLoader har i listan för disken, och hur länge sedan den skannades."))
                row({ gauge(0.86) }, L("How full the disk is, in steps of 10 %. The last two turn yellow above 80 %.", "Hur full disken är, i steg om 10 %. De två sista blir gula över 80 %."))
                row({ Text("45").font(.system(size: 11, weight: .bold)).foregroundStyle(onOk).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(ok)) },
                    L("How many of the card's files are already on the disk. Click the tile to see them.", "Så många av kortets filer som redan finns på disken. Klicka på rutan för att se dem."))
                row({ HStack(spacing: 6) { Circle().fill(miss).frame(width: 7); Circle().fill(copy).frame(width: 7) } },
                    L("Yellow dot: the disk isn't scanned yet. Purple: it's being scanned now.", "Gul prick: disken är inte skannad än. Lila: den skannas nu."))
                row({ Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) },
                    L("Rescan just that disk. Shows when the pointer is over the tile, or right-click.", "Skanna om bara den disken. Syns när muspekaren är över rutan, eller högerklicka."))

                section(L("The lines", "Linjerna"))
                row({ line(ok) }, L("The files are there and match.", "Filerna finns där och stämmer."))
                row({ line(ok.opacity(0.45), dash: [4, 4]) }, L("Found, but still being checked byte by byte (Full check).", "Hittad, men kontrolleras fortfarande byte för byte (Full kontroll)."))
                row({ line(ok.opacity(0.8), dash: [0.5, 6]) }, L("Only in the list for a disconnected disk. Connect it to check.", "Finns bara i listan för en urkopplad disk. Koppla in den för att kontrollera."))
                row({ line(miss, dash: [6, 5]) }, L("Only on the card. Copy before you format.", "Finns bara på kortet. Kopiera innan du formaterar."))
                row({ line(copy, dash: [8, 6]) }, L("Being copied now.", "Kopieras nu."))
                row({ line(idle, dash: [2, 5]) }, L("Nothing from the card on that disk.", "Inget från kortet på den disken."))

                section(L("Why does WilderLoader scan?", "Varför skannar WilderLoader?"))
                Text(L("Searching every disk each time takes long. So WilderLoader lists every photo and video on each disk once: seconds for a normal disk, a few minutes for a NAS. After that every check takes seconds. The lists update when a disk is connected and when you copy files. A list is only used to find candidates; the real file is always compared before it counts.", "Att leta igenom alla diskar varje gång tar lång tid. Därför gör WilderLoader en lista över alla bilder och filmer på varje disk, en gång: sekunder för en vanlig disk, några minuter för en NAS. Sedan går varje koll på några sekunder. Listorna uppdateras när en disk kopplas in och när du kopierar filer. Listan används bara för att hitta kandidater; den riktiga filen jämförs alltid innan den räknas."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 400, height: 520)
    }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(display(15)).tracking(1.5).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func row<V: View>(@ViewBuilder _ sample: () -> V, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            sample().frame(width: 120, alignment: .leading)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gauge(_ f: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { k in
                RoundedRectangle(cornerRadius: 1).fill(k < Int((f * 10).rounded()) ? (k >= 8 ? miss : mute) : idle)
            }
        }
        .frame(width: 100, height: 5)
    }

    private func line(_ c: Color, dash: [CGFloat] = []) -> some View {
        Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 100, y: 4)) }
            .stroke(c, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dash))
            .frame(width: 100, height: 8)
    }
}

/// Välj vad som ska kollas: en inkopplad disk eller en mapp, i stället för ett minneskort.
struct SourceMenu<Label: View>: View {
    @EnvironmentObject var m: Model
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Section(L("Check a connected disk", "Kolla en inkopplad disk")) {
                ForEach(m.disks.filter { $0.disk.key != "home" }) { r in
                    Button(r.disk.name) { m.scan(r.disk.root) }
                }
            }
            Divider()
            Button(L("Choose folder…", "Välj mapp…")) { m.chooseCardFolder() }
        } label: { label() }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(mute)
        .help(L("Check whether the files on a disk or in a folder are already somewhere else", "Kolla om filerna på en disk eller i en mapp redan finns någon annanstans"))
    }
}

/// "nyss", "29 min", "3 h", "2 d": när listan gjordes, kort nog för rutan.
func age(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    return s < 60 ? L("just now", "nyss") : s < 3600 ? "\(s / 60) min" : s < 86400 ? "\(s / 3600) h" : "\(s / 86400) d"
}

struct TileView: View {
    let tile: Tile
    @EnvironmentObject var m: Model
    @State private var showing = false
    @State private var hovering = false

    /// Disken bakom rutan, om den går att skanna (inte L("Other place", "Annan plats") eller saknade filer).
    private var disk: Disk? { tile.kind == .disk ? tile.row?.disk : nil }
    private func rescan() { if let disk { m.index([disk], active: true) } }
    /// Disken går att öppna i Finder om den är inkopplad.
    private var openable: Disk? { disk.flatMap { $0.offline ? nil : $0 } }
    private func openInFinder() { if let openable { NSWorkspace.shared.open(openable.root) } }

    var body: some View {
        let accent: Color? = tile.kind == .missing ? (tile.count > 0 ? miss : nil) : tile.kind == .failed ? fail
            : tile.copying > 0 ? copy : tile.found - tile.listed + tile.verifying > 0 ? safe : tile.listed > 0 ? ok : nil
        let badge = tile.kind == .disk ? tile.found + tile.verifying + tile.copying : tile.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: tile.icon).font(.system(size: 17)).foregroundStyle(accent ?? fg).frame(width: 24, height: 22)
                    .overlay(alignment: .bottomTrailing) {
                        if let dot = scanDot { Circle().fill(dot).frame(width: 7, height: 7).overlay(Circle().stroke(panel, lineWidth: 1.5)).offset(x: 4, y: 3) }
                    }
                Spacer(minLength: 0)
                if hovering, openable != nil {
                    // Klick på rutan visar filerna i Finder, så knappen ger vägen till listan när det finns filer.
                    Button { if tile.urls.isEmpty { openInFinder() } else { showing = true } } label: {
                        Image(systemName: tile.urls.isEmpty ? "folder" : "list.bullet").font(.system(size: 11, weight: .semibold))
                    }
                        .buttonStyle(.plain).foregroundStyle(mute)
                        .help(tile.urls.isEmpty ? L("Open \(tile.name) in Finder", "Öppna \(tile.name) i Finder") : L("Show the card's files", "Visa kortets filer"))
                        .padding(.trailing, 4)
                }
                if hovering, let disk, !disk.offline, tile.row?.progress == nil {
                    Button(action: rescan) { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(m.indexing ? mute.opacity(0.4) : mute)
                        .disabled(m.indexing)
                        .help(m.indexing ? L("Waiting for the current scan to finish", "Väntar tills pågående skanning är klar") : L("Rescan \(tile.name)", "Skanna om \(tile.name)"))
                        .padding(.trailing, 4)
                }
                if badge > 0, let accent {
                    Text("\(badge)").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(onOk)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(accent))
                }
            }
            Spacer(minLength: 6)
            Text(tile.name).font(display(19)).tracking(0.8).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 11, weight: badge > 0 ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(badge > 0 && accent != nil ? accent! : tile.row.map { $0.count == nil } == true ? miss : mute)
                .lineLimit(1).padding(.top, 2)
            if tile.kind == .disk {
                // Nivåmätare i tio steg; de två sista blir gula när disken nästan är full.
                let lit = Int(((tile.row?.fill ?? 0) * 10).rounded())
                HStack(spacing: 2) {
                    ForEach(0..<10, id: \.self) { k in
                        RoundedRectangle(cornerRadius: 1).fill(k < lit ? (k >= 8 ? miss : mute) : idle)
                    }
                }
                .frame(height: 5).padding(.top, 9)
                .help(tile.row?.fill.map { L("\(Int($0 * 100)) % full", "\(Int($0 * 100)) % fullt") } ?? "")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 4).fill(tile.kind == .missing ? miss.opacity(0.05) : panel))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent ?? panelLine, style: .init(lineWidth: accent == nil ? 1 : 1.5, dash: tile.kind == .disk ? [] : [5, 4])))
        .opacity(tile.row?.disk.offline == true ? 0.6 : accent == nil && tile.kind == .disk ? 0.75 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if tile.urls.isEmpty { openInFinder() }
            else if openable != nil { NSWorkspace.shared.activateFileViewerSelecting(tile.urls) }
            else { showing = true }
        }
        .help(helpText)
        .sheet(isPresented: $showing) { TileDetail(tile: tile).environmentObject(m) }
        .onHover { hovering = $0 }
        .contextMenu {
            if !tile.urls.isEmpty { Button(L("Show the card's files", "Visa kortets filer")) { showing = true } }
            if openable != nil { Button(L("Open in Finder", "Öppna i Finder"), action: openInFinder) }
            if disk != nil { Button(L("Rescan \(tile.name)", "Skanna om \(tile.name)"), action: rescan).disabled(m.indexing) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L("Rescan \(tile.name)", "Skanna om \(tile.name)")) { rescan() }
    }

    private var helpText: String {
        var parts: [String] = []
        if !tile.urls.isEmpty { parts.append((openable != nil ? L("Click to show the card's files in Finder", "Klicka för att visa kortets filer i Finder") : L("Click to see exactly where the card's files are", "Klicka för att se exakt var kortets filer ligger"))) }
        if let r = tile.row {
            if let n = r.progress { parts.append(L("Scanning now, \(n.formatted()) photos and videos so far", "Skannas nu, \(n.formatted()) bilder och filmer hittills")) }
            else if let c = r.count, let d = r.date { parts.append(L("\(c.formatted()) photos and videos listed · scanned \(age(d)) ago", "\(c.formatted()) bilder och filmer i listan · skannad för \(age(d)) sedan")) }
            else { parts.append(L("Not scanned yet", "Inte skannad än")) }
            if let f = r.fill { parts.append(L("The disk is \(Int(f * 100)) % full", "Disken är \(Int(f * 100)) % full")) }
        }
        return parts.joined(separator: " · ")
    }

    private var scanDot: Color? {
        guard tile.kind == .disk, let r = tile.row else { return nil }
        return r.progress != nil ? copy : r.count == nil ? miss : nil
    }

    private var detail: String {
        switch tile.kind {
        case .missing: return tile.count > 0 ? L("Only on the card  ›", "Finns bara på kortet  ›") : L("✓ Nothing left", "✓ Inget kvar")
        case .failed: return L("Still on the card", "Ligger kvar på kortet")
        case .discarded: return L("Culled by you  ›", "Rensade av dig  ›")
        case .disk:
            if tile.copying > 0 { return L("Copying now…", "Kopieras nu…") }
            if tile.verifying > 0 { return L("\(tile.found + tile.verifying) · checking…", "\(tile.found + tile.verifying) · kontrolleras…") }
            if tile.row?.disk.offline == true {
                return tile.found > 0 ? L("\(tile.found) · disconnected  ›", "\(tile.found) · urkopplad  ›") : L("Disconnected", "Urkopplad")
            }
            if tile.found > 0 {
                let k = Set(tile.urls.map { $0.deletingLastPathComponent() }).count
                if k > 1 { return L("\(tile.found) in \(k) folders  ›", "\(tile.found) i \(k) mappar  ›") }
                return L("\(tile.found) from the card  ›", "\(tile.found) från kortet  ›")
            }
            guard let r = tile.row else { return "" }
            if let n = r.progress { return L("Scanning… \(n.formatted())", "Skannar… \(n.formatted())") }
            guard let c = r.count, let d = r.date else { return r.disk.spotlight ? L("Spotlight only so far", "Bara Spotlight än") : L("Not scanned", "Inte skannad") }
            return L("\(c.formatted()) files · \(age(d))", "\(c.formatted()) filer · \(age(d))")
        }
    }
}

/// Vilka mappar på en disk varje fotografering ligger i.
struct DiskMap {
    struct Link: Hashable { let shoot: Int; let folder: URL; let files: [URL] }
    var folders: [URL] = []
    var links: [Link] = []
    var fileCount = 0
}

extension Model {
    func diskMap(_ root: URL) -> DiskMap {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var map = DiskMap()
        for (k, group) in shoots.enumerated() {
            var byFolder: [URL: [URL]] = [:]
            for it in items(in: group) {
                var urls = it.copies
                switch it.status {
                case .found(let u), .listed(let u), .copied(let u), .verifying(let u): urls.append(u)
                default: break
                }
                let here = Set(urls).filter { $0.standardizedFileURL.path.hasPrefix(prefix) }
                if !here.isEmpty { map.fileCount += 1 }
                for u in here { byFolder[u.deletingLastPathComponent(), default: []].append(u) }
            }
            map.links += byFolder.map { DiskMap.Link(shoot: k, folder: $0.key, files: $0.value) }
        }
        // Mapparna står i tidsordning, så att linjerna korsar varandra så lite som möjligt.
        let order = Dictionary(grouping: map.links, by: \.folder).mapValues { l in Double(l.map(\.shoot).reduce(0, +)) / Double(l.count) }
        map.folders = order.keys.sorted { (order[$0]!, $0.path) < (order[$1]!, $1.path) }
        return map
    }
}

/// Kartan från pluppen på en disk: fotograferingarna till vänster, diskens mappar till höger och linjer emellan.
struct DiskMapSheet: View {
    let disk: Disk
    let onCopy: () -> Void
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var shootHover: Int?
    @State private var folderHover: URL?

    private let shootRow: CGFloat = 112, folderRow: CGFloat = 68, shootW: CGFloat = 128, folderW: CGFloat = 330

    var body: some View {
        let map = m.diskMap(disk.root)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: m.diskIcon(disk)).font(.system(size: 22)).foregroundStyle(safe).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name).font(display(23)).tracking(0.8)
                    Text(L("\(map.fileCount) of \(m.items.count) files · \(map.folders.count) \(map.folders.count == 1 ? "folder" : "folders")",
                           "\(map.fileCount) av \(m.items.count) filer · \(map.folders.count) \(map.folders.count == 1 ? "mapp" : "mappar")"))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(safe)
                }
                Spacer()
                Button(L("Done", "Klar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(panelLine).frame(height: 1) }

            ScrollView { graph(map).padding(22) }

            HStack {
                Text(L("Click a shoot or a folder to see its files in Finder", "Klicka på en fotografering eller mapp för att se filerna i Finder"))
                    .font(.system(size: 12)).foregroundStyle(mute)
                Spacer()
                Button(L("Make a copy here…", "Gör en kopia här…")) { onCopy(); dismiss() }
                    .disabled(m.copyingTo != nil)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(panelLine).frame(height: 1) }
        }
        .frame(width: 860, height: 640)
        .background(bg)
        .onChange(of: m.card) { dismiss() }
    }

    private func graph(_ map: DiskMap) -> some View {
        let shoots = m.shoots, height = max(CGFloat(shoots.count) * shootRow, CGFloat(map.folders.count) * folderRow, 300)
        let width: CGFloat = 816
        let shootY = { (k: Int) in (CGFloat(k) + 0.5) * height / CGFloat(max(shoots.count, 1)) }
        let folderY = { (i: Int) in (CGFloat(i) + 0.5) * height / CGFloat(max(map.folders.count, 1)) }
        let most = CGFloat(map.links.map(\.files.count).max() ?? 1)
        let fromX = shootW + 14, toX = width - folderW - 14
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for l in map.links {
                    guard let i = map.folders.firstIndex(of: l.folder) else { continue }
                    let a = CGPoint(x: fromX, y: shootY(l.shoot)), b = CGPoint(x: toX, y: folderY(i)), mid = (a.x + b.x) / 2
                    var path = Path()
                    path.move(to: a)
                    path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
                    let lit = shootHover.map { $0 == l.shoot } ?? folderHover.map { $0 == l.folder } ?? true
                    ctx.stroke(path, with: .color(safe.opacity(lit ? 1 : 0.15)), style: StrokeStyle(lineWidth: 1.5 + 2.5 * CGFloat(l.files.count) / most, lineCap: .round))
                    for p in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(safe.opacity(lit ? 1 : 0.15))) }
                }
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)

            ForEach(Array(shoots.enumerated()), id: \.offset) { k, group in
                let links = map.links.filter { $0.shoot == k }
                let files = links.flatMap(\.files)
                Button { if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) } } label: {
                    ShootStack(group: group, all: shoots).allowsHitTesting(false)
                }
                .buttonStyle(.plain)
                .opacity(files.isEmpty ? 0.6 : 1)
                .onHover { shootHover = $0 ? k : nil }
                .help(files.isEmpty ? L("None of these files are on \(disk.name)", "Ingen av de här filerna finns på \(disk.name)") : L("Show these files on \(disk.name) in Finder", "Visa de här filerna på \(disk.name) i Finder"))
                .frame(width: shootW, height: 98)
                .position(x: shootW / 2, y: shootY(k))
                .accessibilityLabel(L("Shoot \(k + 1), \(Set(files).count) files on \(disk.name)", "Fotografering \(k + 1), \(Set(files).count) filer på \(disk.name)"))
            }

            ForEach(Array(map.folders.enumerated()), id: \.offset) { i, folder in
                let files = map.links.filter { $0.folder == folder }.flatMap(\.files)
                let shown = shootHover.map { h in map.links.first { $0.shoot == h && $0.folder == folder }?.files.count ?? 0 } ?? files.count
                Button { NSWorkspace.shared.activateFileViewerSelecting(files) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(safe)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.lastPathComponent).font(display(18)).tracking(0.6).lineLimit(1).truncationMode(.middle)
                            Text(placeLabel(folder.deletingLastPathComponent().path)).font(.system(size: 11)).foregroundStyle(mute).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 6)
                        Text("\(shown)").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(onOk)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(shown > 0 ? safe : mute.opacity(0.4)))
                    }
                    .padding(.horizontal, 12)
                    .frame(width: folderW, height: folderRow - 10)
                    .background(RoundedRectangle(cornerRadius: 4).fill(panel))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(folderHover == folder ? safe : panelLine, lineWidth: folderHover == folder ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { folderHover = $0 ? folder : nil }
                .help(folder.path)
                .position(x: width - folderW / 2, y: folderY(i))
                .accessibilityLabel(L("\(folder.lastPathComponent), \(files.count) files", "\(folder.lastPathComponent), \(files.count) filer"))
            }
        }
        .frame(width: width, height: height)
    }
}

/// Ett eget fönster som liknar Finder: kortets filer med miniatyrer, mapp för mapp, med vägar till Finder.
struct TileDetail: View {
    let tile: Tile
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<URL> = []
    @State private var anchor: URL?
    @State private var copying = false
    @State private var trashing: [(url: URL, other: URL)] = []
    @AppStorage("hideCulled") private var hideCulled = false
    @AppStorage("detailAsList") private var asList = false

    /// Finder-markering: klick väljer en, ⌘-klick lägger till eller tar bort, ⇧-klick tar allt mellan förra klicket och detta.
    private func click(_ f: URL, in ordered: [URL]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor, let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: f) {
            selection.formUnion(ordered[min(a, b)...max(a, b)])
        } else if mods.contains(.command) {
            if selection.contains(f) { selection.remove(f) } else { selection.insert(f) }
            anchor = f
        } else {
            selection = [f]
            anchor = f
        }
    }

    var body: some View {
        // Kortets filer (saknas/misslyckades) grupperas per inspelningsdag, nyast först; filer på en disk per mapp.
        let byDay = tile.kind != .disk
        let groups = Dictionary(grouping: tile.urls) { byDay ? dayString(modified($0)) : $0.deletingLastPathComponent().path }
        let kept = tile.kind == .missing ? keptByDay : [:]
        let culled = tile.kind == .missing ? groups.filter { kept[$0.key] != nil }.reduce(0) { $0 + $1.value.count } : 0
        let total = tile.urls.count
        let dirs = (byDay ? groups.keys.sorted(by: >) : groups.keys.sorted { (groups[$0]!.count, $1) > (groups[$1]!.count, $0) })
            .filter { !(hideCulled && kept[$0] != nil) }
        let accent = tile.kind == .disk ? ok : tile.kind == .failed ? fail : miss
        let sorted = groups.mapValues { $0.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        let ordered = dirs.flatMap { sorted[$0]! }
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: tile.icon).font(.system(size: 22)).foregroundStyle(accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(display(23)).tracking(0.8)
                    if tile.kind == .disk {
                        let n = Set(tile.urls.map { $0.deletingLastPathComponent() }).count
                        Text(L("In \(n) \(n == 1 ? "folder" : "folders")", "I \(n) \(n == 1 ? "mapp" : "mappar")"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                    }
                    Text(L("Click to select · ⇧-click for a range · ⌘-click for single files · double-click to open", "Klicka för att markera · ⇧-klick för flera i rad · ⌘-klick för enstaka · dubbelklicka för att öppna")).font(.system(size: 12)).foregroundStyle(mute)
                }
                Spacer()
                Picker(L("View", "Visning"), selection: $asList) {
                    Image(systemName: "square.grid.2x2").help(L("Icons", "Ikoner")).tag(false)
                    Image(systemName: "list.bullet").help(L("List", "Lista")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel(L("View", "Visning"))
                Button(selection.count == ordered.count ? L("Deselect all", "Avmarkera alla") : L("Select all", "Markera alla")) {
                    selection = selection.count == ordered.count ? [] : Set(ordered)
                }
                .keyboardShortcut("a")
                Button(L("Done", "Klar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(panelLine).frame(height: 1) }

            if culled > 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(miss)
                    Text(L("\(culled) of \(total) are from days where the rest of the photos are already on a disk. They were probably imported and then culled. The other \(total - culled) were never copied.", "\(culled) av \(total) är från dagar där resten av bilderna redan finns på en disk. De har troligen importerats och sedan rensats bort. Övriga \(total - culled) har aldrig kopierats."))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(L("Mark \(culled) as culled", "Markera \(culled) som rensade")) {
                        m.markDiscarded(Set(groups.filter { kept[$0.key] != nil }.flatMap(\.value)), true)
                        dismiss()
                    }
                    .controlSize(.small)
                    .disabled(m.copyingTo != nil)
                    .help(L("They move to Culled and stop counting as only on the card. WilderLoader remembers them next time; you can undo it under Culled.",
                            "De flyttas till Rensade och räknas inte längre som bara på kortet. Det sparas till nästa gång, och du kan ångra under Rensade."))
                    Toggle(L("Hide them", "Dölj dem"), isOn: $hideCulled)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12, weight: .semibold))
                        .onChange(of: hideCulled) { if hideCulled { selection = selection.filter { u in !kept.keys.contains { k in groups[k]?.contains(u) == true } } } }
                }
                .padding(.horizontal, 22).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(miss.opacity(0.1))
            }

            if ordered.isEmpty && culled > 0 {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(mute)
                    Text(L("Every file here is probably culled, so all of them are hidden.", "Alla filer här är troligen rensade, så alla är dolda."))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Mark them as culled, or turn off Hide them to look first.", "Markera dem som rensade, eller stäng av Dölj dem för att titta först."))
                        .font(.system(size: 12)).foregroundStyle(mute)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                    ForEach(dirs, id: \.self) { dir in
                        let files = sorted[dir]!
                        let all = selection.isSuperset(of: files)
                        Section {
                            if asList {
                                LazyVStack(spacing: 2) {
                                    ForEach(files, id: \.self) { f in
                                        FileRow(url: f, selected: selection.contains(f)) { historyBadge(f) }
                                            .onTapGesture(count: 2) { NSWorkspace.shared.open(f) }
                                            .onTapGesture { click(f, in: ordered) }
                                    }
                                }
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 14)], spacing: 18) {
                                    ForEach(files, id: \.self) { f in
                                        FileCell(url: f, selected: selection.contains(f))
                                            .overlay(alignment: .topLeading) { historyBadge(f).padding(7) }
                                            .onTapGesture(count: 2) { NSWorkspace.shared.open(f) }
                                            .onTapGesture { click(f, in: ordered) }
                                    }
                                }
                            }
                        } header: {
                          VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: byDay ? "calendar" : "folder.fill").foregroundStyle(accent)
                                Text(byDay ? dayLabel(dir) : path(URL(fileURLWithPath: dir))).font(.system(size: 12, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                                Text("\(files.count)").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(mute)
                                Spacer(minLength: 10)
                                Button(all ? L("Deselect \(byDay ? "day" : "folder")", "Avmarkera \(byDay ? "dagen" : "mappen")") : L("Select \(byDay ? "day" : "folder")", "Markera \(byDay ? "dagen" : "mappen")")) {
                                    if all { selection.subtract(files) } else { selection.formUnion(files) }
                                }
                                .controlSize(.small)
                                Button(L("Show in Finder", "Visa i Finder")) { NSWorkspace.shared.activateFileViewerSelecting(files) }.controlSize(.small)
                            }
                            if tile.kind == .missing && byDay {
                                // Appen gissar inte: den frågar vad som hände med dagen.
                                HStack(spacing: 8) {
                                    if let k = kept[dir] {
                                        Text(L("\(k.count) other files from this day are in \(placeLabel(k.dir.path)). What happened to these \(files.count)?", "\(k.count) andra filer från dagen ligger i \(placeLabel(k.dir.path)). Vad hände med de här \(files.count)?"))
                                            .font(.system(size: 11)).foregroundStyle(miss).lineLimit(2)
                                            .onTapGesture(count: 2) { NSWorkspace.shared.open(k.dir) }
                                            .help(L("Double-click to open the folder", "Dubbelklicka för att öppna mappen"))
                                    } else {
                                        Text(L("Nothing from this day is on a disk.", "Inget från den här dagen finns på en disk."))
                                            .font(.system(size: 11)).foregroundStyle(mute)
                                    }
                                    Spacer(minLength: 8)
                                    Button(L("I culled them", "Jag rensade bort dem")) { m.markDiscarded(Set(files), true); dismiss() }
                                    if let k = kept[dir] {
                                        Button(L("Put them in \(k.dir.lastPathComponent)", "Lägg dem i \(k.dir.lastPathComponent)")) {
                                            m.copyMissing(Set(files), to: k.dir, withCable: false); dismiss()
                                        }
                                        .help(placeLabel(k.dir.path))
                                    }
                                    Button(kept[dir] == nil ? L("Copy to…", "Kopiera till…") : L("Another folder…", "En annan mapp…")) {
                                        selection = Set(files); copying = true
                                    }
                                }
                                .controlSize(.small)
                                .disabled(m.busy)
                            }
                          }
                            .padding(.vertical, 8)
                            .background(bg)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            }

            HStack(spacing: 10) {
                let one = selection.count == 1 ? selection.first : nil
                if let one, let r = m.history[one] {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(miss)
                    Text(historyText(r)).font(.system(size: 11)).foregroundStyle(fg).lineLimit(1).truncationMode(.middle)
                    Button(L("Show location", "Visa platsen")) { revealNearest(r.dest) }.controlSize(.small)
                } else {
                Text(one?.path ?? (selection.isEmpty ? L("No file selected", "Ingen fil markerad") : L("\(selection.count) files selected", "\(selection.count) filer markerade")))
                    .font(.system(size: 11)).foregroundStyle(mute).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button(L("Show in Finder", "Visa i Finder")) { NSWorkspace.shared.activateFileViewerSelecting(Array(selection)) }
                    .disabled(selection.isEmpty)
                if tile.kind == .missing {
                    Button(L("Mark as culled", "Markera som rensade")) { m.markDiscarded(selection, true); dismiss() }
                        .disabled(selection.isEmpty || m.busy)
                        .help(L("You've deleted these on purpose. They stop counting as only on the card, and WilderLoader remembers them next time.", "Du har tagit bort dem med flit. De räknas inte längre som bara på kortet, och WilderLoader kommer ihåg dem nästa gång."))
                }
                if tile.kind == .disk, tile.row?.disk.offline != true {
                    let dupes = m.duplicates(selection)
                    Button(L("Move to Trash…", "Lägg i papperskorgen…")) { trashing = dupes }
                        .disabled(dupes.isEmpty || m.busy)
                        .help(dupes.isEmpty && !selection.isEmpty
                              ? L("None of the selected files is on another connected disk, so nothing can be removed here.", "Ingen av de markerade filerna finns på en annan inkopplad disk, så inget kan tas bort här.")
                              : L("Removes the copies here that are also on another disk.", "Tar bort kopiorna här som också finns på en annan disk."))
                }
                if tile.kind == .discarded {
                    Button(L("Undo culling", "Ångra rensning")) { m.markDiscarded(selection, false); dismiss() }
                        .disabled(selection.isEmpty || m.busy)
                }
                if tile.kind == .missing {
                    Button(L("Copy \(selection.count) \(selection.count == 1 ? "file" : "files")…", "Kopiera \(selection.count) \(selection.count == 1 ? "fil" : "filer")…")) { copying = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.isEmpty || m.busy)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(panelLine).frame(height: 1) }
        }
        .frame(width: 820, height: 600)
        .background(bg)
        .foregroundStyle(fg)
        .sheet(isPresented: $copying) { CopyChooser(files: m.items.map(\.file).filter { selection.contains($0.url) }) { dismiss() }.environmentObject(m) }
        .confirmationDialog(L("Move \(trashing.count) files on \(tile.name) to the Trash?", "Lägga \(trashing.count) filer på \(tile.name) i papperskorgen?"),
                            isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })) {
            Button(L("Move to Trash", "Lägg i papperskorgen"), role: .destructive) {
                let urls = trashing.map(\.url)
                trashing = []
                dismiss()
                m.trash(urls)
            }
            Button(L("Cancel", "Avbryt"), role: .cancel) { trashing = [] }
        } message: {
            let places = Set(trashing.map { placeLabel($0.other.deletingLastPathComponent().path) }).sorted()
            let kept = selection.count - trashing.count
            Text(L("Each one is also on another disk, e.g. \(places.prefix(2).joined(separator: ", ")). You can get them back from the Trash until you empty it.",
                   "Var och en finns också på en annan disk, t.ex. \(places.prefix(2).joined(separator: ", ")). Du kan ta tillbaka dem från papperskorgen tills du tömmer den.")
                 + (kept > 0 ? L(" \(kept) selected files have no other copy and stay.", " \(kept) markerade filer saknar annan kopia och ligger kvar.") : ""))
        }
    }

    private var title: String {
        let n = tile.urls.count, f = n == 1 ? L("file", "fil") : L("files", "filer")
        switch tile.kind {
        case .disk: return L("\(n) \(f) from the card \(n == 1 ? "is" : "are") on \(tile.name)", "\(n) \(f) från kortet finns på \(tile.name)")
        case .missing: return L("\(n) \(f) only on the card", "\(n) \(f) finns bara på kortet")
        case .failed: return L("\(n) \(f) could not be copied", "\(n) \(f) kunde inte kopieras")
        case .discarded: return L("\(n) \(f) you have culled", "\(n) \(f) som du har rensat bort")
        }
    }

    /// Per inspelningsdag: mappen där flest andra kortfiler från samma dag redan finns, och hur många som finns någonstans.
    private var keptByDay: [String: (dir: URL, count: Int)] {
        var tally: [String: [URL: Int]] = [:]
        for it in m.items {
            if let u = it.status.foundURL { tally[dayString(it.file.date), default: [:]][u.deletingLastPathComponent(), default: 0] += 1 }
        }
        return tally.mapValues { dirs in (dirs.max { $0.value < $1.value }!.key, dirs.values.reduce(0, +)) }
    }

    /// "Kopierades 3 nov. 2026 till Wildermark › … · finns inte där längre"
    private func historyText(_ r: CopyRecord) -> String {
        let fm = FileManager.default
        let date = r.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appLang.locale))
        if !r.copied { return L("Was in \(placeLabel(r.dest.path)) · gone by the scan on \(date)", "Låg i \(placeLabel(r.dest.path)) · borta vid skanningen \(date)") }
        let head = L("Copied \(date) to \(placeLabel(r.dest.path))", "Kopierades \(date) till \(placeLabel(r.dest.path))")
        if fm.fileExists(atPath: r.dest.path) { return head }
        let parts = r.dest.pathComponents
        if parts.count > 2, parts[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/" + parts[2]) {
            return head + L(" · the disk is not connected", " · disken är inte inkopplad")
        }
        return head + L(" · no longer there", " · finns inte där längre")
    }

    /// Öppnar den närmaste mapp som fortfarande finns på vägen till den gamla kopian.
    private func revealNearest(_ u: URL) {
        var dir = u
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir.deleteLastPathComponent() }
        if dir == u { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(dir) }
    }

    @ViewBuilder private func historyBadge(_ f: URL) -> some View {
        if tile.kind != .disk, let r = m.history[f] {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(bg)
                .padding(4).background(Circle().fill(miss))
                .help(historyText(r))
                .accessibilityLabel(historyText(r))
        }
    }

    private func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// "2026-10-31" → "Lördag 31 oktober 2026"
    private func dayLabel(_ day: String) -> String {
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: day) else { return day }
        let f = DateFormatter(); f.locale = appLang.locale; f.dateFormat = L("EEEE, MMMM d, yyyy", "EEEE d MMMM yyyy")
        let s = f.string(from: d); return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// "Wildermark › Wildermark NAS › 01_AKTIVA › …", räknat från diskens eller kortets rot.
    private func path(_ dir: URL) -> String {
        guard let root = tile.root else { return dir.path }
        let base = root.standardizedFileURL.path, p = dir.standardizedFileURL.path
        let rest = p.hasPrefix(base) ? p.dropFirst(base.count).split(separator: "/").map(String.init) : [p]
        return ([root.lastPathComponent == NSUserName() ? tile.name : root.lastPathComponent] + rest).joined(separator: " › ")
    }
}

struct FileCell: View {
    let url: URL
    let selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(panel)
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                } else {
                    Image(systemName: video ? "film" : "photo").font(.system(size: 24, weight: .light)).foregroundStyle(mute)
                }
            }
            .frame(height: 92)
            .overlay(alignment: .bottomTrailing) {
                if video {
                    Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.white)
                        .padding(5).background(Circle().fill(.black.opacity(0.6))).padding(8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? ok : panelLine, lineWidth: selected ? 2 : 1))
            Text(url.lastPathComponent).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(selected ? ok.opacity(0.25) : .clear))
        }
        .contentShape(Rectangle())
        .help(url.path)
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 150, height: 100),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// En rad i listvyn: liten miniatyr, namn, datum och storlek.
struct FileRow<Badge: View>: View {
    let url: URL
    let selected: Bool
    @ViewBuilder let badge: () -> Badge
    @State private var thumb: NSImage?
    @State private var info: (size: Int64, date: Date)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(panel)
                if let thumb { Image(nsImage: thumb).resizable().scaledToFit() }
            }
            .frame(width: 36, height: 26)
            Text(url.lastPathComponent).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            badge()
            Spacer(minLength: 10)
            if let info {
                Text(info.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLang.locale)))
                    .frame(width: 150, alignment: .trailing)
                Text(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)).frame(width: 70, alignment: .trailing)
            }
        }
        .font(.system(size: 11)).foregroundStyle(selected ? fg : fg.opacity(0.9)).monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? ok.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .help(url.path)
        .task(id: url) {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            info = v.map { (Int64($0.fileSize ?? 0), $0.contentModificationDate ?? .distantPast) }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 26),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Väljaren för filer som inte är på väg till någon bestämd disk: den föreslår disken, och du kan byta.
struct CopyChooser: View {
    let files: [CardFile]
    var onStart: () -> Void = {}
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    // Räknas ut en gång: modellen ändras medan fönstret är öppet och förslaget ska inte hoppa.
    @State private var suggestion: (disk: Disk, folder: URL)?

    var body: some View {
        Group { content }
            .onAppear {
                suggestion = m.likelyDisk(for: files).map { ($0, m.likelyFolder(for: files, on: $0)) }
            }
    }

    @ViewBuilder private var content: some View {
        if let suggestion {
            LandingSheet(files: files, disk: suggestion.disk, start: suggestion.folder, canChangeDisk: true, onStart: onStart)
        } else {
            VStack(spacing: 12) {
                Text(L("No disk to copy to is connected.", "Ingen disk att kopiera till är inkopplad."))
                Button(L("Close", "Stäng")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(22)
            .background(bg)
            .foregroundStyle(fg)
        }
    }
}

/// Var filerna landar: diskens riktiga mappar i kolumner, som i Finder. Mappar där filerna redan ligger är gröna.
struct LandingSheet: View {
    let files: [CardFile]
    /// Filerna finns redan på disken, så det som kopieras blir en extra kopia.
    var extra = false
    /// Sant när filerna har dragits hit själv: då kopieras de även om de finns på en annan disk.
    var anyStatus = false
    var canChangeDisk = false
    var onStart: () -> Void = {}
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var disk: Disk
    @State private var folder: URL
    @State private var listing: [URL: [URL]] = [:]
    @State private var newName = ""
    @State private var problem: String?
    /// Mappmallen och fälten sparas, så att nästa kort från samma jobb hamnar rätt direkt.
    @AppStorage("folderTemplate") private var template = dateTemplate
    @AppStorage("folderProject") private var project = ""
    @AppStorage("folderCamera") private var camera = ""
    @State private var customTemplate = false
    /// Andra disken, som får samma filer samtidigt.
    @State private var second: Disk?
    @State private var secondFolder: URL?

    init(files: [CardFile], disk: Disk, start: URL, extra: Bool = false, anyStatus: Bool = false, canChangeDisk: Bool = false, second: Disk? = nil, secondFolder: URL? = nil, onStart: @escaping () -> Void = {}) {
        _second = State(initialValue: second)
        _secondFolder = State(initialValue: secondFolder)
        days = Set(files.map { dayString($0.date) }).sorted()
        self.files = files
        self.extra = extra
        self.anyStatus = anyStatus
        self.canChangeDisk = canChangeDisk
        self.onStart = onStart
        _disk = State(initialValue: disk)
        _folder = State(initialValue: dirURL(start))
    }

    private var root: URL { dirURL(disk.root) }
    @State private var homes: [URL: Int] = [:]
    /// Vägen från diskens rot till den valda mappen.
    private var levels: [URL] {
        var out = [folder], cur = folder
        while cur.path != root.path, cur.path.hasPrefix(root.path + "/") {
            cur = dirURL(cur.deletingLastPathComponent())
            out.insert(cur, at: 0)
        }
        return out
    }
    /// Räknas ut en gång: rutan ritas om ofta, och ett kort kan ha tusentals filer.
    private let days: [String]
    /// Är den valda mappen redan datummappen läggs ingen till.
    private var dated: Bool { !(days.count == 1 && folder.lastPathComponent == days[0]) && !(extra && homes[folder] != nil) }
    /// Mallen för just den här kopieringen. Är den valda mappen redan datummappen läggs inget datum till.
    private var activeTemplate: String {
        dated ? template : template.split(separator: "/").filter { $0 != "{date}" }.joined(separator: "/")
    }
    private func subfolder(_ f: CardFile) -> String { renderTemplate(activeTemplate, project: project, camera: camera, date: f.date) }
    /// Mappvägarna, en per inspelningsdag.
    private var paths: [String] { Array(Set(days.map { renderTemplate(activeTemplate, project: project, camera: camera, day: $0) })).sorted() }
    private func places(in base: URL) -> [URL] { Array(Set(paths.map { dirURL(templatePlace(base, $0)) })).sorted { $0.path < $1.path } }
    private var destinations: [URL] { places(in: folder) }
    /// Filerna finns redan i mappen de skulle hamna i, och inget skrivs över.
    private var alreadyHere: Bool { extra && destinations.contains { homes[$0] != nil } }
    /// Mallen behöver ett projektnamn eller en kamera som inte är ifyllda.
    private var missingField: Bool {
        (template.contains("{project}") && project.trimmingCharacters(in: .whitespaces).isEmpty)
            || (template.contains("{camera}") && camera.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func chip(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? onOk : fg)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? accent : panel))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? accent : panelLine))
        }
        .buttonStyle(.plain)
    }

    /// Hur filerna ordnas i den valda mappen.
    private var templateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("FOLDERS", "MAPPAR")).font(display(15)).tracking(1.5).foregroundStyle(mute).frame(width: 74, alignment: .leading)
                chip(L("By date", "Per datum"), on: !customTemplate && template == dateTemplate) { template = dateTemplate; customTemplate = false }
                chip(L("Project / RAW / Camera / Date", "Projekt / RAW / Kamera / Datum"), on: !customTemplate && template == filmTemplate) {
                    template = filmTemplate; customTemplate = false
                    if camera.isEmpty { camera = m.card?.lastPathComponent ?? "" }
                }
                chip(L("Straight in", "Direkt i mappen"), on: !customTemplate && template.isEmpty) { template = ""; customTemplate = false }
                chip(L("Custom", "Egen"), on: customTemplate) { customTemplate = true }
            }
            if customTemplate {
                TextField("{project}/RAW/{camera}/{date}", text: $template).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            }
            if template.contains("{project}") || template.contains("{camera}") {
                HStack(spacing: 8) {
                    if template.contains("{project}") { TextField(L("Project", "Projekt"), text: $project).textFieldStyle(.roundedBorder) }
                    if template.contains("{camera}") { TextField(L("Camera", "Kamera"), text: $camera).textFieldStyle(.roundedBorder) }
                }
            }
        }
    }

    /// Andra disken: samma filer samtidigt, och samma mappväg som på den första.
    private var secondRow: some View {
        HStack(spacing: 6) {
            Text(L("ALSO TO", "ÄVEN TILL")).font(display(15)).tracking(1.5).foregroundStyle(mute).frame(width: 74, alignment: .leading)
            chip(L("No", "Nej"), on: second == nil) { second = nil; secondFolder = nil }
            ForEach(m.copyTargets.filter { $0.key != disk.key }, id: \.key) { d in
                chip(d.name, on: second?.key == d.key) {
                    second = d
                    secondFolder = dirURL(m.likelyFolder(for: files, on: d))
                }
            }
            if let second, let secondFolder {
                Spacer(minLength: 4)
                Button(L("Change folder…", "Byt mapp…")) {
                    if let picked = m.pickFolder(in: secondFolder), picked.path.hasPrefix(dirURL(second.root).path) { self.secondFolder = dirURL(picked) }
                }
                .font(.system(size: 12))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(extra ? L("Already on \(disk.name)", "Finns redan på \(disk.name)") : L("Choose a folder on \(disk.name)", "Välj mapp på \(disk.name)"))
                    .font(display(24)).tracking(0.8)
                if extra {
                    Text(L("They are in the green folder. Choose another folder to make another copy.", "De ligger i den gröna mappen. Välj en annan mapp för att göra en kopia till."))
                        .font(.system(size: 12)).foregroundStyle(mute)
                }
            }
            if canChangeDisk {
                HStack(spacing: 6) {
                    ForEach(m.copyTargets, id: \.key) { d in
                        let on = d.key == disk.key
                        Button {
                            disk = d
                            folder = dirURL(m.likelyFolder(for: files, on: d))
                            problem = nil
                            if second?.key == d.key { second = nil; secondFolder = nil }
                        } label: {
                            Text(d.name).font(display(16)).tracking(0.6).lineLimit(1)
                                .foregroundStyle(on ? onOk : fg)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 4).fill(on ? accent : panel))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? accent : panelLine))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { i, level in
                    if i > 0 { Rectangle().fill(panelLine).frame(width: 1) }
                    column(level).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 240)
            .background(panel)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(panelLine))
            HStack {
                TextField(L("New folder in \(folder.path == root.path ? disk.name : folder.lastPathComponent)…", "Ny mapp i \(folder.path == root.path ? disk.name : folder.lastPathComponent)…"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createFolder)
                Button(L("Create", "Skapa"), action: createFolder).disabled(cleanName.isEmpty)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(fail) }
            templateRow
            secondRow
            VStack(alignment: .leading, spacing: 4) {
                Text(alreadyHere ? L("ALREADY HERE", "FINNS REDAN HÄR") : L("ENDS UP IN", "HAMNAR I")).font(display(15)).tracking(1.5).foregroundStyle(alreadyHere ? safe : mute)
                // Två rader per disk räcker för att se vägen. Många inspelningsdagar ska inte trycka ut knapparna ur rutan.
                ForEach(destinations.prefix(2) + (secondFolder.map { places(in: $0).prefix(2) } ?? []), id: \.self) { d in
                    Label(placeLabel(d.path, full: true), systemImage: "folder.fill")
                        .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                }
                if destinations.count > 2 {
                    Text(L("+ \(destinations.count - 2) more days", "+ \(destinations.count - 2) dagar till")).font(.system(size: 11)).foregroundStyle(mute)
                }
            }
            if !anyStatus, let f = m.forward, case let n = m.forwardJobs().count, n > 0 {
                Label(L("The cable also copies \(n.formatted()) files to \(placeLabel(f.folder.path)).", "Kabeln kopierar dessutom \(n.formatted()) filer till \(placeLabel(f.folder.path))."), systemImage: "cable.connector")
                    .font(.system(size: 12))
            }
            HStack {
                Text(L("\(files.count) files · \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)) · nothing is overwritten", "\(files.count) filer · \(ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)) · inget skrivs över"))
                    .font(.system(size: 11)).foregroundStyle(mute).monospacedDigit()
                Spacer()
                Button(L("Cancel", "Avbryt")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(extra ? L("Make a copy here", "Gör en kopia här") : L("Copy here", "Kopiera hit")) {
                    m.copyMissing(Set(files.map(\.url)), to: folder, also: secondFolder, subfolder: subfolder, anyStatus: anyStatus)
                    dismiss()
                    onStart()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(alreadyHere || missingField)
            }
        }
        .padding(22)
        .frame(width: 720)
        .background(bg)
        .foregroundStyle(fg)
        .task(id: folder) { await load() }
        .task(id: disk.key) { homes = m.homes(of: files, on: disk) }
    }

    /// De tre sista nivåerna; djupare mappar skjuter de översta åt sidan, som i Finder.
    private var columns: [URL?] { levels.suffix(3) + Array(repeating: nil, count: max(0, 3 - levels.count)) }

    @ViewBuilder private func column(_ level: URL?) -> some View {
        if let level, let list = listing[level] {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if list.isEmpty { Text(L("No folders", "Inga mappar")).font(.system(size: 12)).foregroundStyle(mute).padding(8) }
                        ForEach(list, id: \.self) { u in row(u) }
                    }
                    .padding(4)
                }
                .onAppear { if let open = list.first(where: levels.contains) { proxy.scrollTo(open, anchor: .center) } }
            }
        } else if level != nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func row(_ u: URL) -> some View {
        let on = levels.contains(u), count = homes[u]
        // Grön väg ner till mappen där filerna ligger.
        let leads = count != nil || homes.keys.contains { $0.path.hasPrefix(u.path + "/") }
        return Button { folder = u; problem = nil } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(on ? onOk : leads ? safe : fg)
                Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(on ? onOk : leads ? safe : fg)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(on ? onOk : safe)
                        .help(L("\(count) of the files are here", "\(count) av filerna ligger här"))
                }
            }
            .font(.system(size: 13, weight: on || leads ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 3).fill(on ? (leads ? safe : accent) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Listas utanför huvudtråden, eftersom en NAS kan vara långsam.
    private func load() async {
        for level in levels where listing[level] == nil {
            listing[level] = await Task.detached { subfolders(of: level) }.value
        }
    }

    private var cleanName: String {
        // Snedstreck och kolon skulle skapa undermappar eller ogiltiga namn.
        let n = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return n.hasPrefix(".") ? "" : n
    }

    private func createFolder() {
        guard !cleanName.isEmpty else { return }
        let new = dirURL(folder.appendingPathComponent(cleanName, isDirectory: true))
        do {
            // Finns mappen redan väljs den bara.
            try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            listing[folder] = nil
            folder = new
            problem = nil
            newName = ""
            Task { await load() }
        } catch { problem = error.localizedDescription }
    }
}

/// Bekräftelse före formatering. Om filer bara finns på kortet måste man skriva kortets namn.
struct FormatSheet: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        let name = m.card?.lastPathComponent ?? ""
        let lost = m.missing.count + m.failed.count
        let unchecked = m.unverified
        let others = m.otherFiles.count
        let clear = lost == 0 && unchecked == 0 && others == 0
        let size = (try? m.card?.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).flatMap { $0 }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: clear ? "sdcard" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(clear ? ok : lost > 0 ? fail : miss).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Format \(name)?", "Formatera \(name)?")).font(display(24)).tracking(0.8)
                    let cap = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                    Text(L("\(m.items.count) files\(cap.map { " · \($0) card" } ?? "") · same format and name as now · ejected afterwards",
                           "\(m.items.count) filer\(cap.map { " · kort på \($0)" } ?? "") · samma format och namn som nu · matas ut efteråt"))
                        .font(.system(size: 12)).foregroundStyle(mute)
                }
            }
            if clear {
                Label(L("All files are on another disk and fully checked.", "Alla filer finns på en annan disk och är fullt kontrollerade."), systemImage: "checkmark.circle.fill").foregroundStyle(ok).font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if lost > 0 {
                        Text(L("\(lost) \(lost == 1 ? "file is" : "files are") only on the card and will be gone for good.", "\(lost) \(lost == 1 ? "fil finns" : "filer finns") bara på kortet och försvinner för alltid."))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(fail)
                    }
                    if unchecked > 0 {
                        Text(L("\(unchecked) \(unchecked == 1 ? "file has" : "files have") not had a full check. A copy could be damaged or a different file.", "\(unchecked) \(unchecked == 1 ? "fil har" : "filer har") inte fått en full kontroll. En kopia kan vara skadad eller en annan fil."))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(miss).fixedSize(horizontal: false, vertical: true)
                    }
                    if others > 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L("\(others) other \(others == 1 ? "file" : "files") can't be checked and will be erased too: \(describeKinds(m.otherFiles)).", "\(others) \(others == 1 ? "annan fil" : "andra filer") går inte att kontrollera och raderas också: \(describeKinds(m.otherFiles))."))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(miss).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L("Show", "Visa")) { NSWorkspace.shared.activateFileViewerSelecting(m.otherFiles) }
                        }
                    }
                    Text(L("Type the card's name, \(name), to format anyway.", "Skriv kortets namn, \(name), för att formatera ändå.")).font(.system(size: 12)).foregroundStyle(mute)
                    TextField(name, text: $typed).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 4).fill((lost > 0 ? fail : miss).opacity(0.12)))
            }
            if m.awayOnly > 0 {
                Text(L("\(m.awayOnly) files were matched by name and size against the list of a disconnected disk. Connect it for a full check.",
                       "\(m.awayOnly) filer matchades på namn och storlek mot listan för en urkopplad disk. Koppla in den för en full kontroll."))
                    .font(.system(size: 12)).foregroundStyle(mute).fixedSize(horizontal: false, vertical: true)
            }
            if !m.discarded.isEmpty {
                Text(L("\(m.discarded.count) files you marked as culled are erased too.", "\(m.discarded.count) filer som du markerat som rensade raderas också."))
                    .font(.system(size: 12)).foregroundStyle(mute)
            }
            if m.minorFiles > 0 {
                Text(L("\(m.minorFiles) small metadata files, such as XML and thumbnails, aren't compared with any copy.", "\(m.minorFiles) små metadatafiler, som XML och miniatyrer, jämförs inte med någon kopia."))
                    .font(.system(size: 12)).foregroundStyle(mute).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("If your camera prefers to format the card itself, do it there instead.", "Vill kameran helst formatera själv kan du göra det där i stället.")).font(.system(size: 11)).foregroundStyle(mute)
            HStack {
                Spacer()
                Button(L("Cancel", "Avbryt")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) { m.formatCard(); dismiss() } label: { Text(L("Format", "Formatera")) }
                    .disabled(!clear && typed != name)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(bg)
        .foregroundStyle(fg)
    }
}

/// Bubblan vid kabeln: välj mapp på måldisken och hur filerna ordnas, utan att lämna kartan.
struct ForwardBubble: View {
    @EnvironmentObject var m: Model
    let from: DiskRow
    let to: DiskRow
    let close: () -> Void
    @State private var outside = false
    @State private var hints: [Hint] = []
    private var folder: URL? { m.cableFolder }

    /// Ett mappförslag och varför det finns.
    struct Hint: Hashable {
        let folder: URL
        let layout: Forward.Layout
        let why: String
    }
    private var layout: Forward.Layout { m.cableLayout }

    var body: some View {
        let plan = Forward(from: from.id, to: to.id, folder: folder ?? to.disk.root, layout: layout, includeExisting: m.cableInclude)
        let jobs = m.forwardJobs(plan)
        let both = m.overlap(from: from.disk, to: to.disk)
        let allThere = !both.isEmpty && !m.cableInclude && jobs.isEmpty
        let example = jobs.first.map { String($0.2.path.dropFirst(plan.folder.path.count)) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(from.disk.name) → \(to.disk.name)").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(L("\(jobs.count.formatted()) files", "\(jobs.count.formatted()) filer")).font(.system(size: 12)).foregroundStyle(mute).monospacedDigit()
            }
            if !jobs.isEmpty {
            Text(L("Copies the card's files that are on \(from.disk.name) to \(to.disk.name) too. Nothing on \(from.disk.name) changes.",
                   "Kopierar kortets filer som finns på \(from.disk.name) till \(to.disk.name) också. Inget på \(from.disk.name) ändras."))
                .font(.system(size: 11)).foregroundStyle(mute).fixedSize(horizontal: false, vertical: true)
            }

            // Filer som redan finns på måldisken hoppas över: ingen extra kopia, om man inte själv vill ha en.
            if !both.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(allThere
                          ? L("All \(both.count.formatted()) are already on \(to.disk.name). Nothing needs copying.", "Alla \(both.count.formatted()) finns redan på \(to.disk.name). Inget behöver kopieras.")
                          : L("\(both.count.formatted()) are already on \(to.disk.name) and are skipped.", "\(both.count.formatted()) finns redan på \(to.disk.name) och hoppas över."),
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(ok).fixedSize(horizontal: false, vertical: true)
                    if allThere {
                        Button(L("Copy to another folder anyway…", "Kopiera till en annan mapp ändå…")) { m.cableInclude = true }.controlSize(.small)
                    } else {
                        Toggle(L("Copy them to this folder too", "Kopiera dem till den här mappen också"), isOn: $m.cableInclude)
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                    if !from.disk.offline {
                        Button(L("Move the \(both.count.formatted()) on \(from.disk.name) to Trash…", "Lägg de \(both.count.formatted()) på \(from.disk.name) i papperskorgen…")) {
                            confirmTrash(both)
                        }
                        .controlSize(.small)
                        .help(L("They stay on \(to.disk.name). You can get them back from the Trash until you empty it.", "De ligger kvar på \(to.disk.name). Du kan ta tillbaka dem från papperskorgen tills du tömmer den."))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(ok.opacity(0.08)))
            }

            if !jobs.isEmpty {
            // Var: vald mapp, plus mappar på måldisken där kortets filer redan ligger.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("FOLDER ON \(to.disk.name.uppercased())", "MAPP PÅ \(to.disk.name.uppercased())")).font(display(15)).tracking(1.5).foregroundStyle(mute)
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(folder == nil ? mute : ok)
                    Text(folder.map { placeLabel($0.path) } ?? L("Choose a folder", "Välj en mapp")).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(folder == nil ? mute : fg)
                    Spacer(minLength: 6)
                    Button(folder == nil ? L("Choose…", "Välj…") : L("Change…", "Byt…")) { pick() }.controlSize(.small)
                }
                .font(.system(size: 12))
                if !hints.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hints, id: \.self) { h in
                            let on = folder == h.folder && layout == h.layout
                            Button { m.cableFolder = h.folder; m.cableLayout = h.layout; outside = false } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "sparkle").font(.system(size: 10)).foregroundStyle(ok)
                                    Text(h.folder.lastPathComponent).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text("· " + h.why).font(.system(size: 11)).foregroundStyle(mute).lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(on ? ok.opacity(0.2) : panel))
                                .overlay(Capsule().stroke(on ? ok : panelLine))
                            }
                            .buttonStyle(.plain)
                            .help(placeLabel(h.folder.path))
                        }
                    }
                }
                if outside {
                    Text(L("Choose a folder on \(to.disk.name).", "Välj en mapp på \(to.disk.name).")).font(.system(size: 11)).foregroundStyle(fail)
                }
            }

            // Hur: tre ikoner, och ett exempel på var en fil hamnar.
            VStack(alignment: .leading, spacing: 6) {
                Text(L("ARRANGE", "ORDNING")).font(display(15)).tracking(1.5).foregroundStyle(mute)
                HStack(spacing: 6) {
                    option(.mirror, "list.bullet.indent", L("Like \(from.disk.name)", "Som \(from.disk.name)"))
                    option(.byDay, "calendar", L("By day", "Per dag"))
                    option(.flat, "square.grid.3x3", L("All in one", "Allt i en"))
                }
                if let example, folder != nil {
                    Text(L("e.g. ", "t.ex. ") + "…" + example).font(.system(size: 11, design: .monospaced)).foregroundStyle(mute)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            }

            HStack {
                if m.forward != nil {
                    Button(L("Remove", "Ta bort")) { m.forward = nil; close() }.controlSize(.small)
                }
                Spacer()
                if jobs.isEmpty {
                    Button(L("Done", "Klar")) { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Cancel", "Avbryt")) { close() }.keyboardShortcut(.cancelAction)
                    Button(L("Add", "Lägg till")) { m.forward = plan; close() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(folder == nil)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(bg)
        .foregroundStyle(fg)
        .task { await findHints() }
    }

    private func confirmTrash(_ both: [(src: URL, dst: URL)]) {
        let cable = m.cable
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("Move \(both.count) files on \(from.disk.name) to the Trash?", "Lägga \(both.count) filer på \(from.disk.name) i papperskorgen?")
        let places = Set(both.map { placeLabel($0.dst.deletingLastPathComponent().path) }).sorted()
        a.informativeText = L("Each one is also on \(to.disk.name), e.g. in \(places.prefix(2).joined(separator: ", ")). You can get them back from the Trash until you empty it.",
                              "Var och en finns också på \(to.disk.name), t.ex. i \(places.prefix(2).joined(separator: ", ")). Du kan ta tillbaka dem från papperskorgen tills du tömmer den.")
        a.addButton(withTitle: L("Move to Trash", "Lägg i papperskorgen"))
        a.addButton(withTitle: L("Cancel", "Avbryt"))
        a.buttons.first?.hasDestructiveAction = true
        let go = a.runModal() == .alertFirstButtonReturn
        // Den andra kopian måste fortfarande finnas när vi tar bort, inte bara när listan gjordes.
        let safe = both.filter { FileManager.default.fileExists(atPath: $0.dst.path) }.map(\.src)
        if go { close(); m.trash(safe) } else { m.cable = cable }
    }

    /// Upp till tre mappar på måldisken där flest av kortets filer redan ligger.
    /// Förslag som bara bygger på filerna som ska kopieras:
    /// 1. en mapp på måldisken med samma namn som deras mapp på källdisken,
    /// 2. mappar på måldisken där kortets filer från samma inspelningsdagar redan ligger.
    private func findHints() async {
        let jobs = m.forwardJobs(Forward(from: from.id, to: to.id, folder: to.disk.root, layout: .flat))
        let srcRoot = from.disk.root.standardizedFileURL.path + "/", dstRoot = to.disk.root.standardizedFileURL.path + "/"
        let srcDirs = Set(jobs.compactMap { j -> URL? in
            m.items[j.0].copies.first { $0.standardizedFileURL.path.hasPrefix(srcRoot) }?.deletingLastPathComponent()
        })
        let days = Set(jobs.map { dayString($0.1.date) })
        var sameDay: [URL: Int] = [:]
        for it in m.items where days.contains(dayString(it.file.date)) {
            for u in it.copies where u.standardizedFileURL.path.hasPrefix(dstRoot) { sameDay[u.deletingLastPathComponent(), default: 0] += 1 }
        }
        let dest = to.disk
        let named = await Task.detached { foldersNamed(Set(srcDirs.map(\.lastPathComponent)), on: dest) }.value
        var out: [Hint] = []
        if srcDirs.count == 1, let name = srcDirs.first?.lastPathComponent {
            for d in named.prefix(2) {
                out.append(Hint(folder: d, layout: .flat, why: L("same name as on \(from.disk.name)", "samma namn som på \(from.disk.name)")))
            }
        } else if srcDirs.count > 1 {
            // Flera mappar: föreslå den mapp på måldisken som redan har flest av dem som undermappar.
            let parents = Dictionary(grouping: named, by: { $0.deletingLastPathComponent() }).max { $0.value.count < $1.value.count }
            if let (p, kids) = parents, kids.count > 1 {
                out.append(Hint(folder: p, layout: .mirror, why: L("\(kids.count) of the folders are already here", "\(kids.count) av mapparna finns redan här")))
            }
        }
        for (d, n) in sameDay.sorted(by: { $0.value > $1.value }).prefix(3 - out.count) where !out.contains(where: { $0.folder == d }) {
            out.append(Hint(folder: d, layout: .flat, why: L("\(n) files from the same days", "\(n) filer från samma dagar")))
        }
        hints = out
    }

    private func pick() {
        let cable = m.cable
        defer { m.cable = cable }
        guard let u = m.pickFolder(in: folder ?? to.disk.root) else { return }
        // Mappen måste ligga på disken kabeln går till, annars stämmer inte kabeln med vart filerna tar vägen.
        let root = to.disk.root.standardizedFileURL
        outside = !u.standardizedFileURL.path.hasPrefix(root.path + "/") && u.standardizedFileURL != root
        if !outside { m.cableFolder = u }
    }

    private func option(_ l: Forward.Layout, _ icon: String, _ title: String) -> some View {
        Button { m.cableLayout = l } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(layout == l ? ok : fg)
            .background(RoundedRectangle(cornerRadius: 4).fill(layout == l ? ok.opacity(0.12) : panel))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(layout == l ? ok : panelLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(layout == l ? .isSelected : [])
    }
}
