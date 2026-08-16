//
//  AppSupportDirectory.swift
//  MagicPlus
//

import Foundation

/// The app's Application Support folder, shared by every store.
///
/// The app shipped its first data as "tabmenu" before being renamed; that folder is moved
/// once so clipboard history, the shelf, layouts and rules survive the rename.
nonisolated enum AppSupportDirectory {
    static let folderName = "MagicPlus"
    private static let legacyFolderName = "tabmenu"

    static func url() -> URL {
        let fileManager = FileManager.default
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: current)
        }
        // The folder holds clipboard history and notes; keep it readable by this user only.
        // Attributes only apply on creation, so existing installs are tightened explicitly.
        try? fileManager.createDirectory(
            at: current,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        return current
    }
}
