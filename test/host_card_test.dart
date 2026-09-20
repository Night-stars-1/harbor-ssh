import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  for (final mouse in [true, false]) {
    testWidgets('${mouse ? '右键' : '长按'}打开菜单且不连接，菜单操作可用', (tester) async {
      var connections = 0;
      var favorites = 0;
      String? action;
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 112,
                child: ExpressiveHostCard(
                  host: testHost.withFavorite(false),
                  onConnect: () => connections++,
                  onFavorite: () => favorites++,
                  onAction: (value) => action = value,
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(ExpressiveHostCard);
      expect(
        find.descendant(of: card, matching: find.byType(IconButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );

      Future<void> openMenu() async {
        if (mouse) {
          await tester.tap(
            card,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
        } else {
          await tester.longPress(card);
        }
        await tester.pumpAndSettle();
        expect(connections, 0);
        expect(find.text('编辑连接'), findsOneWidget);
        expect(find.text('重置主机指纹'), findsOneWidget);
        expect(find.text('删除连接'), findsOneWidget);
      }

      await openMenu();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(favorites, 1);
      await openMenu();
      await tester.tap(find.text('编辑连接'));
      await tester.pumpAndSettle();
      expect(action, 'edit');
      await openMenu();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(connections, 0);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(connections, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
