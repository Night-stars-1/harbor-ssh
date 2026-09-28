import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/host_identity_dialog.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  const fingerprint = 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
  const oldFingerprint = 'SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg';
  for (final brightness in Brightness.values) {
    for (final trust in [false, true]) {
      testWidgets('指纹冲突在窄屏大字体下可对照、复制并${trust ? '确认' : '取消'} ($brightness)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: harborTheme(brightness: brightness),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const HostIdentityDialog(
                        host: testHost,
                        keyType: 'ssh-ed25519',
                        fingerprint: fingerprint,
                        previousKey: 'ssh-rsa $oldFingerprint',
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(find.text('主机指纹冲突'), findsOneWidget);
        expect(find.text(testHost.destination), findsOneWidget);
        expect(find.text(oldFingerprint), findsOneWidget);
        expect(find.text(fingerprint), findsOneWidget);
        expect(find.text('ssh-rsa'), findsOneWidget);
        expect(find.text('ssh-ed25519'), findsOneWidget);
        expect(find.textContaining('中间人攻击'), findsOneWidget);
        expect(find.text('信任并连接'), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(find.byType(HostIdentityDialog), findsOneWidget);
        for (final entry in {
          '复制已保存指纹': oldFingerprint,
          '复制当前指纹': fingerprint,
        }.entries) {
          final copy = find.byTooltip(entry.key);
          await tester.ensureVisible(copy);
          await tester.tap(copy);
          await tester.pumpAndSettle();
          expect(copied, entry.value);
        }
        final action = find.text(trust ? '确认更新并连接' : '取消连接');
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(result, trust);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('指纹冲突弹窗默认回车取消连接', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const HostIdentityDialog(
                    host: testHost,
                    keyType: 'ssh-ed25519',
                    fingerprint: fingerprint,
                    previousKey: 'ssh-ed25519 $oldFingerprint',
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(find.byType(HostIdentityDialog), findsNothing);
  });

  for (final trust in [false, true]) {
    testWidgets('窄屏大字体可核对指纹并${trust ? '信任' : '取消'}', (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => const HostIdentityDialog(
                      host: testHost,
                      keyType: 'ssh-ed25519',
                      fingerprint: fingerprint,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.text(fingerprint), findsOneWidget);
      expect(find.text(testHost.destination), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('复制指纹'));
      await tester.tap(find.byTooltip('复制指纹'));
      await tester.pumpAndSettle();
      expect(copied, fingerprint);
      final action = find.text(trust ? '信任并连接' : '取消');
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(result, trust);
      expect(tester.takeException(), isNull);
    });
  }
}
