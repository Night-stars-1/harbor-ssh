// 远程文本编辑器的语法高亮选择：只按文件名与所在目录挑语法，不做内容自动识别。
//
// re_editor 的 CodeHighlightTheme 在 languages 恰好只有一项时直接按该项高亮，
// 多于一项则退回 highlight.js 的自动识别，而自动识别会把普通配置文件误判成别的
// 语言，所以这里始终只注册一种语法，未知文件返回 null（纯文本）。
//
// 传完整远端路径比只传文件名更准：`/etc/nginx/sites-enabled/site.conf` 这类没有
// nginx 字样的配置只能靠目录判定。复用 re_highlight 已生成的语法规则，只导入
// 用得到的语言，不加载 all.dart。

import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart' show TextStyle;
import 'package:re_editor/re_editor.dart'
    show CodeHighlightTheme, CodeHighlightThemeMode;
import 'package:re_highlight/languages/apache.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// 一种可高亮的语言：注册键、语法规则与界面展示名。
class _RemoteCodeLanguage {
  _RemoteCodeLanguage(this.id, this.mode, this.label);

  /// 注册进 [CodeHighlightTheme.languages] 的键，同时决定实际使用的语法。
  final String id;

  /// re_highlight 提供的语法规则。
  final Mode mode;

  /// 界面上展示的语言名称。
  final String label;

  CodeHighlightTheme? _light;
  CodeHighlightTheme? _dark;

  /// [CodeHighlightTheme] 按值比较相等，缓存让每次 build 拿到同一个对象，
  /// 内部高亮引擎不会因主题「变化」而反复重新注册语法规则。
  CodeHighlightTheme theme(Brightness brightness) =>
      brightness == Brightness.dark
      ? (_dark ??= _create(atomOneDarkTheme))
      : (_light ??= _create(atomOneLightTheme));

  CodeHighlightTheme _create(Map<String, TextStyle> styles) =>
      CodeHighlightTheme(
        languages: {id: CodeHighlightThemeMode(mode: mode)},
        theme: styles,
      );
}

final _json = _RemoteCodeLanguage('json', langJson, 'JSON');
final _yaml = _RemoteCodeLanguage('yaml', langYaml, 'YAML');
final _shell = _RemoteCodeLanguage('bash', langBash, 'Shell');
final _python = _RemoteCodeLanguage('python', langPython, 'Python');
final _javascript = _RemoteCodeLanguage(
  'javascript',
  langJavascript,
  'JavaScript',
);
final _typescript = _RemoteCodeLanguage(
  'typescript',
  langTypescript,
  'TypeScript',
);
final _dart = _RemoteCodeLanguage('dart', langDart, 'Dart');
final _markdown = _RemoteCodeLanguage('markdown', langMarkdown, 'Markdown');
final _sql = _RemoteCodeLanguage('sql', langSql, 'SQL');
// re_highlight 的 XML 语法同时覆盖 HTML（规则名 "HTML, XML"），两者只是标签不同。
final _html = _RemoteCodeLanguage('xml', langXml, 'HTML');
final _xml = _RemoteCodeLanguage('xml', langXml, 'XML');
final _css = _RemoteCodeLanguage('css', langCss, 'CSS');
final _ini = _RemoteCodeLanguage('ini', langIni, 'INI');
final _toml = _RemoteCodeLanguage('ini', langIni, 'TOML');
final _properties = _RemoteCodeLanguage(
  'properties',
  langProperties,
  'Properties',
);
final _nginx = _RemoteCodeLanguage('nginx', langNginx, 'Nginx');
final _dockerfile = _RemoteCodeLanguage(
  'dockerfile',
  langDockerfile,
  'Dockerfile',
);
final _makefile = _RemoteCodeLanguage('makefile', langMakefile, 'Makefile');
final _apache = _RemoteCodeLanguage('apache', langApache, 'Apache');

/// 文件名整体决定语言的文件，键为小写文件名。
final Map<String, _RemoteCodeLanguage> _byFileName = {
  'nginx.conf': _nginx,
  'dockerfile': _dockerfile,
  'makefile': _makefile,
  'gnumakefile': _makefile,
};

/// 扩展名决定语言的文件，键为小写扩展名；点文件（`.bashrc`）取点后的整段。
final Map<String, _RemoteCodeLanguage> _byExtension = {
  // 配置与数据
  'json': _json,
  'jsonc': _json,
  'json5': _json,
  'geojson': _json,
  'webmanifest': _json,
  'yaml': _yaml,
  'yml': _yaml,
  'ini': _ini,
  'cfg': _ini,
  'cnf': _ini,
  'conf': _ini,
  'service': _ini,
  'desktop': _ini,
  'env': _ini,
  'editorconfig': _ini,
  'gitconfig': _ini,
  'toml': _toml,
  'properties': _properties,
  'htaccess': _apache,
  // 脚本与代码
  'sh': _shell,
  'bash': _shell,
  'zsh': _shell,
  'ksh': _shell,
  'bashrc': _shell,
  'bash_profile': _shell,
  'bash_aliases': _shell,
  'bash_login': _shell,
  'bash_logout': _shell,
  'profile': _shell,
  'zshrc': _shell,
  'zprofile': _shell,
  'zshenv': _shell,
  'zlogin': _shell,
  'zlogout': _shell,
  'py': _python,
  'pyw': _python,
  'pyi': _python,
  'js': _javascript,
  'mjs': _javascript,
  'cjs': _javascript,
  'jsx': _javascript,
  'ts': _typescript,
  'mts': _typescript,
  'cts': _typescript,
  'tsx': _typescript,
  'dart': _dart,
  'sql': _sql,
  'mk': _makefile,
  // 文本与网页
  'md': _markdown,
  'markdown': _markdown,
  'html': _html,
  'htm': _html,
  'xhtml': _html,
  'xml': _xml,
  'xsd': _xml,
  'xsl': _xml,
  'xslt': _xml,
  'svg': _xml,
  'plist': _xml,
  'css': _css,
};

/// 按文件名（或完整远端路径）与亮度返回语法高亮主题；未知文件返回 null。
///
/// 返回 null 表示调用方不应启用高亮：远程文件保持纯文本，不会出现猜测式染色。
/// 传 [filename] 时用完整路径可以多认出一类文件（`/etc/nginx/**/*.conf`）。
CodeHighlightTheme? remoteCodeHighlightTheme(
  String filename,
  Brightness brightness,
) => _languageOf(filename)?.theme(brightness);

/// 按文件名返回展示用的语言名称；未知文件返回「纯文本」。
String remoteCodeLanguageLabel(String filename) =>
    _languageOf(filename)?.label ?? '纯文本';

_RemoteCodeLanguage? _languageOf(String filename) {
  final String base = _basename(filename).toLowerCase();
  if (base.isEmpty || base == '.' || base == '..') {
    return null;
  }
  return _byFileName[base] ??
      _byNameRule(base) ??
      _byNginxDirectory(filename, base) ??
      _byExtension[_extensionOf(base)];
}

/// `/etc/nginx/**/*.conf`（如 `sites-enabled/site.conf`）按所在目录判定为
/// Nginx 配置；目录名之外的 `.conf` 仍按通用 INI 处理，不看内容。
_RemoteCodeLanguage? _byNginxDirectory(String filename, String base) {
  if (_extensionOf(base) != 'conf') {
    return null;
  }
  final List<String> segments = _directoryOf(filename)
      .toLowerCase()
      .split(_separator);
  return segments.contains('nginx') ? _nginx : null;
}

/// 带前缀的常见文件名：`Dockerfile.dev`、`Makefile.am`、`site.nginx.conf`。
_RemoteCodeLanguage? _byNameRule(String base) {
  if (base.startsWith('dockerfile.') || base.endsWith('.dockerfile')) {
    return _dockerfile;
  }
  if (base.startsWith('makefile.')) {
    return _makefile;
  }
  if (base.endsWith('.nginx.conf')) {
    return _nginx;
  }
  if (base.startsWith('.env.')) {
    return _ini;
  }
  return null;
}

/// 文件名分隔符：远端路径用 `/`，同时容忍 Windows 风格的 `\`。
final RegExp _separator = RegExp(r'[/\\]');

int _lastSeparator(String filename) {
  final int slash = filename.lastIndexOf('/');
  final int backslash = filename.lastIndexOf(r'\');
  return slash > backslash ? slash : backslash;
}

String _basename(String filename) {
  final int start = _lastSeparator(filename);
  return start < 0 ? filename : filename.substring(start + 1);
}

String _directoryOf(String filename) {
  final int start = _lastSeparator(filename);
  return start < 0 ? '' : filename.substring(0, start);
}

String _extensionOf(String base) {
  final int dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) {
    return '';
  }
  return base.substring(dot + 1);
}
