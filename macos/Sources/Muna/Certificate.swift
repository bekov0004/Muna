import CryptoKit
import Foundation
import MunaCore
import Security

/// Muna's own certificate for LocalSend (shared/protocols/localsend.md): self-signed, made once with
/// the openssl tool every Mac has, kept with Muna's data. Its SHA-256 is this device's fingerprint.
final class LocalSendCertificate {
    let identity: SecIdentity
    let certificate: SecCertificate
    let fingerprint: String

    private static let password = "muna"

    private init(identity: SecIdentity, certificate: SecCertificate) {
        self.identity = identity
        self.certificate = certificate
        let der = SecCertificateCopyData(certificate) as Data
        fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The certificate, made first if needed. nil when it cannot be made (then receiving is off).
    static func load() -> LocalSendCertificate? {
        let folder = DataDirectory.url
        let certFile = folder.appendingPathComponent("localsend-cert.pem")
        let keyFile = folder.appendingPathComponent("localsend-key.pem")
        let bundleFile = folder.appendingPathComponent("localsend.p12")
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fileManager.fileExists(atPath: bundleFile.path) {
                try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", keyFile.path, "-out", certFile.path,
                         "-days", "36500", "-subj", "/CN=Muna"])
                try run(["pkcs12", "-export", "-inkey", keyFile.path, "-in", certFile.path, "-out", bundleFile.path,
                         "-passout", "pass:\(password)"])
                for file in [keyFile, bundleFile] {
                    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }
            let data = try Data(contentsOf: bundleFile)
            var options: [String: Any] = [kSecImportExportPassphrase as String: password]
            if #available(macOS 15.0, *) {
                options[kSecImportToMemoryOnly as String] = true
            }
            var items: CFArray?
            guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
                  let first = (items as? [[String: Any]])?.first,
                  let value = first[kSecImportItemIdentity as String] else { return nil }
            let identity = value as! SecIdentity
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            return LocalSendCertificate(identity: identity, certificate: certificate)
        } catch {
            NSLog("Muna: no LocalSend certificate: \(error)")
            return nil
        }
    }

    /// For the TLS questions of other devices when Muna sends.
    var credential: URLCredential {
        URLCredential(identity: identity, certificates: [certificate], persistence: .forSession)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Muna", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl \(arguments.first ?? "") failed"])
        }
    }
}
