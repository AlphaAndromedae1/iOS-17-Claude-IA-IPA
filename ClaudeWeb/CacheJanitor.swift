import Foundation
import WebKit

/// Keeps the app's stored data from growing until only a reinstall gets rid of it.
///
/// WebKit keeps claude.ai's files (scripts, style sheets, images, with a new set after every
/// claude.ai update), the page's offline databases and service worker caches, and the app caches
/// the style sheets it downloads for the iOS 17 fix. All of that can be thrown away: claude.ai
/// downloads or rebuilds it. Cookies and local storage are never cleared, so you stay signed in
/// and keep your settings.
@MainActor
enum CacheJanitor {

    /// Clear automatically when the app's stored data passes this size...
    static let sizeLimit: Int64 = 150 * 1024 * 1024
    /// ...or when it was last cleared this long ago.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Coming back to the app checks again only after this long.
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    /// Website data that's safe to throw away. Not cookies, local or session storage.
    static let clearableTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeFileSystem,
    ]

    private static let lastCleanedKey = "CacheJanitor.LastCleaned"
    private static var lastChecked: Date?
    private static var cleaning = false

    /// The size measured most recently, for Settings. Nil until something has measured it.
    private(set) static var lastMeasuredSize: Int64?

    static var lastCleaned: Date? {
        UserDefaults.standard.object(forKey: lastCleanedKey) as? Date
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Clears the cache if it's grown past `sizeLimit` or is older than `maxAge`. With `throttled`,
    /// does nothing if it last checked less than six hours ago. `completion` says whether it cleared.
    static func cleanIfNeeded(throttled: Bool = false, completion: @escaping (_ cleared: Bool) -> Void) {
        if !AppSettings.autoClearCache || cleaning {
            completion(false)
            return
        }
        if throttled, let lastChecked, Date().timeIntervalSince(lastChecked) < checkInterval {
            completion(false)
            return
        }
        lastChecked = Date()
        measure { size in
            let age = lastCleaned.map { Date().timeIntervalSince($0) } ?? .infinity
            if size > sizeLimit {
                clean(reason: "The app's data had reached \(format(size)), over the \(format(sizeLimit)) limit") {
                    completion(true)
                }
            } else if age > maxAge {
                clean(reason: lastCleaned == nil ? "It had never been cleared" : "It was last cleared over a week ago") {
                    completion(true)
                }
            } else {
                completion(false)
            }
        }
    }

    /// Clears everything in `clearableTypes`, the app's own download cache and old temporary files,
    /// then notes the sizes before and after in the debug log.
    static func clean(reason: String, completion: @escaping () -> Void) {
        guard !cleaning else {
            completion()
            return
        }
        cleaning = true
        measure { before in
            WKWebsiteDataStore.default().removeData(ofTypes: clearableTypes, modifiedSince: .distantPast) {
                URLCache.shared.removeAllCachedResponses()
                removeOldTemporaryFiles()
                UserDefaults.standard.set(Date(), forKey: lastCleanedKey)
                measure { after in
                    cleaning = false
                    DebugLog.shared.info(
                        "Storage", "Cleared \(format(max(0, before - after))) of cache",
                        details: "\(reason).\nBefore: \(format(before)). After: \(format(after)).\n"
                            + "Kept: cookies and local storage, so you stay signed in."
                    )
                    completion()
                }
            }
        }
    }

    /// Adds up the app's Library and temporary folders on a background queue.
    static func measure(completion: @escaping (Int64) -> Void) {
        let folders = storageFolders()
        DispatchQueue.global(qos: .utility).async {
            let size = folders.reduce(Int64(0)) { $0 + folderSize($1) }
            Task { @MainActor in
                lastMeasuredSize = size
                completion(size)
            }
        }
    }

    nonisolated static func storageFolders() -> [URL] {
        let fileManager = FileManager.default
        return [fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0], fileManager.temporaryDirectory]
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Temporary files more than an hour old. Newer ones may be a photo being attached right now.
    private static func removeOldTemporaryFiles() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-60 * 60)
        guard let items = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: item)
            }
        }
    }
}
