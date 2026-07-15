import Foundation

enum SecretVaultError: LocalizedError {
    case keychainWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychainWriteFailed(let account):
            return "Could not save the credential for \"\(account)\" to the Keychain."
        }
    }
}

/// The app's single entry point for reading and writing provider credentials.
///
/// On a stably signed build (Developer ID / Apple Development) every secret
/// lives inside ONE keychain item holding a JSON dictionary, so macOS asks
/// for authorization at most once per binary instead of once per credential.
/// Legacy per-account items migrate into the unified item on first read and
/// are then removed. On an ad-hoc/unsigned build (local `swift build`)
/// secrets live in the 0600 development file, because Keychain ACLs wouldn't
/// survive the next rebuild. Under ATTACHE_UI_TEST the real keychain is never
/// touched at all, so automated runs cannot churn item ACLs or hang on an
/// authorization dialog.
enum AttacheSecretVault {
    /// Account name of the unified item. Distinct from any legacy per-account
    /// name so migration can tell them apart.
    private static let unifiedAccount = "unified-vault-v1"
    private static let lock = NSLock()
    private static var cache: [String: String]?
    private static var uiTestStore: [String: String] = [:]

    private static var uiTestMode: Bool {
        ProcessInfo.processInfo.environment["ATTACHE_UI_TEST"] == "1"
    }

    private static var storesInKeychain: Bool {
        CodeSignatureInfo.isStablySigned
    }

    static func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if uiTestMode { return uiTestStore[account] }
        guard storesInKeychain else {
            return AttacheDevelopmentSecretStore.read(account: account)
        }
        return loadUnifiedLocked()[account]
    }

    static func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if uiTestMode {
            if trimmed.isEmpty { uiTestStore.removeValue(forKey: account) } else { uiTestStore[account] = trimmed }
            return
        }
        guard storesInKeychain else {
            try AttacheDevelopmentSecretStore.save(value, account: account)
            return
        }
        var all = loadUnifiedLocked()
        if trimmed.isEmpty {
            all.removeValue(forKey: account)
        } else {
            all[account] = trimmed
        }
        try persistUnifiedLocked(all)
    }

    static func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        if uiTestMode {
            uiTestStore.removeValue(forKey: account)
            return
        }
        guard storesInKeychain else {
            AttacheDevelopmentSecretStore.delete(account: account)
            return
        }
        var all = loadUnifiedLocked()
        all.removeValue(forKey: account)
        _ = try? persistUnifiedLocked(all)
    }

    // MARK: - Unified keychain item

    private static func loadUnifiedLocked() -> [String: String] {
        if let cache { return cache }
        var all = readUnifiedItem() ?? migrateLegacyKeychainItemsLocked()
        // Secrets saved by earlier ad-hoc builds live in the development
        // file; fold them in once and drop the plaintext copy.
        let development = AttacheDevelopmentSecretStore.loadAll()
        if !development.isEmpty {
            for (account, value) in development where all[account] == nil {
                all[account] = value
            }
            if (try? persistUnifiedLocked(all)) != nil {
                AttacheDevelopmentSecretStore.deleteFile()
            }
        }
        cache = all
        return all
    }

    @discardableResult
    private static func persistUnifiedLocked(_ all: [String: String]) throws -> Bool {
        cache = all
        let data = (try? JSONEncoder().encode(all)) ?? Data("{}".utf8)
        guard let blob = String(data: data, encoding: .utf8),
              AttacheSecretStore.writeVaultSecret(blob, account: unifiedAccount) else {
            throw SecretVaultError.keychainWriteFailed(unifiedAccount)
        }
        return true
    }

    private static func readUnifiedItem() -> [String: String]? {
        guard let blob = AttacheSecretStore.readVaultSecret(account: unifiedAccount),
              let data = blob.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Reads every legacy per-account item into the unified item, then removes
    /// the legacy items whose values made it across. This is the last time the
    /// keychain can prompt once per credential; afterwards there is one item.
    private static func migrateLegacyKeychainItemsLocked() -> [String: String] {
        var all: [String: String] = [:]
        var migrated: [String] = []
        for account in AttacheSecretStore.allVaultAccounts() where account != unifiedAccount {
            if let value = AttacheSecretStore.readVaultSecret(account: account), !value.isEmpty {
                all[account] = value
                migrated.append(account)
            }
        }
        if (try? persistUnifiedLocked(all)) != nil {
            for account in migrated {
                AttacheSecretStore.deleteVaultSecret(account: account)
            }
        }
        return all
    }
}
