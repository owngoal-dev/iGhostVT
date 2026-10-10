//
//  KeyboardBarPictures.swift
//  iGhostVT
//

import Foundation
import UIKit

/// The pictures custom accessory keys are filled with, one PNG per key in
/// Application Support. A key's code names its file; the store sweeps files
/// no key names any more.
@MainActor
enum KeyboardBarPictures {
    /// Three times the bar's 36-point button: enough for any screen.
    private static let pixelSide: CGFloat = 108

    private static var cache: [String: UIImage] = [:]

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyboardBarPictures", isDirectory: true)
    }

    static func image(named name: String) -> UIImage? {
        if let image = cache[name] {
            return image
        }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        cache[name] = image
        return image
    }

    /// Writes `image`, scaled so its short side fills the button, and returns
    /// the name a key's code keeps; `nil` when it cannot be written.
    static func save(_ image: UIImage) -> String? {
        let scale = pixelSide / max(1, min(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.pngData() else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        cache[name] = scaled
        return name
    }

    /// Deletes every picture not in `names`.
    static func removeAll(except names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            cache[file] = nil
        }
    }
}
