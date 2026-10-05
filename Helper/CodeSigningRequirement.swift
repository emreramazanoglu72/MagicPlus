//
//  CodeSigningRequirement.swift
//  MagicPlusHelper
//

import Foundation
import Security

/// Builds the requirement a client has to satisfy before the helper will talk to it.
///
/// The team identifier is read from the helper's own signature rather than baked in: anyone
/// who forks this project signs both halves with their own certificate, and hardcoding one
/// team would either lock them out or invite them to loosen the check.
enum CodeSigningRequirement {
    static func forApplication() -> String? {
        guard let teamIdentifier = ownTeamIdentifier() else { return nil }
        return "identifier \"\(HelperConstants.applicationBundleIdentifier)\""
            + " and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let details = information as? [String: Any]
        else { return nil }

        return details[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
