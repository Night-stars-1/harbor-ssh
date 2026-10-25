import 'terminal_ai.dart';

/// Optional capability of a session-bound [AiCommandExecutor] that can run
/// commands as root for the current turn.
///
/// Elevation always starts a dedicated SSH exec channel with its own writable
/// stdin; it never reuses the human terminal and never persists a password or
/// an authorization. The controller detects this interface so executors that
/// cannot elevate keep working without advertising the `request_root` tool.
abstract interface class AiPrivilegeExecutor implements AiCommandExecutor {
  /// Whether [execute] currently runs through a verified root channel.
  ///
  /// False before a successful [elevate], after [revokePrivilege], and as soon
  /// as the underlying channel closes or the turn is cancelled. Once
  /// elevation succeeded, losing the channel makes [execute] fail instead of
  /// silently running the command unprivileged.
  bool get elevated;

  /// Authenticates this turn's root channel with [password].
  ///
  /// The password is used once, only after sudo itself asks for it, and is
  /// never stored on the executor or forwarded to the model. Completes only
  /// after `id -u` on the new channel reports 0. Throws an [AiFailure] with a
  /// fixed, credential-free message otherwise.
  Future<void> elevate(String password);

  /// Closes the root channel immediately and cancels an authorization that is
  /// still opening or authenticating.
  ///
  /// Safe to call repeatedly and when no elevation is active. A late channel
  /// opened by a revoked attempt is closed instead of becoming usable, and a
  /// subsequent [elevate] starts immediately rather than waiting for the
  /// revoked attempt. A command already running will fail rather than continue
  /// with reduced privileges.
  void revokePrivilege();
}
