# Harbor SSH macOS Keychain compatibility patch

Based on flutter_secure_storage_darwin 0.4.3 (BSD-3-Clause; see LICENSE).
The upstream Dart workspace declaration is removed for this standalone copy.

## Missing-record queries must stay in the selected keychain

Harbor uses `usesDataProtectionKeychain: false` with the existing service
`dev.harborssh.credentials`. In 0.4.3, `read` and `containsKey` try a
`kSecAttrAccessControl` fallback after a normal query returns `errSecItemNotFound`.
This attribute excludes the file-based keychain and can route the fallback to
the data-protection keychain, where this app has no Keychain Sharing entitlement.
A missing bundle or sync journal can therefore fail instead of returning null.

Apple's implementation explicitly excludes the file-based keychain when
`kSecAttrAccessControl` is present:
https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecItem.cpp
(search for `Check presence of kSecAttrTokenID and kSecAttrAccessControl`).

The patch skips the AccessControl and accessibility-class fallback queries
only on macOS when data-protection storage is disabled. Direct queries, error
propagation, service/account identity, and all stored values remain unchanged.
Data-protection clients and iOS retain the upstream migration behavior.
No entitlement, access-control list, signing identity, or data reset is added.

## Current storage only

Harbor no longer enumerates or migrates older credential layouts. On macOS it
reads/writes only harbor.secrets.bundle.v1; a missing archive or entry is absent,
without falling back to individual old records. Other platforms use their
current per-key storage without unpacking an older bundle. Existing obsolete
records are not deleted automatically. See docs/macos-credentials.md.

The experimental file-based readAll workaround was removed together with the
app's migration code. Harbor's SecretBackend no longer exposes readAll.

## Validation

`tool/macos_keychain_smoke.swift` checks absent records and current-bundle
creation, update, reopening and deletion against the real Security framework.
The macOS build job runs it with a temporary CI-only keychain.
`test/startup_failure_test.dart` verifies redacted, actionable diagnostics.
`test/workspace_startup_test.dart` verifies failed recovery still blocks sync,
retains saved data, and supports retry after Keychain access is restored.

The native smoke test requires macOS and does not validate an end user's
existing Keychain authorization or a change in app signing identity.
