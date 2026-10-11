/// Public, credential-free identity of an SSH session offered by the AI window.
class AiWindowSession {
  const AiWindowSession({
    required this.id,
    required this.hostName,
    required this.endpoint,
    required this.connected,
    this.running = false,
    this.waitingApproval = false,
  });

  final String id;
  final String hostName;
  final String endpoint;
  final bool connected;
  final bool running;
  final bool waitingApproval;

  /// Wire form used by the `harbor/ai_window` mirror. Only the fields above
  /// cross the channel; no password, key or provider profile is ever included.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'hostName': hostName,
    'endpoint': endpoint,
    'connected': connected,
    'running': running,
    'waitingApproval': waitingApproval,
  };

  factory AiWindowSession.fromJson(Map<Object?, Object?> json) =>
      AiWindowSession(
        id: '${json['id'] ?? ''}',
        hostName: '${json['hostName'] ?? ''}',
        endpoint: '${json['endpoint'] ?? ''}',
        connected: json['connected'] == true,
        running: json['running'] == true,
        waitingApproval: json['waitingApproval'] == true,
      );
}

/// Session selection supplied by the detached engine, not by ordinary AI tasks.
/// Its state changes are notified through the existing task controller.
abstract interface class AiWindowSessionSelection {
  List<AiWindowSession> get sessions;
  String? get sessionId;
  bool get selectingSession;
  Future<bool> selectSession(String id);
}
