import Foundation
import Security

enum CompanionSecretStore {
    static let presentationAPIKeyService = "com.bryanlabs.attache.presentation"
    static let presentationAPIKeyAccount = "presentationLLMAPIKey"
    /// Service name for the unified secret vault (provider API keys, keyed by account).
    static let vaultService = "com.bryanlabs.attache.secrets"
    private static var cachedOPSecrets: [String: (value: String, expiresAt: Date)] = [:]
    private static let cacheLock = NSLock()
    /// 1Password secrets are cached briefly to avoid a Touch ID prompt per read,
    /// but evicted after this so a rotated secret is picked up (INF-157).
    private static let opCacheTTL: TimeInterval = 15 * 60

    /// Drop cached 1Password secrets (e.g. when the user changes provider settings).
    static func clearSecretCache() {
        cacheLock.lock()
        cachedOPSecrets.removeAll()
        cacheLock.unlock()
    }

    static func readVaultSecret(account: String) -> String? {
        readPresentationAPIKey(service: vaultService, account: account)
    }

    /// Account names of every item under the vault service. Asks for
    /// attributes only, so this never triggers a keychain authorization.
    static func allVaultAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Creates or updates the Keychain item for `account`. Returns false if the
    /// Keychain rejected the write (caller decides how to surface that).
    static func writeVaultSecret(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func deleteVaultSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: vaultService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readSecret(reference: String) -> String? {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReference.hasPrefix("op://") {
            return readOPSecret(reference: trimmedReference)
        }
        if trimmedReference.hasPrefix("keychain://") {
            return readKeychainReference(trimmedReference)
        }
        return nil
    }

    static func readPresentationAPIKey(
        service: String = presentationAPIKeyService,
        account: String = presentationAPIKeyAccount
    ) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readOPSecret(reference: String, timeoutSeconds: TimeInterval = 5) -> String? {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReference.hasPrefix("op://") else { return nil }

        cacheLock.lock()
        if let cached = cachedOPSecrets[trimmedReference] {
            if cached.expiresAt > Date() {
                cacheLock.unlock()
                return cached.value
            }
            cachedOPSecrets[trimmedReference] = nil   // expired
        }
        cacheLock.unlock()

        let helper = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/op-codex")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return nil
        }

        let process = Process()
        process.executableURL = helper
        process.arguments = ["read", trimmedReference]
        process.environment = helperEnvironment()

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completed.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard completed.wait(timeout: .now() + timeoutSeconds) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        cacheLock.lock()
        cachedOPSecrets[trimmedReference] = (trimmed, Date().addingTimeInterval(opCacheTTL))
        cacheLock.unlock()

        return trimmed
    }

    private static func readKeychainReference(_ reference: String) -> String? {
        guard let url = URL(string: reference),
              url.scheme == "keychain",
              let service = url.host,
              let account = url.pathComponents.dropFirst().first,
              !service.isEmpty,
              !account.isEmpty else {
            return nil
        }
        return readPresentationAPIKey(service: service, account: account)
    }

    private static func helperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let helperPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = currentPath.isEmpty ? helperPath : "\(helperPath):\(currentPath)"
        return environment
    }
}
