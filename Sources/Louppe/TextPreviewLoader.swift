import Foundation
import Darwin

/// One bounded reader/parser lane, used only for the document currently open.
/// Documents never enter the image caches or run an XML/HTML interpreter.
actor TextPreviewLoader {
    static let shared = TextPreviewLoader()
    static let maximumBytes = 1_048_576

    enum PreviewError: LocalizedError {
        case tooLarge
        case unsupportedEncoding
        case changed
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return L10n.text("This file is larger than the 1 MB text preview limit. Open it in another app to read it.")
            case .unsupportedEncoding:
                return L10n.text("This file couldn’t be read as UTF-8 or Unicode text. Open it in another app to check its encoding.")
            case .changed:
                return L10n.text("This file changed since the folder was scanned. Rescan the folder to see the current text.")
            case .unreadable:
                return L10n.text("This file couldn’t be read. Check that it is still available and that Louppe has permission to open it.")
            }
        }
    }

    func load(item: PhotoItem) throws -> AttributedString {
        try Task.checkCancellation()
        let before = try FileOperationJournal.captureIdentity(at: item.primaryURL)
        if let expected = item.primaryFile.scannedIdentity, before != expected {
            throw PreviewError.changed
        }
        let descriptor = item.primaryURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw PreviewError.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { throw PreviewError.unreadable }
        guard UInt64(info.st_dev) == before.systemNumber,
              UInt64(info.st_ino) == before.fileNumber else { throw PreviewError.changed }
        guard info.st_size <= Self.maximumBytes else { throw PreviewError.tooLarge }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw PreviewError.tooLarge }
        guard try FileOperationJournal.captureIdentity(at: item.primaryURL) == before else {
            throw PreviewError.changed
        }
        try Task.checkCancellation()
        let source = try Self.decode(data)
        guard ["md", "markdown"].contains(item.primaryURL.pathExtension.lowercased()) else {
            return AttributedString(source)
        }
        return try AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )
    }

    static func decode(_ data: Data) throws -> String {
        let encoding: String.Encoding
        let offset: Int
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            encoding = .utf32BigEndian; offset = 4
        } else if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            encoding = .utf32LittleEndian; offset = 4
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; offset = 2
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; offset = 2
        } else {
            encoding = .utf8; offset = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        }
        guard let text = String(data: data.dropFirst(offset), encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw PreviewError.unsupportedEncoding
        }
        return text
    }
}
