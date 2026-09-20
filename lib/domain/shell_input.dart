import 'package:xterm/xterm.dart';

class ShellInput {
  const ShellInput(this.line, this.directory, this.command, this.row);
  final String line;
  final String directory;
  final String command;
  final int row;
}

ShellInput? parseShellInput(String line, {int row = 0}) {
  final prompt = RegExp(r'^[^\s@]+@[^\s:]+:(~(?:/.*?)?|/.*?)[$#%] (.*)$')
      .firstMatch(line);
  if (prompt == null) return null;
  return ShellInput(line, prompt[1]!, prompt[2]!, row);
}

/// Only complete a recognized shell prompt, at the end of its input line.
ShellInput? readShellInput(Terminal terminal) {
  if (terminal.isUsingAltBuffer || !terminal.cursorVisibleMode) return null;
  final buffer = terminal.buffer;
  var row = buffer.absoluteCursorY;
  final current = buffer.lines[row];
  if (current.getText(buffer.insertionX).trim().isNotEmpty) return null;
  var line = current.getText(0, buffer.insertionX);
  while (row > 0 && buffer.lines[row].isWrapped) {
    line = buffer.lines[--row].getText() + line;
  }
  return parseShellInput(line, row: row);
}
