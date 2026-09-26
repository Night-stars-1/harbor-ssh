import 'dart:ui' show Brightness, Color;

import 'package:flutter/painting.dart' show InlineSpan, TextSpan;
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/remote_code_highlight.dart';
import 'package:re_highlight/re_highlight.dart'
    show Highlight, TextSpanRenderer;
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// 按 [remoteCodeHighlightTheme] 返回的主题真实跑一遍语法高亮，收集实际用到的颜色。
///
/// 这里复刻 re_editor 内部的注册方式（单一语言 + 同一份主题），因此断言的是
/// 「打开远程文件时编辑器会怎样着色」，而不是内部实现细节。
Set<Color> _highlightedColors(String filename, String code) {
  final theme = remoteCodeHighlightTheme(filename, Brightness.light)!;
  final highlight = Highlight()
    ..registerLanguages(
      theme.languages.map((key, value) => MapEntry(key, value.mode)),
    );
  final result = highlight.highlight(
    code: code,
    language: theme.languages.keys.single,
  );
  final renderer = TextSpanRenderer(null, theme.theme);
  result.render(renderer);

  final colors = <Color>{};
  void visit(InlineSpan span) {
    final color = span.style?.color;
    if (color != null) {
      colors.add(color);
    }
    if (span is TextSpan) {
      span.children?.forEach(visit);
    }
  }

  final span = renderer.span;
  if (span != null) {
    visit(span);
  }
  return colors;
}

void main() {
  test('每类文件各取一个代表，按文件名选定语法并给出标签', () {
    // 一行一种语法 / 一类文件；同一语法的其它别名不再逐条铺开。
    final representatives = <String, (String, String)>{
      'config.json': ('json', 'JSON'),
      'settings.yaml': ('yaml', 'YAML'),
      'deploy.sh': ('bash', 'Shell'),
      '.bashrc': ('bash', 'Shell'),
      'main.py': ('python', 'Python'),
      'server.properties': ('properties', 'Properties'),
      'app.ini': ('ini', 'INI'),
      'index.html': ('xml', 'HTML'),
      'nginx.conf': ('nginx', 'Nginx'),
      'Dockerfile': ('dockerfile', 'Dockerfile'),
      'Makefile': ('makefile', 'Makefile'),
      '.htaccess': ('apache', 'Apache'),
    };

    representatives.forEach((filename, target) {
      final (key, label) = target;
      final theme = remoteCodeHighlightTheme(filename, Brightness.light);
      expect(theme, isNotNull, reason: '$filename 应当启用语法高亮');
      // 只注册一种语言：re_editor 才会直接用该语法，而不是自动识别。
      expect(theme!.languages.keys.toList(), [key], reason: filename);
      expect(remoteCodeLanguageLabel(filename), label, reason: filename);
    });
  });

  test('大小写、路径与别名归一化到同一语法', () {
    final aliases = <String, (String, String)>{
      'CONFIG.JSON': ('json', 'JSON'),
      '/etc/nginx/conf.d/site.nginx.conf': ('nginx', 'Nginx'),
      // 没有 nginx 字样的站点配置靠所在目录判定。
      '/etc/nginx/sites-enabled/site.conf': ('nginx', 'Nginx'),
      'Dockerfile.dev': ('dockerfile', 'Dockerfile'),
      'GNUmakefile': ('makefile', 'Makefile'),
      '.env.production': ('ini', 'INI'),
      // 目录里没有 nginx 的 `.conf` 仍按通用 INI 处理。
      '/etc/php-fpm.d/pool.conf': ('ini', 'INI'),
      'pyproject.toml': ('ini', 'TOML'),
      'app.ts': ('typescript', 'TypeScript'),
    };

    aliases.forEach((filename, target) {
      final (key, label) = target;
      final theme = remoteCodeHighlightTheme(filename, Brightness.dark);
      expect(theme, isNotNull, reason: filename);
      expect(theme!.languages.keys.toList(), [key], reason: filename);
      expect(remoteCodeLanguageLabel(filename), label, reason: filename);
    });
  });

  test('未知文件保持纯文本', () {
    for (final filename in [
      'notes.txt',
      '/etc/hosts',
      'access.log',
      '.envrc',
      'config.',
    ]) {
      expect(remoteCodeHighlightTheme(filename, Brightness.light), isNull);
      expect(remoteCodeHighlightTheme(filename, Brightness.dark), isNull);
      expect(remoteCodeLanguageLabel(filename), '纯文本');
    }
  });

  test('高亮主题随亮度切换', () {
    final light = remoteCodeHighlightTheme('app.yaml', Brightness.light)!;
    final dark = remoteCodeHighlightTheme('app.yaml', Brightness.dark)!;
    expect(light.theme, atomOneLightTheme);
    expect(dark.theme, atomOneDarkTheme);
    expect(light, isNot(dark));
    expect(dark.languages.keys.toList(), light.languages.keys.toList());
  });

  test('代表性的配置与脚本能被真正着色', () {
    // 每一项：文件名、示例内容、必须出现的语法作用域（颜色由所选主题决定）。
    // 作用域命中即证明注册进去的是该语言的语法，而不是别的语言。
    final cases = <(String, String, Set<String>)>[
      (
        'config.json',
        '{"port": 8080, "path": "/srv/app", "debug": true}',
        {'attr', 'string'},
      ),
      ('settings.yaml', 'server:\n  listen: 8080\n', {'attr'}),
      ('app.ini', '[server]\nport = 8080\n', {'section', 'attr'}),
      ('server.properties', 'server.port=8080\n', {'attr'}),
      ('Makefile', 'all: build\n\t@echo ok\n', {'section'}),
      (
        'deploy.sh',
        '#!/bin/bash\nif [ -f /etc/app/app.conf ]; then\n  echo "ready"\nfi\n',
        {'keyword'},
      ),
      ('nginx.conf', 'server {\n  listen 8080;\n}\n', {'section'}),
      ('Dockerfile', 'FROM debian:12\nRUN apt-get update\n', {'keyword'}),
    ];

    for (final (filename, code, scopes) in cases) {
      final theme = remoteCodeHighlightTheme(filename, Brightness.light)!;
      final colors = _highlightedColors(filename, code);
      expect(colors, isNotEmpty, reason: '$filename 未产生任何高亮着色');

      final themeColors = theme.theme.values
          .map((style) => style.color)
          .toSet();
      expect(
        colors.difference(themeColors),
        isEmpty,
        reason: '$filename 使用了主题之外的颜色',
      );

      for (final scope in scopes) {
        expect(
          colors,
          contains(theme.theme[scope]!.color),
          reason: '$filename 缺少 $scope 着色',
        );
      }
    }
  });
}
