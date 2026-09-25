//
//  TerminalDropDelegate.swift
//  iGhostVT
//

import GhosttyTerminal
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What a drop on the terminal pastes: a path for everything that is, or
/// can be made into, a file; the text itself for a link or a snippet.
///
/// Replaces the library's drop handling (see `LockableTerminalView`), which
/// staged a copy of every file and refused folders outright. The rule here
/// goes by where the item lives:
///
/// - **On this Mac's disk** (a Finder drag, on Catalyst): the item's own
///   path, opened in place. Someone dragging `report.pdf` off the Desktop
///   wants `open` to see that file, not a duplicate the staging sweep
///   deletes a day later. A folder is a path the shell can already reach,
///   so it pastes the same way.
/// - **A file the shell cannot read** (Files on iOS, whose security-scoped
///   URL means nothing to a shell in another process): a copy under
///   `TerminalFileStaging.directory`, keeping the item's name — folders
///   included, copied whole.
/// - **Not a file at all** (a photo out of Photos, an image off a web page,
///   a Mail attachment): the bytes, written under the same directory and
///   named for their type, so the path ends in an extension a program can
///   go by.
/// - **An image, on iOS and iPadOS**: a PNG or JPEG is stored as it came;
///   anything else `UIImage` can decode — the HEIC every photo is — is
///   re-encoded as PNG first, because the programs a path gets pasted into
///   (an AI agent, mostly) read PNG and JPEG and nothing else. The Mac
///   pastes the file's own path and is left alone.
/// - **A link or a snippet of text**: pasted as it is, the way the library
///   did.
///
/// Paths go in shell-escaped and space-separated, with a trailing space so
/// the caret is ready for an argument instead of glued to the path.
@MainActor
final class TerminalDropDelegate: NSObject, UIDropInteractionDelegate {
    private weak var terminal: LockableTerminalView?

    init(terminal: LockableTerminalView) {
        self.terminal = terminal
    }

    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.items.contains { Payload(provider: $0.itemProvider) != nil }
    }

    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        let payloads = session.items.compactMap { Payload(provider: $0.itemProvider) }
        guard !payloads.isEmpty else { return }
        let directory = TerminalFileStaging.directory
        TerminalFileStaging.removeStaleFiles()
        Task { [weak self] in
            // Resolved together, pasted in drop order.
            let resolved = await withTaskGroup(of: (Int, Resolved?).self) { group in
                for (index, payload) in payloads.enumerated() {
                    group.addTask {
                        let resolved = await payload.resolve(stagingIn: directory)
                        return (index, resolved)
                    }
                }
                var results = [Resolved?](repeating: nil, count: payloads.count)
                for await pair in group {
                    let (index, result) = pair
                    results[index] = result
                }
                return results.compactMap(\.self)
            }
            guard let terminal = self?.terminal, !resolved.isEmpty else {
                AppLog.info(.drop, "drop skipped: nothing resolved from \(payloads.count) item(s)")
                return
            }
            let text = resolved.map(\.pasted).joined(separator: " ")
            let trailer = resolved.last?.isPath == true ? " " : ""
            AppLog.info(.drop, "drop pasting \(resolved.count) of \(payloads.count) item(s)")
            terminal.paste(text: text + trailer)
        }
    }

    /// One dropped item's contribution to the paste.
    private enum Resolved {
        case path(String)
        case text(String)

        var pasted: String {
            switch self {
            case let .path(path): TerminalDropDelegate.shellEscaped(path)
            case let .text(text): text
            }
        }

        var isPath: Bool {
            if case .path = self {
                return true
            }
            return false
        }
    }

    /// What one item provider offers, sorted into the kinds above.
    private struct Payload: @unchecked Sendable {
        let provider: NSItemProvider

        /// The type a file would be asked for: an image ahead of anything
        /// else the item registers (a copied photo also carries its URL),
        /// else the first real type that is not a bare link. Text stays a
        /// file type only when the item is a named file — a `.txt` out of
        /// Files — rather than a snippet.
        let fileType: UTType?
        let hasFileURL: Bool
        let isText: Bool
        let isLink: Bool

        init?(provider: NSItemProvider) {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init).filter { !$0.isDynamic }
            guard !types.isEmpty else { return nil }
            self.provider = provider
            hasFileURL = types.contains { $0.conforms(to: .fileURL) }
            let named = !(provider.suggestedName ?? "").isEmpty
            isText = types.contains { $0.conforms(to: .text) } && !named
            isLink = types.contains { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }
            fileType = types.first { $0.conforms(to: .image) }
                ?? types.first { type in
                    type.conforms(to: .item)
                        && !type.conforms(to: .url)
                        && (named || !type.conforms(to: .text))
                }
            // An item that is none of these — a tab dragged out of the
            // sidebar or the strip (`TabReorder.itemType`), which conforms
            // to nothing — is not a drop the terminal accepts, so the drag
            // shows no copy badge over it and pastes nothing.
            guard hasFileURL || isText || isLink || fileType != nil else { return nil }
        }

        func resolve(stagingIn directory: URL) async -> Resolved? {
            #if targetEnvironment(macCatalyst)
                if hasFileURL || fileType != nil, let path = await inPlacePath() {
                    return .path(path)
                }
            #endif
            if let fileType {
                #if !targetEnvironment(macCatalyst)
                    if fileType.conforms(to: .image), let path = await stagedImage(of: fileType, in: directory) {
                        return .path(path)
                    }
                #endif
                if let path = await stagedCopy(of: fileType, in: directory) {
                    return .path(path)
                }
                if let path = await stagedData(of: fileType, in: directory) {
                    return .path(path)
                }
            }
            if isLink, let url = await loadURL() {
                return .text(url.absoluteString)
            }
            if isText || fileType == nil, let text = await loadText() {
                return .text(text)
            }
            return nil
        }

        // MARK: In place

        /// The file's own path: the provider's in-place representation when
        /// the source grants one, else the `public.file-url` it registered.
        /// Either way the file has to exist where the shell would look.
        private func inPlacePath() async -> String? {
            if let fileType, provider.hasItemConformingToTypeIdentifier(fileType.identifier) {
                let inPlace: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadInPlaceFileRepresentation(
                        forTypeIdentifier: fileType.identifier,
                    ) { url, isInPlace, error in
                        if let error {
                            AppLog.warning(.drop, "in-place load failed for \(fileType.identifier): \(error)")
                        }
                        continuation.resume(returning: isInPlace ? url : nil)
                    }
                }
                if let inPlace, FileManager.default.fileExists(atPath: inPlace.path) {
                    return inPlace.path
                }
            }
            guard hasFileURL else { return nil }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let error {
                        AppLog.warning(.drop, "file-url load failed: \(error)")
                    }
                    continuation.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.path
        }

        // MARK: Staging

        /// A copy of the provider's file, under `directory`. The copy has to
        /// happen inside the completion: the representation is gone the
        /// moment it returns.
        private func stagedCopy(of type: UTType, in directory: URL) async -> String? {
            let suggested = provider.suggestedName
            return await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    guard let url else {
                        AppLog.warning(.drop, "file load failed for \(type.identifier): \(String(describing: error))")
                        continuation.resume(returning: nil)
                        return
                    }
                    // Named for the file's own type when the one asked for is
                    // abstract (`public.image`, `public.data`) and so has no
                    // extension to give.
                    let actual = type.preferredFilenameExtension == nil
                        ? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType).flatMap { $0.conforms(to: type) ? $0 : nil }
                        : nil
                    let name = Self.fileName(suggested: suggested ?? url.lastPathComponent, type: actual ?? type)
                    continuation.resume(returning: Self.store(name: name, in: directory) {
                        try FileManager.default.copyItem(at: url, to: $0)
                    })
                }
            }
        }

        /// The provider's bytes, written as a file named for their type —
        /// for an item with no file behind it.
        private func stagedData(of type: UTType, in directory: URL) async -> String? {
            let suggested = provider.suggestedName
            return await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    guard let data else {
                        AppLog.warning(.drop, "data load failed for \(type.identifier): \(String(describing: error))")
                        continuation.resume(returning: nil)
                        return
                    }
                    let name = Self.fileName(suggested: suggested, type: type)
                    continuation.resume(returning: Self.store(name: name, in: directory) {
                        try data.write(to: $0, options: .atomic)
                    })
                }
            }
        }

        #if !targetEnvironment(macCatalyst)
            /// The provider's image, as a file a program can read: PNG and
            /// JPEG bytes as they are, anything else re-encoded as PNG when
            /// `UIImage` decodes it. Names go by the bytes, not by the type
            /// the provider was asked for — a drag can register the abstract
            /// `public.image`, which has no extension of its own. Returns
            /// `nil` when the data cannot be loaded or decoded, and the copy
            /// path takes over with whatever the provider has.
            private func stagedImage(of type: UTType, in directory: URL) async -> String? {
                let suggested = provider.suggestedName
                return await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                        guard let data, !data.isEmpty else {
                            AppLog.warning(
                                .drop,
                                "image load failed for \(type.identifier): \(String(describing: error))",
                            )
                            continuation.resume(returning: nil)
                            return
                        }
                        let actual = Self.imageType(of: data) ?? type
                        if actual.conforms(to: .png) || actual.conforms(to: .jpeg) {
                            let name = Self.fileName(suggested: suggested, type: actual)
                            continuation.resume(returning: Self.store(name: name, in: directory) {
                                try data.write(to: $0, options: .atomic)
                            })
                            return
                        }
                        guard let image = UIImage(data: data), let png = Self.upright(image).pngData() else {
                            AppLog.warning(
                                .drop,
                                "image decode failed for \(actual.identifier); storing the bytes as they are",
                            )
                            continuation.resume(returning: nil)
                            return
                        }
                        AppLog.info(.drop, "re-encoding \(actual.identifier) as PNG")
                        let name = Self.fileName(suggested: Self.strippingImageExtension(suggested), type: .png)
                        continuation.resume(returning: Self.store(name: name, in: directory) {
                            try png.write(to: $0, options: .atomic)
                        })
                    }
                }
            }

            /// The concrete type of image bytes, read from the bytes.
            private static func imageType(of data: Data) -> UTType? {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let identifier = CGImageSourceGetType(source) as String?,
                      let type = UTType(identifier), !type.isDynamic
                else { return nil }
                return type
            }

            /// The image drawn the way up it is meant to be seen. PNG has no
            /// orientation tag, so a photo whose pixels are stored sideways
            /// has to be turned before it is encoded.
            private static func upright(_ image: UIImage) -> UIImage {
                guard image.imageOrientation != .up else { return image }
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = image.scale
                return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: image.size))
                }
            }

            /// `IMG_0001.HEIC` → `IMG_0001`, so the PNG the bytes became is
            /// not named for the format they left behind.
            private static func strippingImageExtension(_ name: String?) -> String? {
                guard let name, extensionMatches((name as NSString).pathExtension, .image) else { return name }
                return (name as NSString).deletingPathExtension
            }
        #endif

        private func loadURL() async -> URL? {
            guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL) as URL?)
                }
            }
        }

        private func loadText() async -> String? {
            guard provider.canLoadObject(ofClass: NSString.self) else { return nil }
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    let text = (object as? NSString) as String?
                    continuation.resume(returning: text?.isEmpty == false ? text : nil)
                }
            }
        }

        /// The name a staged item gets: its own when it has one, else
        /// `image`, `folder`, or `file` — always ending in the type's
        /// extension unless the name brought its own. Path separators and
        /// control characters become `_`; the shell escape covers the rest.
        ///
        /// A name "brought its own" only when what follows its last dot is
        /// an extension the type would wear: `IMG_0001.HEIC` for an image,
        /// yes; `Screenshot 2026-08-30 at 10.23.45` — the name iPadOS gives
        /// a screenshot — no, or the `.png` would be lost to the seconds.
        static func fileName(suggested: String?, type: UTType) -> String {
            let fallback = type.conforms(to: .image) ? "image" : type.conforms(to: .directory) ? "folder" : "file"
            let raw = (suggested?.isEmpty == false ? suggested : nil) ?? fallback
            let safe = String(
                raw.map { $0 == "/" || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true ? "_" : $0 },
            )
            guard !type.conforms(to: .directory),
                  !extensionMatches((safe as NSString).pathExtension, type),
                  let ext = type.preferredFilenameExtension
            else {
                return safe
            }
            return "\(safe).\(ext)"
        }

        /// Whether `ext` is a real file extension for `type`: one the system
        /// knows (not a dynamic `dyn.*` it made up on the spot) and whose
        /// type conforms to the one being written.
        static func extensionMatches(_ ext: String, _ type: UTType) -> Bool {
            guard !ext.isEmpty, let known = UTType(filenameExtension: ext), !known.isDynamic else { return false }
            return known.conforms(to: type)
        }

        /// Serialises name choice and write: provider completions arrive on
        /// concurrent queues, and two items with the same name would
        /// otherwise be handed the same path.
        private static let storeLock = NSLock()

        /// Writes one item under `directory` at a name nothing else took —
        /// `report.pdf`, then `report-2.pdf` — readable by whoever can reach
        /// the directory (the shell may not be the app's user), and returns
        /// its path, or `nil` when the write fails.
        static func store(name: String, in directory: URL, write: (URL) throws -> Void) -> String? {
            storeLock.lock()
            defer { storeLock.unlock() }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755],
                )
                let destination = uniqueURL(name: name, in: directory)
                try write(destination)
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                try FileManager.default.setAttributes(
                    [.posixPermissions: isDirectory.boolValue ? 0o755 : 0o644],
                    ofItemAtPath: destination.path,
                )
                return destination.path
            } catch {
                AppLog.error(.drop, "staged write failed for \(name): \(error)")
                return nil
            }
        }

        static func uniqueURL(name: String, in directory: URL) -> URL {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = directory.appendingPathComponent(name)
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                let numbered = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                candidate = directory.appendingPathComponent(numbered)
                counter += 1
            }
            return candidate
        }
    }

    /// Backslash-escapes what a POSIX shell would otherwise read as syntax.
    ///
    /// The character set is Ghostty's `Shell.escape`, mirrored here because
    /// the library keeps its own copy internal. Backslashes rather than
    /// quotes: this lands at a live prompt someone keeps editing, not in a
    /// command line being assembled.
    nonisolated static func shellEscaped(_ path: String) -> String {
        let sensitive: Set<Character> = [
            "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
            "!", "#", "$", "&", ";", "|", "*", "?", "\t",
        ]
        var result = ""
        result.reserveCapacity(path.utf8.count)
        for character in path {
            if sensitive.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
