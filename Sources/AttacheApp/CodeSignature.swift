import Foundation
import Security

/// Inspects the running binary's own code signature.
///
/// Keychain item ACLs are keyed to the creating app's code identity. A
/// Developer ID (or Apple Development) signature has a stable identity, anchored
/// to Apple + the bundle identifier + the Team Identifier, that survives
/// rebuilds and even certificate renewal. An ad-hoc / linker-only signature
/// (what `swift build` produces on Apple Silicon) has no Team Identifier and its
/// identity is the binary hash, which changes on every build, so items written
/// under one build can't be read by the next.
///
/// We therefore only persist secrets to the Keychain when the signature is
/// stable, and fall back to the on-disk development store otherwise.
enum CodeSignatureInfo {
    static let isStablySigned: Bool = {
        guard let info = signingInformation() else { return false }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            return false
        }
        if let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value {
            let adhoc: UInt32 = 0x2 // kSecCodeSignatureAdhoc
            if flags & adhoc != 0 { return false }
        }
        return true
    }()

    static let teamIdentifier: String? = {
        guard let team = signingInformation()?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            return nil
        }
        return team
    }()

    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}
