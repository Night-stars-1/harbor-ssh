import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

MarkdownStyleSheet aiMarkdownStyle(ThemeData theme) {
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    code: theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      // TextSpan backgrounds paint over the paragraph's selection highlight.
      // Keep inline code selectable with the same highlight as surrounding text.
      backgroundColor: Colors.transparent,
    ),
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
  );
}
