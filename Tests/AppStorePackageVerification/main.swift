import Foundation
import Security

func expectRejection(_ label: String, containing text: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        guard String(describing: error).contains(text) else { throw error }
        print("Passed: \(label)")
        return
    }
    throw InstallerVerificationError.rejected("Unexpectedly accepted \(label).")
}

do {
    guard CommandLine.arguments.count == 5 else {
        throw InstallerVerificationError.rejected("Usage: tests signed-package installer-sha1 installer-identity public-application-certificate")
    }
    let package = CommandLine.arguments[1]
    let hash = CommandLine.arguments[2]
    let identity = CommandLine.arguments[3]
    try verifyInstallerPackage(package, expectedHash: hash, expectedIdentity: identity)
    print("Passed: exact signed submission package and system trust")
    try expectRejection("wrong selected identity", containing: "does not match the selected identity") {
        try verifyInstallerPackage(package, expectedHash: String(repeating: "0", count: 40), expectedIdentity: identity)
    }
    var certificates = try embeddedInstallerCertificates(package)
    let applicationData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
    guard let application = SecCertificateCreateWithData(nil, applicationData as CFData),
          let applicationIdentity = SecCertificateCopySubjectSummary(application) as String? else {
        throw InstallerVerificationError.rejected("Invalid public application certificate fixture.")
    }
    certificates[0] = applicationData
    // The replacement leaf passes its own exact hash/name checks, but an
    // Apple Distribution app certificate must fail the installer policy.
    try expectRejection("application certificate under installer policy", containing: "fails Apple's MacDistributionInstaller policy") {
        try verifyInstallerCertificates(certificates, expectedHash: certificateFingerprint(applicationData),
                                        expectedIdentity: applicationIdentity)
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-installer-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let toc = try XMLDocument(data: checkedOutput("/usr/bin/xar", ["--dump-toc=-", "-f", package]),
                              options: .nodeLoadExternalEntitiesNever)
    let offset = Int(try toc.nodes(forXPath: "/xar/toc/signature/offset").first!.stringValue!)!
    var bytes = try Data(contentsOf: URL(fileURLWithPath: package))
    let headerSize = bytes[4..<6].reduce(0) { ($0 << 8) | Int($1) }
    let compressedSize = bytes[8..<16].reduce(0) { ($0 << 8) | Int($1) }
    bytes[headerSize + compressedSize + offset] ^= 1
    let rsaOnly = temporary.appendingPathComponent("rsa-only.pkg")
    try bytes.write(to: rsaOnly)
    try verifyInstallerPackage(rsaOnly.path, expectedHash: hash, expectedIdentity: identity)
    print("Observed: intact active CMS permits legacy RSA-only corruption")
    // Flip a byte at the end of the CMS DER object, inside its signature,
    // preserving ASN.1 framing and avoiding unused package-signature padding.
    let cmsOffset = Int(try toc.nodes(forXPath: "/xar/toc/x-signature/offset").first!.stringValue!)!
    let cmsStart = headerSize + compressedSize + cmsOffset
    let lengthBytes = Int(bytes[cmsStart + 1] & 0x7f)
    let cmsLength = bytes[(cmsStart + 2)..<(cmsStart + 2 + lengthBytes)].reduce(0) { ($0 << 8) | Int($1) }
    let cmsEnd = cmsStart + 2 + lengthBytes + cmsLength
    let tampered = temporary.appendingPathComponent("both-signatures.pkg")
    bytes[cmsEnd - 1] ^= 1
    try bytes.write(to: tampered)
    try expectRejection("tampered active CMS and legacy RSA signatures", containing: "/usr/sbin/pkgutil rejected the package") {
        try verifyInstallerPackage(tampered.path, expectedHash: hash, expectedIdentity: identity)
    }
    let cmsOnly = temporary.appendingPathComponent("cms-only.pkg")
    bytes[headerSize + compressedSize + offset] ^= 1
    try bytes.write(to: cmsOnly)
    try expectRejection("tampered active CMS signature", containing: "/usr/sbin/pkgutil rejected the package") {
        try verifyInstallerPackage(cmsOnly.path, expectedHash: hash, expectedIdentity: identity)
    }
    print("All installer verification checks passed.")
} catch {
    FileHandle.standardError.write(Data("Installer verification tests failed: \(error)\n".utf8))
    exit(1)
}
