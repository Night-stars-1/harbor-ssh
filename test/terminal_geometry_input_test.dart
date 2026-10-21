import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _surface = Size(800, 600);

class _Geometry {
  const _Geometry({required this.editableSize, required this.caret});

  final Size editableSize;
  final Rect caret;
}

Widget _app(
  Terminal terminal,
  TerminalController controller,
  ScrollController vertical,
  FocusNode focus, {
  required double fontSize,
}) {
  return MaterialApp(
    home: Scaffold(
      // 顶部留出偏移：候选框必须使用全局坐标，而不是局部布局坐标。
      body: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TerminalView(
          terminal,
          controller: controller,
          scrollController: vertical,
          focusNode: focus,
          textStyle: TerminalStyle(fontFamily: 'monospace', fontSize: fontSize),
          // 与 TerminalPane 一致：输入法文本以两个空格作为编辑缓冲前缀。
          deleteDetection: true,
          // 关闭闪烁定时器，让帧推进只由终端状态驱动。
          alwaysShowCursor: true,
        ),
      ),
    ),
  );
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

TerminalViewState _view(WidgetTester tester) =>
    tester.state<TerminalViewState>(find.byType(TerminalView));

/// 推进到帧末：第一帧完成后布局与 post-frame 回调都已结算，第二帧让
/// 横向滚动指标这类帧末触发的同步落到最终位置。
Future<void> _pumpFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

_Geometry? _geometryFrom(Iterable<MethodCall> calls) {
  Size? editableSize;
  Rect? caret;
  for (final call in calls) {
    final args = call.arguments;
    if (args is! Map) continue;
    if (call.method == 'TextInput.setEditableSizeAndTransform') {
      editableSize = Size(
        (args['width'] as num).toDouble(),
        (args['height'] as num).toDouble(),
      );
    } else if (call.method == 'TextInput.setCaretRect') {
      caret = Rect.fromLTWH(
        (args['x'] as num).toDouble(),
        (args['y'] as num).toDouble(),
        (args['width'] as num).toDouble(),
        (args['height'] as num).toDouble(),
      );
    }
  }
  if (editableSize == null || caret == null) return null;
  return _Geometry(editableSize: editableSize, caret: caret);
}

/// 平台当前持有的候选框几何：最后一次成功发送的值。
_Geometry _lastGeometry(WidgetTester tester) {
  final geometry = _geometryFrom(tester.testTextInput.log);
  expect(geometry, isNotNull, reason: '输入连接应已收到可编辑区域和光标矩形');
  return geometry!;
}

/// 校验平台侧候选框几何与最终布局/滚动后的真实光标完全一致。
void _expectCandidateMatchesRender(WidgetTester tester, {String? reason}) {
  final render = _view(tester).renderTerminal;
  final cursor = render.localToGlobal(render.cursorOffset);
  final cell = render.cellSize;
  final sent = _lastGeometry(tester);
  final where = reason == null ? '' : '（$reason）';

  expect(cell.width, greaterThan(0), reason: '单元格宽度$where');
  expect(cell.height, greaterThan(0), reason: '单元格高度$where');
  expect(sent.caret.left, closeTo(cursor.dx, 0.01), reason: '候选框左边缘$where');
  expect(sent.caret.top, closeTo(cursor.dy, 0.01), reason: '候选框顶部$where');
  expect(sent.caret.width, closeTo(cell.width, 0.01), reason: '候选框宽度$where');
  expect(sent.caret.height, closeTo(cell.height, 0.01), reason: '候选框高度$where');
  expect(
    sent.editableSize.width,
    closeTo(render.size.width - cursor.dx, 0.01),
    reason: '输入区域宽度$where',
  );
  expect(
    sent.editableSize.height,
    closeTo(cell.height, 0.01),
    reason: '输入区域高度$where',
  );
}

void main() {
  testWidgets('终端输出、滚动、缩放与输入法重连后候选框始终落在最终光标上', (tester) async {
    _useSurface(tester, _surface);

    final terminal = Terminal()..lineWrap = false;
    final controller = TerminalController();
    final vertical = ScrollController();
    final focus = FocusNode();
    final output = <String>[];
    terminal.onOutput = output.add;
    addTearDown(() {
      controller.dispose();
      vertical.dispose();
      focus.dispose();
    });

    await tester.pumpWidget(
      _app(terminal, controller, vertical, focus, fontSize: 14),
    );
    await _pumpFrame(tester);

    focus.requestFocus();
    await _pumpFrame(tester);
    expect(focus.hasFocus, isTrue);
    expect(
      tester.testTextInput.log.where(
        (call) => call.method == 'TextInput.setClient',
      ),
      isNotEmpty,
    );

    // 完整输出滚动：一次写入大量行后，只应基于帧末的最终光标同步几何。
    terminal.write([for (var i = 0; i < 120; i++) 'line $i\r\n'].join());
    await _pumpFrame(tester);
    _expectCandidateMatchesRender(tester, reason: '连续输出后');

    final bottomGeometry = _lastGeometry(tester);
    final scrollPosition = vertical.position;
    expect(scrollPosition.maxScrollExtent, greaterThan(400));

    // 回看滚动：滚动位置减小，内容整体下移，底部光标也随之来到视口下方，
    // 候选框必须反映这个最终（可能已离开视口）的位置。
    vertical.jumpTo(scrollPosition.maxScrollExtent - 200);
    await _pumpFrame(tester);
    final scrolled = _lastGeometry(tester);
    expect(
      scrolled.caret.top,
      closeTo(bottomGeometry.caret.top + 200, 0.6),
      reason: '纵向回看 200 像素后候选框应随内容同步下移',
    );
    _expectCandidateMatchesRender(tester, reason: '纵向滚动后');

    // 回到跟随输出的位置，后续缩放和输入都基于可见光标。
    vertical.jumpTo(vertical.position.maxScrollExtent);
    await _pumpFrame(tester);
    _expectCandidateMatchesRender(tester, reason: '回到输出底部后');

    // 窗口尺寸变化会改变终端行列，候选框必须基于新的最终布局。
    tester.view.physicalSize = const Size(640, 480);
    await _pumpFrame(tester);
    _expectCandidateMatchesRender(tester, reason: '窗口尺寸变化后');

    // 换字号改变单元格度量，候选框尺寸应跟随新的 cell 高度。
    final cellBeforeFontChange = _view(tester).renderTerminal.cellSize;
    await tester.pumpWidget(
      _app(terminal, controller, vertical, focus, fontSize: 20),
    );
    await _pumpFrame(tester);
    final cellAfterFontChange = _view(tester).renderTerminal.cellSize;
    expect(
      cellAfterFontChange.height,
      isNot(closeTo(cellBeforeFontChange.height, 0.5)),
      reason: '字号变化应改变单元格高度',
    );
    _expectCandidateMatchesRender(tester, reason: '更换字号后');

    // 横向滚动：长行把光标推到右侧，候选框应带上水平偏移。
    terminal.write('x' * 300);
    await _pumpFrame(tester);
    final render = _view(tester).renderTerminal;
    expect(render.horizontalOffset, greaterThan(0));
    _expectCandidateMatchesRender(tester, reason: '横向跟随光标后');

    // 光标回到行首：水平偏移归零，候选框随最终偏移一起移动。
    final followed = _lastGeometry(tester);
    terminal.write('\x1b[1G');
    await _pumpFrame(tester);
    expect(render.horizontalOffset, 0);
    final restored = _lastGeometry(tester);
    expect(
      restored.caret.left,
      lessThan(followed.caret.left),
      reason: '水平偏移归零后候选框应回到未平移的光标位置',
    );
    _expectCandidateMatchesRender(tester, reason: '横向滚动回到行首后');

    // 中文输入法组合期间不向远端发送内容，候选框保持正确。
    output.clear();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  你好',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    );
    await _pumpFrame(tester);
    expect(output, isEmpty, reason: '组合中的拼音/汉字不应发送到远端');
    _expectCandidateMatchesRender(tester, reason: '输入法组合中');

    // 组合提交：内容进入远端，编辑缓冲被重置，候选框跟随新光标。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  你好',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await _pumpFrame(tester);
    expect(output.join(), '你好');
    expect(tester.testTextInput.editingState!['text'], '  ');
    _expectCandidateMatchesRender(tester, reason: '组合提交后');

    // 失焦断开输入连接，重新聚焦必须重建连接并重新发送同一几何。
    final beforeReconnect = _lastGeometry(tester);
    final reconnectStart = tester.testTextInput.log.length;
    focus.unfocus();
    await _pumpFrame(tester);
    expect(
      tester.testTextInput.log.any(
        (call) => call.method == 'TextInput.clearClient',
      ),
      isTrue,
      reason: '失焦应关闭输入连接',
    );

    focus.requestFocus();
    await _pumpFrame(tester);
    final reconnectCalls = tester.testTextInput.log
        .skip(reconnectStart)
        .toList();
    expect(
      reconnectCalls.where((call) => call.method == 'TextInput.setClient'),
      isNotEmpty,
      reason: '重新聚焦应建立新的输入连接',
    );
    final resent = _geometryFrom(reconnectCalls);
    expect(resent, isNotNull, reason: '新连接必须重新发送可编辑区域和光标矩形');
    expect(resent!.caret.left, closeTo(beforeReconnect.caret.left, 0.01));
    expect(resent.caret.top, closeTo(beforeReconnect.caret.top, 0.01));
    expect(resent.caret.width, closeTo(beforeReconnect.caret.width, 0.01));
    expect(resent.caret.height, closeTo(beforeReconnect.caret.height, 0.01));
    expect(
      resent.editableSize.width,
      closeTo(beforeReconnect.editableSize.width, 0.01),
    );
    expect(
      resent.editableSize.height,
      closeTo(beforeReconnect.editableSize.height, 0.01),
    );
    _expectCandidateMatchesRender(tester, reason: '输入连接重建后');

    // 重连后的输入仍然只把新增内容发送到远端。
    output.clear();
    tester.testTextInput.enterText('  ok');
    await _pumpFrame(tester);
    expect(output.join(), 'ok');
    _expectCandidateMatchesRender(tester, reason: '重连后继续输入');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
