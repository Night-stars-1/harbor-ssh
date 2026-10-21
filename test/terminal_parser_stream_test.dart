import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 模拟 SSH 输出：按任意字节分片解码 UTF8，并把每次解码结果写入终端。
void _feedUtf8(Terminal terminal, List<int> bytes, List<int> chunkSizes) {
  final converter = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_TerminalSink(terminal.write));
  var offset = 0;
  var index = 0;
  while (offset < bytes.length) {
    final size = chunkSizes[index++ % chunkSizes.length];
    final end = offset + size < bytes.length ? offset + size : bytes.length;
    converter.add(bytes.sublist(offset, end));
    offset = end;
  }
  converter.close();
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this._write);

  final void Function(String) _write;

  @override
  void add(String data) => _write(data);

  @override
  void close() {}
}

/// 终端可见状态快照，用于验证多分片写入与整段写入完全一致。
class _TerminalSnapshot {
  _TerminalSnapshot(Terminal terminal, List<String> titles)
    : text = terminal.buffer.getText(),
      cursorX = terminal.buffer.cursorX,
      cursorY = terminal.buffer.cursorY,
      titles = List.of(titles),
      lines = [
        for (var i = 0; i < terminal.buffer.height; i++)
          terminal.buffer.lines[i].data.toList(growable: false),
      ];

  final String text;
  final int cursorX;
  final int cursorY;
  final List<String> titles;
  final List<List<int>> lines;

  void expectSameAs(_TerminalSnapshot other) {
    expect(text, other.text, reason: 'buffer text');
    expect(cursorX, other.cursorX, reason: 'cursorX');
    expect(cursorY, other.cursorY, reason: 'cursorY');
    expect(titles, other.titles, reason: 'title history');
    expect(lines, other.lines, reason: 'cell data');
  }
}

void main() {
  test('分片到达的 CSI、OSC、保存恢复光标和颜色序列得到完整终端状态', () {
    final titles = <String>[];
    final terminal = Terminal(onTitleChange: titles.add)..resize(30, 12);
    const chunks = [
      '\x1b]2;harbor 构建日志',
      '\x07\x1b[1;31mER',
      'ROR\x1b[0m 中文\r\n',
      '\x1b[38;2;12;34;56mRGB\x1b[0m ',
      '\x1b[48;5;208mBG\x1b[0m\r\n',
      '\x1b[3;5H\x1b7',
      '\x1b[6;1H临时草稿',
      '\x1b8\x1b]0;完成 😀\x1b\\',
      'OK',
    ];
    for (final chunk in chunks) {
      terminal.write(chunk);
    }

    expect(titles, ['harbor 构建日志', '完成 😀']);
    expect(
      terminal.buffer.getText(),
      [
        'ERROR 中文',
        'RGB BG',
        'OK',
        '',
        '',
        '临时草稿',
        '',
        '',
        '',
        '',
        '',
        '',
      ].join('\n'),
    );
    expect(terminal.buffer.cursorX, 6);
    expect(terminal.buffer.cursorY, 2);

    final first = terminal.buffer.lines[0];
    expect(first.getText(), 'ERROR 中文');
    expect(first.getCodePoint(6), 0x4E2D);
    expect(first.getWidth(6), 2);
    expect(first.getCodePoint(8), 0x6587);
    expect(first.getWidth(8), 2);
    expect(first.getForeground(0), NamedColor.red | CellColor.named);
    expect(first.getAttributes(0) & CellAttr.bold, CellAttr.bold);
    expect(first.getForeground(5), 0);
    expect(first.getAttributes(5), 0);

    final second = terminal.buffer.lines[1];
    expect(second.getText(), 'RGB BG');
    expect(
      second.getForeground(0),
      (12 << 16) | (34 << 8) | 56 | CellColor.rgb,
    );
    expect(second.getForeground(3), 0);
    expect(second.getBackground(4), 208 | CellColor.palette);
    expect(second.getBackground(6), 0);

    final draft = terminal.buffer.lines[5];
    expect(draft.getText(), '临时草稿');
    expect(draft.getWidth(0), 2);
    expect(draft.getCodePoint(0), 0x4E34);
    expect(draft.getCodePoint(6), 0x7A3F);
  });

  test('UTF8 多字节字符跨字节分片时终端结果与整段写入一致', () {
    const stream =
        '\x1b]2;部署日志 — 中文 😀\x07'
        '\x1b[1;32m\$ make deploy\x1b[0m\r\n'
        'step 1/3: 拉取源码…\r\n'
        'step 2/3: 编译 中文宽字符与 𝄞 以及 😀\r\n'
        '\x1b[2K\x1b[1Gstep 3/3: 上传 100%\r\n'
        '\x1b[38;5;45m✓\x1b[0m 部署完成\r\n';
    final bytes = utf8.encode(stream);

    final expectedTitles = <String>[];
    final expectedTerminal = Terminal(onTitleChange: expectedTitles.add)
      ..resize(40, 12);
    expectedTerminal.write(stream);
    final expected = _TerminalSnapshot(expectedTerminal, expectedTitles);

    for (final sizes in [
      [1],
      [2, 3],
      [5, 1, 7, 4],
      [bytes.length],
    ]) {
      final titles = <String>[];
      final terminal = Terminal(onTitleChange: titles.add)..resize(40, 12);
      terminal.write('');
      _feedUtf8(terminal, bytes, sizes);
      _TerminalSnapshot(terminal, titles).expectSameAs(expected);
    }
  });

  test('转义序列在任意输入分片边界被切断时仍得到同一终端状态', () {
    const stream =
        '\x1b]2;标题\x1b\\'
        '\x1b[1;35m加载\x1b[0m 中文 😀\r\n'
        '\x1b[38;2;200;10;20mred\x1b[0m\r\n'
        '\x1b[4;7H\x1b7\x1b[6;1Hscratch\x1b8OK';
    final expectedTitles = <String>[];
    final expectedTerminal = Terminal(onTitleChange: expectedTitles.add)
      ..resize(20, 10);
    expectedTerminal.write(stream);
    final expected = _TerminalSnapshot(expectedTerminal, expectedTitles);

    final boundaries = <int>[];
    var units = 0;
    for (final rune in stream.runes) {
      units += rune > 0xFFFF ? 2 : 1;
      boundaries.add(units);
    }

    for (final boundary in boundaries) {
      final titles = <String>[];
      final terminal = Terminal(onTitleChange: titles.add)..resize(20, 10);
      terminal.write(stream.substring(0, boundary));
      terminal.write(stream.substring(boundary));
      _TerminalSnapshot(terminal, titles).expectSameAs(expected);
    }
  });

  test('长日志按小块输出时滚动、覆盖和中文宽字符与整段写入一致', () {
    final builder = StringBuffer();
    for (var i = 0; i < 120; i++) {
      builder.write('\x1b[3${i % 7 + 1}m[$i]\x1b[0m ');
      builder.write(i.isEven ? '中文行 ${'数据' * 3}' : 'ascii line $i');
      if (i % 7 == 0) {
        builder.write('\r\x1b[2Kprogress ${i * 7}%');
      }
      builder.write('\r\n');
    }
    final stream = builder.toString();
    final bytes = utf8.encode(stream);

    final expectedTitles = <String>[];
    final expectedTerminal = Terminal(onTitleChange: expectedTitles.add)
      ..resize(36, 8);
    expectedTerminal.write(stream);
    final expected = _TerminalSnapshot(expectedTerminal, expectedTitles);

    final titles = <String>[];
    final terminal = Terminal(onTitleChange: titles.add)..resize(36, 8);
    _feedUtf8(terminal, bytes, const [1, 2, 3, 5, 8, 13, 21]);
    _TerminalSnapshot(terminal, titles).expectSameAs(expected);

    String? lastLine;
    for (var i = terminal.buffer.height - 1; i >= 0; i--) {
      final text = terminal.buffer.lines[i].getText();
      if (text.isNotEmpty) {
        lastLine = text;
        break;
      }
    }
    expect(lastLine, 'progress 833%');
    expect(terminal.buffer.cursorX, 0);
    expect(terminal.buffer.cursorY, 7);
  });
}
