//
//  MediaStore.swift
//  SMS TN
//
//  Cache-all media policy (decided for v2): every attachment is
//  downloaded at receive/sync time and kept on disk so the full history
//  is readable offline. Files live in Application Support/SMS TN/Media.
//

import Foundation
import GRDB
import os

actor MediaStore {
    private let db: AppDatabase
    private let bridge: BridgeClient
    private let directory: URL
    private let log = Logger(subsystem: "macDroid.SMS-TN", category: "media")
    private var draining = false

    init(db: AppDatabase, bridge: BridgeClient) throws {
        self.db = db
        self.bridge = bridge
        directory = try AppDatabase.defaultDirectory()
            .appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated func fileURL(for localFileName: String) -> URL {
        directory.appendingPathComponent(localFileName)
    }

    func url(for media: MediaRecord) -> URL? {
        guard let name = media.localFileName else { return nil }
        let url = fileURL(for: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Kicks the download queue; safe to call often.
    func drainQueue() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        while true {
            let batch = (try? await db.pendingMedia(limit: 4)) ?? []
            if batch.isEmpty { return }
            for var media in batch {
                do {
                    guard let key = media.decryptionKey else {
                        media.downloadState = MediaRecord.DownloadState.failed.rawValue
                        try await db.updateMedia(media)
                        continue
                    }
                    let data = try await bridge.downloadMedia(mediaID: media.mediaID, keyBase64: key)
                    let name = sanitizedFileName(for: media)
                    try data.write(to: fileURL(for: name), options: .atomic)
                    media.localFileName = name
                    media.downloadState = MediaRecord.DownloadState.downloaded.rawValue
                    try await db.updateMedia(media)
                } catch {
                    log.warning("Media download failed for \(media.mediaID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    media.downloadAttempts += 1
                    media.downloadState = media.downloadAttempts >= 5
                        ? MediaRecord.DownloadState.failed.rawValue
                        : MediaRecord.DownloadState.pending.rawValue
                    try? await db.updateMedia(media)
                }
            }
            // Small pause between batches to stay polite.
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Re-marks failed downloads as pending (manual retry).
    func retryFailed() async {
        // downloadAttempts is reset so the queue picks them up again.
        try? await db.pool.write { db in
            try db.execute(sql: """
                UPDATE media SET downloadState = 'pending', downloadAttempts = 0
                WHERE downloadState = 'failed'
                """)
        }
        await drainQueue()
    }

    /// Removes files whose DB rows are gone (after hard-delete mirroring).
    func garbageCollect() async {
        guard let referenced = try? await db.referencedMediaFiles() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func sanitizedFileName(for media: MediaRecord) -> String {
        let ext: String
        if let fileName = media.fileName, let dotExt = fileName.split(separator: ".").last,
           dotExt.count <= 5, fileName.contains(".") {
            ext = String(dotExt)
        } else {
            ext = Self.extensionFor(mimeType: media.mimeType ?? "")
        }
        let safeID = media.mediaID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return ext.isEmpty ? safeID : "\(safeID).\(ext)"
    }

    nonisolated static func extensionFor(mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/bmp", "image/x-ms-bmp": return "bmp"
        case "video/mp4": return "mp4"
        case "video/3gpp": return "3gp"
        case "video/webm": return "webm"
        case "audio/aac": return "aac"
        case "audio/amr": return "amr"
        case "audio/mp3", "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/ogg": return "ogg"
        case "application/pdf": return "pdf"
        case "text/vcard": return "vcf"
        case "text/plain": return "txt"
        default:
            return String(mimeType.split(separator: "/").last ?? "")
        }
    }
}
