import AppKit
import Foundation
import EscaleCore

/// Scénario `--selftest-hosteditor <dossier>` : écrit `<dossier>/result.json` (ok, checks, failed, details).
///
/// Ouvre la feuille d'édition pour chaque protocole et chaque onglet (captures PNG, clair puis sombre), vérifie qu'un
/// hôte modifié puis enregistré garde tous ses champs (aller-retour), que le bandeau bascule les onglets et les
/// sections, et que la taille de la feuille ne bouge pas. Piloté par l'API interne (`HostEditorForm.current`),
/// sans événement clavier ni souris, sans activation de l'app.
@MainActor
final class HostEditorSelfTest {
    let directory: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var sheetSizes: Set<String> = []

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-hosteditor] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Capture de la feuille (ou de la fenêtre principale à défaut) ; enregistre aussi sa taille.
    private func screenshot(_ name: String) async {
        guard let main = model.mainWindow else { return }
        let win = main.attachedSheet ?? main
        win.orderFrontRegardless()
        await sleep(0.45)
        win.contentView?.needsDisplay = true
        win.displayIfNeeded()
        if main.attachedSheet != nil { sheetSizes.insert("\(Int(win.frame.width))x\(Int(win.frame.height))") }
        let path = "\(directory)/\(name).png"
        // Rendu de la vue elle-même (ni permission d'écran, ni dépendance à ce qui recouvre la fenêtre : `screencapture -l`
        // ne sait pas viser une feuille). Les zones non peintes sont posées sur le fond de fenêtre du thème courant.
        if let view = win.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            win.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
               let data = out.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        }
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    /// Ouvre l'éditeur et renvoie son formulaire une fois affiché.
    private func openEditor(_ request: EditorRequest, hostID: UUID? = nil) async -> HostEditorForm? {
        model.editor = request
        let ok = await wait(10) {
            guard let f = HostEditorForm.current else { return false }
            return hostID == nil || f.hostID == hostID
        }
        guard ok else { return nil }
        await sleep(0.2)
        return HostEditorForm.current
    }

    private func closeEditor() async {
        model.editor = nil
        _ = await wait(10) { HostEditorForm.current == nil }
    }

    private func slug(_ t: HostEditorTab) -> String {
        switch t {
        case .basic: "basique"
        case .advanced: "avance"
        case .terminal: "terminal"
        case .network: "reseau"
        case .protocolSettings: "protocole"
        }
    }

    private func json(_ h: HostProfile) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(h)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    // MARK: Hôtes de recette (tous les champs hors défauts)

    private func fixtures(folder: UUID) -> [HostProfile] {
        let relay = UUID()
        let sshID = UUID(), kcID = UUID()
        let tunnels = [
            TunnelSpec(kind: .local, bindPort: 18080, destinationHost: "intranet.example", destinationPort: 80, name: "Intranet", autoStart: true),
            TunnelSpec(kind: .dynamic, bindPort: 11080, name: "SOCKS"),
        ]
        let ssh = HostProfile(
            id: sshID, name: "Recette SSH", host: "ssh.example.com", port: 2222, user: "deploy",
            auth: .keyFile(path: "/Users/test/.ssh/id_recette"), jumpHosts: ["admin@bastion:2200", "autre-bastion"],
            tags: ["prod", "web"], folderID: folder, tunnels: tunnels, x11Forwarding: true,
            startupCommand: "tmux attach || tmux new")
        let kc = HostProfile(
            id: kcID, name: "Recette Trousseau", host: "kc.example.com", user: "root",
            auth: .keychainPassword(account: AuthKeychain.passwordAccount(for: kcID)), tags: ["kc"])
        let telnet = HostProfile(
            id: relay, name: "Recette Telnet", host: "switch.example", port: 2323, user: "admin", tags: ["reseau"], folderID: folder,
            connectionProtocol: .telnet,
            telnet: TelnetSettings(terminalType: "vt100", lineEnding: .crlf, connectTimeout: 20, viaSSHHostID: sshID))
        let serial = HostProfile(
            name: "Recette serie", host: "/dev/cu.recette", tags: ["labo"], connectionProtocol: .serial,
            serial: SerialSettings(devicePath: "/dev/cu.recette", baudRate: 9600, dataBits: 7, parity: .even, stopBits: 2,
                                   flowControl: .hardware, localEcho: true, lineEnding: .crlf))
        var vncSettings = VNCSettings(); vncSettings.viaSSHHostID = sshID; vncSettings.viewOnly = true; vncSettings.shared = false
        let vnc = HostProfile(name: "Recette VNC", host: "127.0.0.1", port: 5901, tags: ["bureau"], folderID: folder,
                              connectionProtocol: .vnc, vnc: vncSettings)
        var rdpSettings = RDPSettings()
        rdpSettings.displayMode = .fixedSize; rdpSettings.width = 1280; rdpSettings.height = 800
        rdpSettings.multiMonitor = true; rdpSettings.redirectClipboard = false
        rdpSettings.sharedFolders = ["/tmp/partage-recette"]; rdpSettings.gatewayHostname = "gw.example.com"
        let rdp = HostProfile(name: "Recette RDP", host: "win.example.com", port: 3390, user: "CORP\\alice", tags: ["win"],
                              connectionProtocol: .rdp, rdp: rdpSettings)
        return [ssh, kc, telnet, serial, vnc, rdp]
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        win.orderFrontRegardless()
        _ = await wait(10) { model.library.isLoaded }
        check("fenetre_principale", true)
        NSApp.appearance = NSAppearance(named: .aqua)

        guard let folder = model.library.addFolder(name: "Recette", parentID: nil) else {
            check("dossier_cree", false); return finish()
        }
        let hosts = fixtures(folder: folder.id)
        for h in hosts { model.library.upsert(h) }
        check("hotes_de_recette_en_bibliotheque", hosts.allSatisfy { model.library.host($0.id) != nil })

        // 1. Chaque hôte : chaque onglet (clair), aller-retour d'un hôte modifié puis enregistré.
        for h in hosts {
            let p = h.connectionProtocol
            guard let form = await openEditor(.editHost(h), hostID: h.id) else { check("\(p.rawValue)_editeur_ouvert", false); continue }
            check("\(p.rawValue)_editeur_ouvert", true)
            check("\(p.rawValue)_protocole_charge", form.connectionProtocol == p)
            check("\(p.rawValue)_onglets", form.tabs == HostEditorTab.tabs(for: p), "\(form.tabs.map(slug))")
            check("\(p.rawValue)_formulaire_valide", form.errors.isEmpty, "\(form.errors)")
            for t in form.tabs {
                form.tab = t
                await screenshot("\(p.rawValue)-\(slug(t))-clair")
            }
            // Variante sombre : tous les onglets du SSH, l'onglet de réglages des autres.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            for t in (p == .ssh ? form.tabs : [form.tabs.last!]) {
                form.tab = t
                await screenshot("\(p.rawValue)-\(slug(t))-sombre")
            }
            NSApp.appearance = NSAppearance(named: .aqua)

            form.tab = .basic
            form.name = h.name + " modifié"
            form.saveAction?()
            check("\(p.rawValue)_feuille_fermee_apres_enregistrement", await wait(10) { model.editor == nil })
            _ = await wait(10) { HostEditorForm.current == nil }
            var expected = h; expected.name = h.name + " modifié"
            let saved = model.library.host(h.id)
            check("\(p.rawValue)_aller_retour_tous_champs", saved == expected,
                  saved == expected ? "" : "attendu \(json(expected)) obtenu \(saved.map(json) ?? "absent")")
            // Second aller-retour sans modification : le profil ne bouge plus.
            if let again = saved, let f2 = await openEditor(.editHost(again), hostID: h.id) {
                f2.saveAction?()
                _ = await wait(10) { model.editor == nil }
                _ = await wait(10) { HostEditorForm.current == nil }
                check("\(p.rawValue)_reenregistrement_stable", model.library.host(h.id) == again)
            } else { check("\(p.rawValue)_reenregistrement_stable", false) }
        }

        // 2. Bandeau : le changement de protocole bascule onglets et sections.
        guard let nf = await openEditor(.newHost(folder: folder.id)) else { check("nouvel_hote_editeur_ouvert", false); return finish() }
        check("nouvel_hote_editeur_ouvert", true)
        check("nouvel_hote_ssh_par_defaut", nf.connectionProtocol == .ssh && nf.folderID == folder.id)
        check("nouvel_hote_hote_obligatoire", !nf.errors.isEmpty && nf.errors.contains { $0.contains("hôte") }, "\(nf.errors)")
        nf.tab = .advanced
        nf.selectProtocol(.telnet)
        check("bandeau_telnet_onglets", nf.tabs == [.basic, .protocolSettings], "\(nf.tabs.map(slug))")
        check("bandeau_onglet_avance_replie_sur_basique", nf.tab == .basic)
        nf.selectProtocol(.ssh)
        check("bandeau_retour_ssh_onglets", nf.tabs == [.basic, .advanced, .terminal, .network])
        nf.tab = .protocolSettings
        nf.selectProtocol(.vnc)
        check("bandeau_onglet_reglages_conserve_entre_protocoles", nf.tab == .protocolSettings)
        nf.selectProtocol(.serial)
        check("bandeau_serie_sans_hote", !nf.errors.contains { $0.contains("hôte") }, "\(nf.errors)")
        check("bandeau_serie_port_obligatoire", !nf.errors.isEmpty, "\(nf.errors)")
        for p in ConnectionProtocol.allCases {
            nf.selectProtocol(p)
            nf.tab = .basic
            await screenshot("bandeau-\(p.rawValue)")
            if p != .ssh {
                nf.tab = .protocolSettings
                await screenshot("bandeau-\(p.rawValue)-reglages")
            }
        }
        // Un hôte invalide ne s'enregistre pas.
        nf.selectProtocol(.ssh); nf.tab = .basic
        nf.hostname = "-oProxyCommand=x"
        check("hote_invalide_refuse", !nf.errors.isEmpty)
        let countBefore = model.library.library.hosts.count
        nf.saveAction?()
        await sleep(0.4)
        check("hote_invalide_non_enregistre", model.library.library.hosts.count == countBefore && model.editor != nil)
        // Création via le bandeau : VNC, les réglages des autres protocoles ne sont pas enregistrés.
        nf.selectProtocol(.telnet); nf.telnet.terminalType = "ansi"
        nf.selectProtocol(.vnc)
        nf.hostname = "vnc.example"; nf.name = "Nouveau VNC"; nf.vnc.viewOnly = true
        nf.saveAction?()
        check("creation_vnc_feuille_fermee", await wait(10) { model.editor == nil })
        let created = model.library.library.hosts.first { $0.name == "Nouveau VNC" }
        check("creation_vnc_protocole", created?.connectionProtocol == .vnc && created?.vnc?.viewOnly == true && created?.telnet == nil
              && created?.serial == nil && created?.rdp == nil && created?.folderID == folder.id, created.map(json) ?? "absent")
        _ = await wait(10) { HostEditorForm.current == nil }

        // 2b. Authentification par clé SSH directement dans l'onglet Basique.
        if let kf = await openEditor(.newHost(folder: folder.id)) {
            check("cle_basique_editeur_ouvert", kf.tab == .basic && kf.connectionProtocol == .ssh)
            kf.hostname = "key.example.com"
            kf.name = "Nouveau SSH Clé"
            kf.authChoice = .keyFile
            check("cle_basique_chemin_obligatoire", !kf.errors.isEmpty, "\(kf.errors)")
            kf.keyPath = "/Users/test/.ssh/id_ed25519"
            check("cle_basique_formulaire_valide", kf.errors.isEmpty, "\(kf.errors)")
            await screenshot("ssh-cle-basique-clair")
            kf.saveAction?()
            check("cle_basique_feuille_fermee", await wait(10) { model.editor == nil })
            let savedKeyHost = model.library.library.hosts.first { $0.name == "Nouveau SSH Clé" }
            check("cle_basique_auth_enregistree",
                  savedKeyHost?.auth == .keyFile(path: "/Users/test/.ssh/id_ed25519") && savedKeyHost?.folderID == folder.id,
                  savedKeyHost.map(json) ?? "absent")
            _ = await wait(10) { HostEditorForm.current == nil }
        } else {
            check("cle_basique_editeur_ouvert", false)
        }

        // 3. Taille de feuille stable.
        check("taille_de_feuille_stable", sheetSizes.count == 1, "\(sheetSizes.sorted())")

        NSApp.appearance = nil
        return finish()
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "total": checks.count,
            "passed": checks.filter { $0.1 }.count,
            "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { $1 }),
            "screenshots": shots,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return ok
    }
}
