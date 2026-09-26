import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/host_editor.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  const user = SshUser(
    id: 'key-user',
    name: 'Deployment',
    username: 'deploy',
    authMethod: AuthMethod.privateKey,
  );
  const credentials = Credentials(
    privateKey: 'saved-key',
    passphrase: 'phrase',
  );

  testWidgets('测试使用所选凭证且不保存，保存按钮单独保存', (tester) async {
    Host? saved, tested;
    Credentials? connected;
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          host: Host(
            id: testHost.id,
            name: testHost.name,
            address: testHost.address,
            username: testHost.username,
            authMethod: AuthMethod.privateKey,
          ),
          users: const [user],
          userCredentials: const {'key-user': credentials},
          onSave: (host, _) async {
            saved = host;
          },
          onTest: (host, creds) async {
            tested = host;
            connected = creds;
          },
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '用户名'),
      'custom-user',
    );
    expect(find.byType(CredentialFields), findsNothing);
    final save = find.text('测试连接');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('请选择已有凭证'), findsOneWidget);
    final selector = find.byType(DropdownMenuFormField<String>);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.text('手动填写'), findsNothing);
    await tester.tap(find.text('Deployment').last);
    await tester.pumpAndSettle();
    expect(find.text('使用已保存的私钥'), findsNothing);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(tested?.userId, user.id);
    expect(tested?.username, 'custom-user');
    expect(tested?.authMethod, AuthMethod.privateKey);
    expect(connected, same(credentials));
    expect(find.text('连接成功，SSH 身份验证已通过。'), findsOneWidget);
    // 成功反馈是瞬时提示，不占表单布局，随后自动消失。
    expect(
      find.descendant(
        of: find.byType(HostEditor),
        matching: find.text('连接成功，SSH 身份验证已通过。'),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('连接成功，SSH 身份验证已通过。'), findsNothing);
    expect(find.byType(HostEditor), findsOneWidget);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.userId, user.id);
  });

  testWidgets('测试成功的提示显示在对话框之上，关闭后不残留叠加层', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Host? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => HostEditor(
                  host: Host(
                    id: 'host',
                    name: 'Server',
                    address: 'localhost',
                    username: user.username,
                    userId: user.id,
                    authMethod: user.authMethod,
                  ),
                  users: const [user],
                  userCredentials: const {'key-user': credentials},
                  onSave: (host, _) async {
                    saved = host;
                  },
                  onTest: (_, _) async {},
                ),
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final notice = find.text('连接成功，SSH 身份验证已通过。');
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(notice, findsOneWidget);
    // 提示挂在导航叠加层而不是底层 Scaffold，因此位于对话框之上。
    expect(
      find.ancestor(of: notice, matching: find.byType(Scaffold)),
      findsNothing,
    );
    expect(
      find.descendant(of: find.byType(Dialog), matching: notice),
      findsNothing,
    );
    // 提示显示期间不拦截点击，对话框仍可保存；关闭后不残留提示或计时器。
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.userId, user.id);
    expect(notice, findsNothing);
    expect(find.byType(HostEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少已存密码或私钥时阻止连接且不显示手动输入', (tester) async {
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          host: Host(
            id: 'host',
            name: 'Server',
            address: 'localhost',
            username: 'deploy',
            userId: user.id,
            authMethod: user.authMethod,
          ),
          users: const [user],
          onSave: (_, _) async {
            saved = true;
          },
          onTest: (_, _) async => fail('未保存凭据时不能测试连接'),
        ),
      ),
    );
    final save = find.text('测试连接');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(find.text('请先在凭证页补全所选凭证的私钥。'), findsOneWidget);
    expect(find.byType(CredentialFields), findsNothing);
  });

  testWidgets('测试期间禁止重复操作，失败后可修改并保存', (tester) async {
    final pending = Completer<void>();
    Host? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          host: Host(
            id: 'host',
            name: 'Server',
            address: 'localhost',
            username: user.username,
            userId: user.id,
            authMethod: user.authMethod,
          ),
          users: const [user],
          userCredentials: const {'key-user': credentials},
          onSave: (host, _) async {
            saved = host;
          },
          onTest: (_, _) => pending.future,
        ),
      ),
    );
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pump();
    expect(find.text('正在测试…'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存连接'))
          .onPressed,
      isNull,
    );
    expect(saved, isNull);
    pending.completeError(Exception('authentication failed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试连接失败'), findsOneWidget);
    expect(find.byType(HostEditor), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '连接名称'),
      'Renamed',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('测试连接失败'), findsNothing);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.name, 'Renamed');
  });

  testWidgets('没有凭证时提示前往凭证页，不提供新建入口', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建连接'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '连接名称'),
      'Server',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '主机地址'),
      'localhost',
    );
    expect(find.text('请先在凭证页添加凭证'), findsNothing);
    expect(find.byType(SegmentedButton<AuthMethod>), findsNothing);
    expect(find.text('新建凭证'), findsNothing);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(model.hosts.single.authMethod, AuthMethod.password);
    expect(model.hosts.single.userId, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('凭证预选新建连接：测试与保存都引用该用户的凭证', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Host? saved;
    Host? tested;
    Credentials? connected;
    Credentials? stored = credentials;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => HostEditor(
                  initialCredential: user,
                  users: const [user],
                  userCredentials: const {'key-user': credentials},
                  onSave: (host, secret) async {
                    saved = host;
                    stored = secret;
                  },
                  onTest: (host, creds) async {
                    tested = host;
                    connected = creds;
                  },
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('新建连接'), findsOneWidget);
    // 打开即预选该密钥凭证：下拉已选中它，且不显示密码输入。
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byType(DropdownMenuFormField<String>),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      user.name,
    );
    expect(find.widgetWithText(TextFormField, '密码'), findsNothing);
    // 用户名优先继承凭证的非空用户名。
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '用户名'))
          .controller
          ?.text,
      user.username,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '连接名称'),
      'Key server',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '主机地址'),
      'localhost',
    );
    // 不碰下拉即可测试：使用该用户安全存储里的凭证，而不是表单里的口令。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(tested?.userId, user.id);
    expect(tested?.authMethod, AuthMethod.privateKey);
    expect(connected, same(credentials));
    await tester.pump(const Duration(seconds: 4));
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.userId, user.id);
    expect(saved?.authMethod, AuthMethod.privateKey);
    expect(saved?.username, user.username);
    // 私钥留在用户安全存储，Host 不自带任何口令或私钥。
    expect(stored, isNull);
    expect(find.byType(HostEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预选凭证不在用户列表时不生效，回退密码认证', (tester) async {
    const stale = SshUser(
      id: 'missing',
      name: 'Gone',
      username: 'ghost',
      authMethod: AuthMethod.privateKey,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          initialCredential: stale,
          users: const [user],
          userCredentials: const {'key-user': credentials},
          onSave: (_, _) async {},
          onTest: (_, _) async => fail('没有可用凭证时不能测试连接'),
        ),
      ),
    );
    expect(find.widgetWithText(TextFormField, '密码'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '用户名'))
          .controller
          ?.text,
      'root',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '连接名称'),
      'Fallback',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '主机地址'),
      'localhost',
    );
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请输入密码后测试连接。'), findsOneWidget);
  });

  testWidgets('编辑已有主机时初始凭证不覆盖其认证方式', (tester) async {
    Host? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          host: Host(
            id: 'host',
            name: 'Server',
            address: 'localhost',
            username: 'admin',
            authMethod: AuthMethod.password,
          ),
          initialCredential: user,
          users: const [user],
          userCredentials: const {'key-user': credentials},
          onSave: (host, _) async {
            saved = host;
          },
          onTest: (_, _) async {},
        ),
      ),
    );
    // 已有主机的密码认证、用户名与空 userId 都保持不变。
    expect(find.widgetWithText(TextFormField, '密码'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '用户名'))
          .controller
          ?.text,
      'admin',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码'),
      'host-secret',
    );
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.authMethod, AuthMethod.password);
    expect(saved?.username, 'admin');
    expect(saved?.userId, isEmpty);
  });

  testWidgets('预选凭证用户名为空时保持默认 root', (tester) async {
    const anonymous = SshUser(
      id: 'key-plain',
      name: 'Plain',
      username: '',
      authMethod: AuthMethod.privateKey,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          initialCredential: anonymous,
          users: const [anonymous],
          onSave: (_, _) async {},
          onTest: (_, _) async {},
        ),
      ),
    );
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '用户名'))
          .controller
          ?.text,
      'root',
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byType(DropdownMenuFormField<String>),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      anonymous.name,
    );
  });
}
