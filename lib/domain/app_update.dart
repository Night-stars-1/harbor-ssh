/// Numeric parts of a release version such as `v1.0.25` or `1.0.25+26`.
/// Build metadata and pre-release suffixes are ignored; null when malformed.
List<int>? parseAppVersion(String value) {
  var text = value.trim();
  if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
  final end = text.indexOf(RegExp(r'[+-]'));
  if (end >= 0) text = text.substring(0, end);
  if (text.isEmpty) return null;
  final parts = <int>[];
  for (final part in text.split('.')) {
    final number = int.tryParse(part);
    if (number == null || number < 0) return null;
    parts.add(number);
  }
  return parts;
}

/// Whether [candidate] is a strictly newer release than [current].
/// Missing trailing parts count as zero, so `1.1` equals `1.1.0`.
bool isNewerAppVersion(String candidate, String current) {
  final next = parseAppVersion(candidate);
  final installed = parseAppVersion(current);
  if (next == null || installed == null) return false;
  final length = next.length > installed.length
      ? next.length
      : installed.length;
  for (var i = 0; i < length; i++) {
    final a = i < next.length ? next[i] : 0;
    final b = i < installed.length ? installed[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}

/// Update behaviour stored only on this device.
class UpdatePreferences {
  const UpdatePreferences({this.autoCheck = true, this.skippedVersion = ''});

  /// Check GitHub Releases once at launch.
  final bool autoCheck;

  /// Release the user chose to skip; automatic prompts ignore exactly it.
  final String skippedVersion;

  UpdatePreferences copyWith({bool? autoCheck, String? skippedVersion}) =>
      UpdatePreferences(
        autoCheck: autoCheck ?? this.autoCheck,
        skippedVersion: skippedVersion ?? this.skippedVersion,
      );

  Map<String, Object> toJson() => {
    'autoCheck': autoCheck,
    'skippedVersion': skippedVersion,
  };

  factory UpdatePreferences.fromJson(Map<dynamic, dynamic> json) =>
      UpdatePreferences(
        autoCheck: json['autoCheck'] != false,
        skippedVersion: json['skippedVersion'] is String
            ? json['skippedVersion'] as String
            : '',
      );
}
