// Compile alongside the vendored FlutterSecureStorage.swift on macOS. The CI
// job supplies a temporary default keychain; never use real application data.
import Foundation
import Security

@main
struct MacOSKeychainSmoke {
    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func success(_ response: FlutterSecureStorageResponse, _ operation: String) {
        require(response.status == errSecSuccess, "\(operation): OSStatus \(response.status)")
    }

    static func main() {
        require(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
                "Run this native smoke test in the isolated macOS CI keychain.")
        let service = "dev.harborssh.keychain-smoke.\(UUID().uuidString)"
        let storage = FlutterSecureStorage()
        func params(_ key: String?) -> KeychainQueryParameters {
            KeychainQueryParameters(
                key: key, service: service, isSynchronizable: false,
                accessibilityLevel: "unlocked", usesDataProtectionKeychain: false,
                shouldReturnData: true
            )
        }
        defer { _ = storage.deleteAll(params: params(nil)) }

        // The regression: a missing bundle/journal must be null, not an
        // entitlement failure from a fallback to a different keychain.
        for key in ["harbor.secrets.bundle.v1", "harbor.sync.pending.v1"] {
            let absent = storage.read(params: params(key))
            success(absent, "read absent \(key)")
            require(absent.value == nil, "Absent record must return nil")
            switch storage.containsKey(params: params(key)) {
            case .success(let exists): require(!exists, "Absent record exists")
            case .failure(let error): fatalError("containsKey: \(error.status)")
            }
        }

        // Seed an old file-based record using Security directly, rather than
        // writing and reading through the same plugin implementation.
        let legacyKey = "harbor.credentials.legacy"
        let legacy: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: legacyKey,
            kSecValueData: Data("legacy-test-secret".utf8),
        ]
        require(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess, "Seed legacy item")
        let restored = storage.read(params: params(legacyKey))
        success(restored, "read legacy item")
        require(restored.value as? String == "legacy-test-secret", "Legacy value changed")
        let all = storage.readAll(params: params(nil))
        success(all, "enumerate legacy items")
        require((all.value as? [String: String])?[legacyKey] == "legacy-test-secret", "Legacy item omitted")

        let bundle = params("harbor.secrets.bundle.v1")
        success(storage.write(params: bundle, value: "test-bundle"), "create bundle")
        success(storage.write(params: bundle, value: "updated-bundle"), "update bundle")
        let updated = storage.read(params: bundle)
        success(updated, "read updated bundle")
        require(updated.value as? String == "updated-bundle", "Updated value mismatch")
        success(storage.delete(params: bundle), "delete bundle")
        let deleted = storage.read(params: bundle)
        success(deleted, "read deleted bundle")
        require(deleted.value == nil, "Deleted value returned")
        success(storage.delete(params: bundle), "delete absent bundle")
        print("macOS legacy Keychain smoke test passed")
    }
}
