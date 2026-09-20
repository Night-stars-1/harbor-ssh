import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_keys.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/host_editor.dart';

import 'support.dart';

void main() {
  testWidgets('新建凭证默认展示密钥操作，生成后保存私钥和公钥', (tester) async {
    SshUser? savedUser;
    Credentials? savedCredentials;
    await tester.pumpWidget(
      MaterialApp(
        home: UserEditor(
          onSave: (user, credentials) async {
            savedUser = user;
            savedCredentials = credentials;
          },
        ),
      ),
    );
    expect(find.text('导入私钥'), findsOneWidget);
    expect(find.text('生成密钥'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '密码'), findsNothing);
    expect(
      find.widgetWithText(TextFormField, '公钥（authorized_keys）'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '显示名称'),
      'Deployment key',
    );
    expect(find.widgetWithText(TextFormField, '用户名'), findsNothing);
    expect(find.byType(SegmentedButton<AuthMethod>), findsNothing);
    await tester.ensureVisible(find.text('生成密钥'));
    await tester.tap(find.text('生成密钥'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存凭证'));
    await tester.tap(find.text('保存凭证'));
    await tester.pumpAndSettle();
    expect(savedUser?.authMethod, AuthMethod.privateKey);
    expect(savedCredentials?.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(savedCredentials?.password, isEmpty);
    expect(savedUser?.publicKey, startsWith('ssh-ed25519 '));
    expect(
      publicKeyFromPrivatePem(savedCredentials!.privateKey),
      savedUser!.publicKey,
    );
  });

  testWidgets('导入的私钥及口令安全保存，公钥从私钥派生', (tester) async {
    final repository = memoryRepository();
    final pair = generateEd25519Key(passphrase: 'key-passphrase');
    await tester.pumpWidget(
      MaterialApp(
        home: UserEditor(
          user: const SshUser(
            id: 'key',
            name: 'Deploy key',
            username: '',
            authMethod: AuthMethod.privateKey,
          ),
          onSave: (user, stored) async {
            await repository.saveUserCredentials(user.id, stored);
            await repository.saveUsers([user]);
          },
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'PEM / OpenSSH 私钥'),
      pair.privatePem,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '私钥口令（若已加密）'),
      'key-passphrase',
    );
    await tester.ensureVisible(find.text('保存凭证'));
    await tester.tap(find.text('保存凭证'));
    await tester.pumpAndSettle();
    final stored = await repository.userCredentials('key');
    expect(stored?.privateKey, pair.privatePem.trim());
    expect(stored?.passphrase, 'key-passphrase');
    expect(stored?.password, isEmpty);
    expect((await repository.loadUsers()).single.publicKey, pair.publicOpenSsh);
  });

  testWidgets('用户名和密码在连接表单填写、测试并自动安全保存', (tester) async {
    final repository = memoryRepository();
    Host? saved;
    Credentials? tested;
    await tester.pumpWidget(
      MaterialApp(
        home: HostEditor(
          host: testHost,
          onSave: (host, credentials) async {
            saved = host;
            await repository.saveCredentials(host.id, credentials);
          },
          onTest: (host, credentials) async {
            expect(host.username, 'root');
            tested = credentials;
          },
        ),
      ),
    );
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'root');
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码'),
      'host-password',
    );
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(tested?.password, 'host-password');
    expect(saved, isNull);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(saved?.username, 'root');
    expect(saved?.authMethod, AuthMethod.password);
    expect(saved?.userId, isEmpty);
    expect(
      (await repository.credentials(testHost.id))?.password,
      'host-password',
    );
  });
}
