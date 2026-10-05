import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

final _highlight = Highlight()
  ..registerLanguage('bash', langBash)
  ..registerLanguage('javascript', langJavascript)
  ..registerLanguage('json', langJson)
  ..registerLanguage('python', langPython)
  ..registerLanguage('yaml', langYaml);

/// Only replaces Markdown's block-level `pre`; inline code, including code in
/// tables, continues to use the normal Markdown renderer.
class AiMarkdownCodeBuilder extends MarkdownElementBuilder {
  int _index = 0;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children
        ?.whereType<md.Element>()
        .where((child) => child.tag == 'code')
        .firstOrNull;
    final languageClass = code?.attributes['class']
        ?.split(' ')
        .where((value) => value.startsWith('language-'))
        .firstOrNull;
    final text = code?.textContent ?? element.textContent;
    // Markdown appends one structural newline to a fenced code block. Remove
    // that delimiter, preserving indentation and any actual trailing lines.
    return AiMarkdownCodeBlock(
      key: ValueKey('markdown-code-${_index++}'),
      code: text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
      language: languageClass?.substring('language-'.length) ?? '',
    );
  }
}

class AiMarkdownCodeBlock extends StatefulWidget {
  const AiMarkdownCodeBlock({
    super.key,
    required this.code,
    this.language = '',
  });

  final String code, language;

  @override
  State<AiMarkdownCodeBlock> createState() => _AiMarkdownCodeBlockState();
}

class _AiMarkdownCodeBlockState extends State<AiMarkdownCodeBlock> {
  bool _expanded = true, _copied = false;
  Timer? _copyTimer;
  late HighlightResult? _highlighted = _parse();

  String get _code =>
      widget.code.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  String get _language => switch (widget.language.toLowerCase()) {
    '' || 'sh' || 'shell' || 'zsh' => 'bash',
    'py' => 'python',
    'js' => 'javascript',
    'yml' => 'yaml',
    final value => value,
  };
  String get _label => switch (_language) {
    'bash' => 'Bash',
    'python' => 'Python',
    'javascript' => 'JavaScript',
    'json' => 'JSON',
    'yaml' => 'YAML',
    'text' || 'plaintext' => 'Text',
    _ => widget.language,
  };

  HighlightResult? _parse() =>
      const ['bash', 'python', 'javascript', 'json', 'yaml'].contains(_language)
      ? _highlight.highlight(code: _code, language: _language)
      : null;

  @override
  void didUpdateWidget(AiMarkdownCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language) {
      _highlighted = _parse();
      _copyTimer?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
      if (!mounted) return;
      _copyTimer?.cancel();
      setState(() => _copied = true);
      _copyTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('复制代码失败')));
      }
    }
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.6,
      letterSpacing: 0,
      color: colors.onSurface,
    );
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    final renderer = TextSpanRenderer(
      style,
      theme.brightness == Brightness.dark
          ? atomOneDarkTheme
          : atomOneLightTheme,
    );
    _highlighted?.render(renderer);
    final lineCount = '\n'.allMatches(_code).length + 1;
    return Material(
      color: theme.brightness == Brightness.dark
          ? const Color(0xff1e1e1e)
          : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.code_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_label, style: theme.textTheme.labelLarge),
                  ),
                  IconButton(
                    tooltip: _copied ? '已复制' : '复制代码',
                    onPressed: _copy,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_outlined,
                      size: 18,
                    ),
                  ),
                  IconButton(
                    tooltip: _expanded ? '折叠代码' : '展开代码',
                    onPressed: _toggle,
                    icon: Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Text(
                            List.generate(
                              lineCount,
                              (index) => '${index + 1}',
                            ).join('\n'),
                            textAlign: TextAlign.right,
                            strutStyle: strut,
                            style: style.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SelectableText.rich(
                          renderer.span ?? TextSpan(text: _code),
                          style: style,
                          strutStyle: strut,
                          textDirection: TextDirection.ltr,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
