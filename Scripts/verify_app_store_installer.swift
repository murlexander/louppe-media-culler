import CryptoKit
import Foundation
import Security

enum InstallerVerificationError: Error, CustomStringConvertible {
    case rejected(String)
    var description: String {
        switch self { case .rejected(let reason): return reason }
    }
}

func checkedOutput(_ tool: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, value in value }
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw InstallerVerificationError.rejected("\(tool) rejected the package: \(String(decoding: data, as: UTF8.self))")
    }
    return data
}

func certificateFingerprint(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

func embeddedInstallerCertificates(_ package: String) throws -> [Data] {
    let toc = try checkedOutput("/usr/bin/xar", ["--dump-toc=-", "-f", package])
    let document = try XMLDocument(data: toc, options: .nodeLoadExternalEntitiesNever)
    let rsa = try document.nodes(forXPath: "/xar/toc/signature")
    let cms = try document.nodes(forXPath: "/xar/toc/x-signature")
    guard rsa.count == 1, cms.count <= 1,
          (rsa[0] as? XMLElement)?.attribute(forName: "style")?.stringValue == "RSA",
          cms.isEmpty || (cms[0] as? XMLElement)?.attribute(forName: "style")?.stringValue == "CMS" else {
        throw InstallerVerificationError.rejected("Expected one RSA signature and at most one CMS signature.")
    }
    let namespace = "http://www.w3.org/2000/09/xmldsig#"
    let path = ["KeyInfo", "X509Data", "X509Certificate"].map {
        "*[local-name()='\($0)']"
    }.joined(separator: "/")
    let chains = try (rsa + cms).map { signature -> [Data] in
        let nodes = try signature.nodes(forXPath: "./" + path)
        guard nodes.count == 3, nodes.allSatisfy({
            $0.uri == namespace && $0.parent?.uri == namespace && $0.parent?.parent?.uri == namespace
        }) else {
            throw InstallerVerificationError.rejected("Expected the installer, WWDR and Apple root certificates.")
        }
        return try nodes.map { node in
            let encoded = (node.stringValue ?? "").filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
                throw InstallerVerificationError.rejected("Invalid embedded installer certificate.")
            }
            return data
        }
    }
    guard chains.allSatisfy({ $0 == chains[0] }) else {
        throw InstallerVerificationError.rejected("The RSA and CMS certificate chains differ.")
    }
    return chains[0]
}

func reportedSignerFingerprint(_ output: Data) throws -> String {
    let lines = String(decoding: output, as: UTF8.self).components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let leaf = lines.firstIndex(where: { $0.hasPrefix("1. ") }),
          let label = lines[leaf...].firstIndex(of: "SHA256 Fingerprint:") else {
        throw InstallerVerificationError.rejected("pkgutil did not identify the verified signer.")
    }
    let fingerprint = lines[(label + 1)...].prefix { line in
        !line.isEmpty && line.filter { !$0.isWhitespace }.allSatisfy { $0.isHexDigit }
    }.joined().filter { !$0.isWhitespace }.uppercased()
    guard fingerprint.count == 64 else {
        throw InstallerVerificationError.rejected("pkgutil did not report a complete signer fingerprint.")
    }
    return fingerprint
}

func verifyInstallerCertificates(_ data: [Data], expectedHash: String, expectedIdentity: String) throws {
    guard expectedHash.range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil,
          let leafData = data.first,
          certificateFingerprint(leafData) == expectedHash.uppercased() else {
        throw InstallerVerificationError.rejected("The embedded installer certificate does not match the selected identity.")
    }
    let certificates = try data.map { bytes -> SecCertificate in
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
            throw InstallerVerificationError.rejected("Could not read the embedded certificate chain.")
        }
        return certificate
    }
    guard let leaf = certificates.first,
          SecCertificateCopySubjectSummary(leaf) as String? == expectedIdentity else {
        throw InstallerVerificationError.rejected("The installer certificate has the wrong name or team.")
    }
    // Apple's SecPolicy.list maps .105 to MacDistributionInstaller: the WWDR
    // intermediate marker .6.2.1 and submission installer leaf marker .6.1.8.
    // https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.list
    guard let policy = SecPolicyCreateWithProperties("1.2.840.113635.100.1.105" as CFString, nil) else {
        throw InstallerVerificationError.rejected("Apple's MacDistributionInstaller policy is unavailable.")
    }
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
          let trust else {
        throw InstallerVerificationError.rejected("Could not evaluate the installer certificate chain.")
    }
    // Use current system trust, validity and revocation checks; no custom
    // anchors, verification date or trust exceptions.
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else {
        throw InstallerVerificationError.rejected("The certificate chain fails Apple's MacDistributionInstaller policy: \(String(describing: error))")
    }
    var result = SecTrustResultType.invalid
    guard SecTrustGetTrustResult(trust, &result) == errSecSuccess, result == .unspecified else {
        throw InstallerVerificationError.rejected("The installer requires a local trust override.")
    }
}

func verifyInstallerPackage(_ package: String, expectedHash: String, expectedIdentity: String) throws {
    // pkgutil validates the signature. Its human-readable Status wording is
    // not a certificate-type test; .105 and the exact embedded leaf are.
    let signature = try checkedOutput("/usr/sbin/pkgutil", ["--check-signature", package])
    let certificates = try embeddedInstallerCertificates(package)
    let embeddedFingerprint = SHA256.hash(data: certificates[0]).map { String(format: "%02X", $0) }.joined()
    guard try reportedSignerFingerprint(signature) == embeddedFingerprint else {
        throw InstallerVerificationError.rejected("The verified signer differs from the embedded installer certificate.")
    }
    try verifyInstallerCertificates(certificates, expectedHash: expectedHash, expectedIdentity: expectedIdentity)
}

#if !APP_STORE_INSTALLER_TESTS
@main
struct InstallerVerifier {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else {
                throw InstallerVerificationError.rejected("Usage: verifier package installer-sha1 installer-identity")
            }
            try verifyInstallerPackage(CommandLine.arguments[1], expectedHash: CommandLine.arguments[2],
                                       expectedIdentity: CommandLine.arguments[3])
        } catch {
            FileHandle.standardError.write(Data("Installer verification failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
