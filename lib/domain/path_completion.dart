import 'package:xterm/xterm.dart';

import 'shell_input.dart';

class RemotePathEntry {
  const RemotePathEntry(this.name, {required this.isDirectory});
  final String name;
  final bool isDirectory;
}

class PathCompletionRequest {
  const PathCompletionRequest({
    required this.line,
    required this.directory,
    required this.prefix,
    required this.quote,
    required this.directoriesOnly,
  });
  final String line;
  final String directory;
  final String prefix;
  final String? quote;
  final bool directoriesOnly;

  String suffix(RemotePathEntry entry) {
    final remaining = entry.name.substring(prefix.length);
    final escaped = switch (quote) {
      "'" => remaining.replaceAll("'", "'\\''"),
      '"' => remaining.replaceAllMapped(RegExp(r'[\\"$`]'), (m) => '\\${m[0]}'),
      _ => remaining.replaceAllMapped(
        RegExp(r'[^a-zA-Z0-9_./\-]', unicode: true),
        (m) => '\\${m[0]}',
      ),
    };
    return '$escaped${entry.isDirectory ? '/' : ''}';
  }
}

/// Complete only at the end of a simple shell command with a known working
/// directory. Do not infer a directory from a previous command or from output.
PathCompletionRequest? readPathCompletion(Terminal terminal) {
  final input = readShellInput(terminal);
  if (input == null) return null;
  final command = RegExp(
    r'^(cd|ls|cat|less|head|tail|nano|vim|vi) +(?:-- +)?(.*)$',
  ).firstMatch(input.command);
  if (command == null) return null;
  final raw = command[2]!;
  var decoded = StringBuffer();
  String? quote;
  var escaped = false;
  for (final rune in raw.runes) {
    final char = String.fromCharCode(rune);
    if (escaped) {
      decoded.write(char);
      escaped = false;
    } else if (char == '\\' && quote != "'") {
      escaped = true;
    } else if (char == quote) {
      quote = null;
    } else if ((char == "'" || char == '"') && quote == null) {
      quote = char;
    } else if (quote == null && char == ' ') {
      // A second argument is not a valid cd destination.
      if (command[1] == 'cd') return null;
      decoded = StringBuffer();
    } else if (quote != "'" && r'$`;&|<>()*?[]{}'.contains(char)) {
      return null;
    } else {
      decoded.write(char);
    }
  }
  if (escaped) return null;
  final path = decoded.toString();
  if (path.startsWith('-') ||
      (path.startsWith('~') && !path.startsWith('~/') && path != '~') ||
      (path.startsWith('~') && (raw.startsWith("'") || raw.startsWith('"')))) {
    return null;
  }
  final slash = path.lastIndexOf('/');
  final parent = slash < 0 ? '' : path.substring(0, slash + 1);
  final cwd = input.directory;
  final directory = parent.startsWith('/') || parent.startsWith('~/')
      ? parent
      : parent.isEmpty
      ? cwd
      : '$cwd/$parent';
  return PathCompletionRequest(
    line: input.line,
    directory: directory,
    prefix: slash < 0 ? path : path.substring(slash + 1),
    quote: quote,
    directoriesOnly: command[1] == 'cd',
  );
}
