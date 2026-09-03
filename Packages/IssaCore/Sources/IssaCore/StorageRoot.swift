import Foundation

/// The one directory everything this app writes lives under.
///
/// Application Support on iOS and macOS: the system never purges it, so a book
/// downloaded for a flight is still there when there is no network to fetch it
/// again. Each writer marks its own subtree as excluded from backup.
///
/// **Caches on tvOS**, because that is the platform's contract rather than a
/// preference. An Apple TV app may write only to Caches and tmp; a
/// `createDirectory` under Application Support fails with "You don't have
/// permission to save the file …", which is exactly the error a reader saw
/// when the first download on a real Apple TV failed. The tvOS *simulator*
/// does not enforce this — it writes to the Mac's filesystem — which is why
/// every simulator run passed while the device could not save a single file.
///
/// tvOS may reclaim Caches under storage pressure, so on that platform a
/// download, the local catalogue or the log can vanish between launches. There
/// is no alternative: the choice on tvOS is purgeable storage or none. Every
/// reader of these files already copes with absence — a book is downloaded
/// again, the catalogue is rebuilt from the next fetch, a log starts over.
///
/// Nothing persists an absolute path under this root across launches: the store
/// is reopened by server key, a download resolves its destination when it
/// completes, fonts are re-registered from the directory at each launch. Moving
/// the root therefore needs no migration — and on tvOS there is nothing to
/// migrate, because no write under the old root ever succeeded.
public enum StorageRoot {
    public static let url: URL = {
        #if os(tvOS)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }()

    /// `root/<name>/`. Does not create it; every caller creates what it needs
    /// with intermediates, which also creates the root itself.
    public static func directory(_ name: String) -> URL {
        url.appending(path: name, directoryHint: .isDirectory)
    }

    /// True where the system may reclaim this root. For documentation and
    /// tests — no behaviour branches on it.
    public static let isPurgeable: Bool = {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }()
}
