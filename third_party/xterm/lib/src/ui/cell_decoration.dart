import 'dart:ui';

/// Overrides the appearance of a single terminal cell while painting.
class TerminalCellDecoration {
  const TerminalCellDecoration({this.foreground, this.underline = false});

  final Color? foreground;
  final bool underline;
}
