import 'dart:convert';

import 'package:xterm/xterm.dart';

import 'shell_input.dart';

/// Session-local history. It is never written to a local plaintext file.
class CommandHistory {
  CommandHistory(this.terminal) {
    terminal.addListener(_echoChanged);
  }
  final Terminal terminal;
  final List<String> _commands = [];
  final List<CellAnchor> _pending = [];

  void add(String command) {
    if (!isHistoryCommand(command)) return;
    _commands.remove(command);
    _commands.add(command);
    if (_commands.length > 500) _commands.removeAt(0);
  }

  void mergeOlder(Iterable<String> commands) {
    final recent = List<String>.of(_commands);
    _commands.clear();
    for (final command in [...commands, ...recent]) {
      add(command);
    }
  }

  List<String> matching(String prefix) {
    if (prefix.trim().isEmpty) return const [];
    return _commands.reversed
        .where((command) => command.startsWith(prefix) && command != prefix)
        .take(100)
        .toList();
  }

  void observeInput(String data) {
    if (data.contains('\x03')) {
      _clearPending();
      return;
    }
    if (data != '\r' && data != '\n' && data != '\r\n') return;
    final input = readShellInput(terminal);
    if (input == null) return;
    if (_pending.any((anchor) => anchor.attached && anchor.y == input.row)) {
      return;
    }
    _pending.add(terminal.buffer.createAnchor(0, input.row));
    if (_pending.length > 8) _pending.removeAt(0).dispose();
  }

  void _echoChanged() {
    if (terminal.isUsingAltBuffer) {
      _clearPending();
      return;
    }
    final buffer = terminal.buffer;
    for (final anchor in List<CellAnchor>.of(_pending)) {
      if (!anchor.attached) {
        _pending.remove(anchor);
        anchor.dispose();
        continue;
      }
      var end = anchor.y;
      var line = buffer.lines[end].getText();
      while (end + 1 < buffer.lines.length && buffer.lines[end + 1].isWrapped) {
        line += buffer.lines[++end].getText();
      }
      // Wait for remote echo including the newline, so fast typing followed
      // by Enter does not record a truncated command.
      if (buffer.absoluteCursorY <= end) continue;
      final input = parseShellInput(line);
      if (input != null) add(input.command);
      _pending.remove(anchor);
      anchor.dispose();
    }
  }

  void _clearPending() {
    for (final anchor in _pending) {
      anchor.dispose();
    }
    _pending.clear();
  }

  void dispose() {
    terminal.removeListener(_echoChanged);
    _clearPending();
  }
}

bool isHistoryCommand(String command) =>
    command.trim().isNotEmpty &&
    !command.startsWith(' ') &&
    command.length <= 4096 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(command);

/// Supports Bash timestamps and Zsh extended history. Multiline entries are
/// omitted rather than offering a fragment as a standalone command.
List<String> parseCommandHistory(String text, {bool zsh = false}) {
  final result = <String>[];
  final lines = const LineSplitter().convert(text);
  final timestamped =
      !zsh && lines.any((line) => RegExp(r'^#\d{10,}$').hasMatch(line));
  final extendedZsh =
      zsh && lines.any((line) => RegExp(r'^: \d+:\d+;').hasMatch(line));
  final marker = zsh ? RegExp(r'^: \d+:\d+;') : RegExp(r'^#\d{10,}$');
  String? entry;
  var continuation = false;
  void flush() {
    if (entry != null && isHistoryCommand(entry!)) result.add(entry!);
    entry = null;
  }

  for (final line in lines) {
    if (timestamped || extendedZsh) {
      if (marker.hasMatch(line)) {
        flush();
        entry = zsh ? line.replaceFirst(marker, '') : '';
      } else if (entry != null) {
        entry = entry!.isEmpty ? line : '$entry\n$line';
      }
    } else {
      if (continuation || line.endsWith('\\')) {
        continuation = line.endsWith('\\');
        continue;
      }
      if (!line.startsWith('#') && isHistoryCommand(line)) result.add(line);
    }
  }
  flush();
  return result;
}
