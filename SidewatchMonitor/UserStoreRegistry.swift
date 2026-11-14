import Foundation
import Darwin

/// Called from the extension's request/ingestion workers, never from an ES callback.
actor UserStoreRegistry {
    private var stores: [UInt32: ActivityStore] = [:]

    func store(for userID: UInt32) throws -> ActivityStore {
        if let store = stores[userID] { return store }
        let users = try Self.openUsersDirectory()
        defer { close(users) }
        let user = try Self.openPrivateDirectory(String(userID), beneath: users)
        defer { close(user) }
        var information = stat()
        let exists = fstatat(user, "activity.sqlite", &information, AT_SYMLINK_NOFOLLOW)
        if exists == 0 {
            guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == 0,
                  information.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
        } else if errno != ENOENT {
            throw Self.posixError()
        }
        let path = "/Library/Application Support/dev.shisheng.Sidewatch/Users/\(userID)/activity.sqlite"
        let store = try ActivityStore(path: path)
        for file in ["activity.sqlite", "activity.sqlite-wal", "activity.sqlite-shm"] {
            if fchmodat(user, file, 0o600, 0) != 0 && errno != ENOENT { throw Self.posixError() }
        }
        stores[userID] = store
        return store
    }

    /// Closes the user's store and deletes its database files and directory. The shared
    /// parent directories are removed too once no user remains. Used only after the user
    /// erased their data and is uninstalling the extension.
    func removeStore(for userID: UInt32) throws {
        if let store = stores.removeValue(forKey: userID) { try store.close() }
        let users = try Self.openUsersDirectory()
        defer { close(users) }
        let name = String(userID)
        let user = openat(users, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if user < 0 {
            guard errno == ENOENT else { throw Self.posixError() }
        } else {
            defer { close(user) }
            for file in ["activity.sqlite-wal", "activity.sqlite-shm", "activity.sqlite"] {
                if unlinkat(user, file, 0) != 0 && errno != ENOENT { throw Self.posixError() }
            }
        }
        if unlinkat(users, name, AT_REMOVEDIR) != 0 && errno != ENOENT { throw Self.posixError() }
        // Best effort: other users' stores keep the parents in place (ENOTEMPTY).
        let root = "/Library/Application Support/dev.shisheng.Sidewatch"
        if rmdir(root + "/Users") == 0 { _ = rmdir(root) }
    }

    func knownUserIDs() throws -> [UInt32] {
        let users = try Self.openUsersDirectory()
        defer { close(users) }
        let names = try FileManager.default.contentsOfDirectory(atPath: "/Library/Application Support/dev.shisheng.Sidewatch/Users")
        return names.compactMap { name in
            guard let uid = UInt32(name), String(uid) == name else { return nil }
            return uid
        }.sorted()
    }

    private static func openUsersDirectory() throws -> Int32 {
        guard geteuid() == 0 else { throw POSIXError(.EPERM) }
        let support = open("/Library/Application Support", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard support >= 0 else { throw posixError() }
        defer { close(support) }
        let root = try openPrivateDirectory("dev.shisheng.Sidewatch", beneath: support)
        defer { close(root) }
        return try openPrivateDirectory("Users", beneath: root)
    }

    private static func openPrivateDirectory(_ name: String, beneath parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw posixError() }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        guard information.st_uid == 0, information.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw POSIXError(.EPERM)
        }
        return descriptor
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
