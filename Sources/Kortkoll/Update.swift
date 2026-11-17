import AppKit
import Foundation

/// En nyare version på GitHub. Anteckningarna är release-texten.
struct Release: Equatable {
    let tag: String
    let notes: String
    let zip: URL
    let page: URL
    var version: String { versionParts(tag).map(String.init).joined(separator: ".") }
}

/// "v0.3-beta" -> [0, 3]
func versionParts(_ s: String) -> [Int] {
    s.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
}

func isNewer(_ tag: String, than current: String) -> Bool {
    let a = versionParts(tag), b = versionParts(current)
    guard !b.isEmpty else { return false } // dev-byggen tjatar aldrig
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// Releaserna är prereleases, så /releases/latest hittar dem inte. Listan kommer nyast först.
func newestRelease(in json: Data, after current: String) -> Release? {
    guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
    for r in list where (r["draft"] as? Bool) != true {
        guard let tag = r["tag_name"] as? String, isNewer(tag, than: current),
              let assets = r["assets"] as? [[String: Any]],
              let zip = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".zip") }).flatMap(URL.init(string:)),
              let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
        return Release(tag: tag, notes: r["body"] as? String ?? "", zip: zip, page: page)
    }
    return nil
}

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var available: Release?
    @Published var showSheet = false
    @Published var installing = false
    @Published var error: String?

    func check() async {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/joeland2/wilderloader/releases?per_page=10")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let r = newestRelease(in: data, after: appVersion) else { return }
        available = r
        // "Senare" gömmer rutan för just den versionen. Den lilla knappen finns kvar.
        showSheet = UserDefaults.standard.string(forKey: "skippedUpdate") != r.tag
    }

    func later() {
        if let r = available { UserDefaults.standard.set(r.tag, forKey: "skippedUpdate") }
        showSheet = false
    }

    /// Laddar ner zippen, byter ut appen (den gamla hamnar i papperskorgen) och startar om.
    /// Går något fel öppnas release-sidan så att man kan ladda ner för hand.
    func install() async {
        guard let r = available, !installing else { return }
        installing = true; error = nil
        do {
            let (zip, _) = try await URLSession.shared.download(from: r.zip)
            let here = try await Task.detached { try Updater.replaceApp(with: zip) }.value
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", here.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            installing = false
            self.error = L("Couldn't update by itself. The download page is open instead.", "Kunde inte uppdatera av sig själv. Nedladdningssidan har öppnats i stället.")
            NSWorkspace.shared.open(r.page)
        }
    }

    private struct Failure: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    /// Körs utanför huvudtråden så att fönstret inte fryser medan zippen packas upp.
    nonisolated static func replaceApp(with zip: URL) throws -> URL {
        let here = Bundle.main.bundleURL
        guard here.pathExtension == "app" else { throw Failure("Not running from an app bundle") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wilderloader-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path)
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw Failure(L("The download had no app in it.", "Nedladdningen innehöll ingen app."))
        }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: here, resultingItemURL: &trashed)
        do { try run("/usr/bin/ditto", app.path, here.path) } catch {
            if let old = trashed as URL? { try? FileManager.default.moveItem(at: old, to: here) }
            throw error
        }
        return here
    }

    nonisolated private static func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw Failure("\(tool) \(p.terminationStatus)") }
    }
}

func testUpdate() {
    precondition(isNewer("v0.3-beta", than: "0.2"))
    precondition(!isNewer("v0.2-beta", than: "0.2"))
    precondition(!isNewer("v0.2-beta", than: "0.10"))
    precondition(isNewer("v1.0", than: "0.9.9"))
    precondition(!isNewer("v9.9", than: "dev"))
    let json = """
    [{"tag_name":"v0.4-beta","draft":true,"assets":[],"html_url":"https://x/4"},
     {"tag_name":"v0.3-beta","draft":false,"body":"New stuff","html_url":"https://x/3","assets":[{"browser_download_url":"https://x/a.txt"},{"browser_download_url":"https://x/W.zip"}]},
     {"tag_name":"v0.2-beta","draft":false,"body":"","html_url":"https://x/2","assets":[{"browser_download_url":"https://x/old.zip"}]}]
    """.data(using: .utf8)!
    let r = newestRelease(in: json, after: "0.2")
    precondition(r?.tag == "v0.3-beta" && r?.zip.absoluteString == "https://x/W.zip" && r?.notes == "New stuff" && r?.version == "0.3")
    precondition(newestRelease(in: json, after: "0.3") == nil)
}
