import Foundation
import Testing
@testable import EscaleCore

@Suite struct SSHKeyDiscoveryTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("escale-sshkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, _ content: String) throws {
        try Data(content.utf8).write(to: url)
    }

    @Test func dossierAbsentRenvoieVide() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("escale-absent-\(UUID().uuidString)", isDirectory: true)
        #expect(SSHKeyDiscovery.discover(in: missing).isEmpty)
    }

    @Test func entetesOpenSSHEtPEMEtCompagnonPub() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir.appendingPathComponent("id_ed25519"), "-----BEGIN OPENSSH PRIVATE KEY-----\nfactice\n-----END OPENSSH PRIVATE KEY-----\n")
        try write(dir.appendingPathComponent("id_ed25519.pub"), "ssh-ed25519 AAAA test@example\n")

        try write(dir.appendingPathComponent("prod_rsa"), "-----BEGIN RSA PRIVATE KEY-----\nfactice\n-----END RSA PRIVATE KEY-----\n")
        try write(dir.appendingPathComponent("deploy_ec"), "-----BEGIN EC PRIVATE KEY-----\nfactice\n-----END EC PRIVATE KEY-----\n")
        try write(dir.appendingPathComponent("pkcs8_key"), "-----BEGIN PRIVATE KEY-----\nfactice\n-----END PRIVATE KEY-----\n")

        // Clé reconnue uniquement par la présence de son fichier `.pub` compagnon.
        try write(dir.appendingPathComponent("hardware_key"), "donnees-opaques-cle\n")
        try write(dir.appendingPathComponent("hardware_key.pub"), "sk-ssh-ed25519@openssh.com AAAA test\n")

        let discovered = SSHKeyDiscovery.discover(in: dir)
        let names = discovered.map(\.filename)
        #expect(names == ["id_ed25519", "deploy_ec", "hardware_key", "pkcs8_key", "prod_rsa"])

        let ed = try #require(discovered.first { $0.filename == "id_ed25519" })
        #expect(ed.hasPublicKey == true)
        #expect(ed.id == ed.path)
        #expect(ed.path == dir.appendingPathComponent("id_ed25519").path)

        let rsa = try #require(discovered.first { $0.filename == "prod_rsa" })
        #expect(rsa.hasPublicKey == false)

        let hw = try #require(discovered.first { $0.filename == "hardware_key" })
        #expect(hw.hasPublicKey == true)
    }

    @Test func filtreFichiersNonClesEtSurdimensionnes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Fichiers standards de ~/.ssh à ignorer même si un en-tête factice y figure.
        for excluded in ["known_hosts", "known_hosts.old", "authorized_keys", "authorized_keys2", "config", "environment", "rc", ".DS_Store"] {
            try write(dir.appendingPathComponent(excluded), "-----BEGIN OPENSSH PRIVATE KEY-----\nfactice\n")
        }
        // Suffixes exclus.
        for excluded in ["id_ed25519.pub", "id_ed25519-cert.pub", "client.cert", "id_rsa.bak", "id_rsa.old", "id_rsa~"] {
            try write(dir.appendingPathComponent(excluded), "-----BEGIN OPENSSH PRIVATE KEY-----\nfactice\n")
        }
        // Fichier texte quelconque sans en-tête ni .pub.
        try write(dir.appendingPathComponent("notes"), "juste une note\n")
        // Clé publique ou certificat sans extension .pub.
        try write(dir.appendingPathComponent("pubkey_no_ext"), "-----BEGIN PUBLIC KEY-----\nfactice\n")
        try write(dir.appendingPathComponent("cert_no_ext"), "-----BEGIN CERTIFICATE-----\nfactice\n")
        // Sous-dossier (même avec un .pub compagnon).
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sous_dossier"), withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("sous_dossier.pub"), "ssh-ed25519 AAAA\n")
        // Lien symbolique cassé.
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("lien_casse"), withDestinationURL: dir.appendingPathComponent("introuvable"))
        // Fichier trop gros (> 64 Kio).
        var huge = Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8)
        huge.append(Data(repeating: 0x41, count: SSHKeyDiscovery.maxKeyFileSize + 16))
        try huge.write(to: dir.appendingPathComponent("trop_gros"))

        // Une seule vraie clé valide.
        try write(dir.appendingPathComponent("valide"), "-----BEGIN OPENSSH PRIVATE KEY-----\nfactice\n")

        let discovered = SSHKeyDiscovery.discover(in: dir)
        #expect(discovered.map(\.filename) == ["valide"])
    }

    @Test func triClesStandardPuisAlphabetique() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let names = ["zeta_key", "id_dsa", "alpha_key", "id_rsa", "id_ecdsa", "id_ed25519", "Beta_key"]
        for name in names {
            try write(dir.appendingPathComponent(name), "-----BEGIN OPENSSH PRIVATE KEY-----\nfactice\n")
        }

        let discovered = SSHKeyDiscovery.discover(in: dir)
        #expect(discovered.map(\.filename) == [
            "id_ed25519",
            "id_ecdsa",
            "id_rsa",
            "id_dsa",
            "alpha_key",
            "Beta_key",
            "zeta_key",
        ])
    }

    @Test func abreviationCheminUtilisateur() {
        #expect(SSHKeyDiscovery.abbreviatedPath("/Users/alice/.ssh/id_ed25519", homeDirectory: "/Users/alice") == "~/.ssh/id_ed25519")
        #expect(SSHKeyDiscovery.abbreviatedPath("/Users/alice/.ssh/id_ed25519", homeDirectory: "/Users/alice/") == "~/.ssh/id_ed25519")
        #expect(SSHKeyDiscovery.abbreviatedPath("/Users/alice", homeDirectory: "/Users/alice") == "~")
        #expect(SSHKeyDiscovery.abbreviatedPath("/Users/alice2/.ssh/id_ed25519", homeDirectory: "/Users/alice") == "/Users/alice2/.ssh/id_ed25519")
        #expect(SSHKeyDiscovery.abbreviatedPath("/etc/ssh/key", homeDirectory: "/Users/alice") == "/etc/ssh/key")
    }
}
