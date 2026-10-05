import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_keys.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/host_editor.dart';

import 'support.dart';

void main() {
  testWidgets('选择中转主机、保存重开、取消中转并拦截循环配置', (tester) async {
    final repository = memoryRepository();
    const gateway = Host(
      id: 'gateway',
      name: '公网堡垒机',
      address: 'gateway.example.com',
      username: 'deploy',
    );
    const dependent = Host(
      id: 'dependent',
      name: '依赖目标的主机',
      address: '10.0.0.3',
      username: 'root',
      jumpHostId: 'target',
    );
    const target = Host(
      id: 'target',
      name: '内网服务器',
      address: '10.0.0.8',
      username: 'root',
    );
    await repository.saveHosts([gateway, dependent, target]);
    Host? tested;
    Future<void> open(Host current) async {
      final hosts = await repository.loadHosts();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => HostEditor(
                    host: current,
                    hosts: hosts,
                    onSave: (host, credentials) async {
                      await repository.saveHosts([gateway, dependent, host]);
                      await repository.saveCredentials(host.id, credentials);
                    },
                    onTest: (host, _) async => tested = host,
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
    }

    Future<void> select(String name) async {
      final menu = find.byType(DropdownMenuFormField<Host>);
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    Future<void> save() async {
      await tester.ensureVisible(find.text('保存连接'));
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
    }

    await open(target);
    await select('公网堡垒机');
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(tested?.jumpHostId, gateway.id);
    await save();
    final saved = (await repository.loadHosts()).last;
    expect(saved.jumpHostId, gateway.id);

    await open(saved);
    expect(find.text('公网堡垒机'), findsWidgets);
    await select('依赖目标的主机');
    await save();
    expect(find.text('中转主机存在循环引用，请修改连接配置。'), findsOneWidget);
    expect((await repository.loadHosts()).last.jumpHostId, gateway.id);
    await select('直接连接');
    await save();
    expect((await repository.loadHosts()).last.jumpHostId, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('密码留空时测试和保存免密码连接，重新编辑可改用密码', (tester) async {
    final repository = memoryRepository();
    const username =
        'cnb-kvr-1k40i3ljv-001.36fec6bd-9fc0-43ae-9f78-3de159c9cf4e-p13';
    const cnbHost = Host(
      id: 'cnb-host',
      name: 'CNB',
      address: 'cnb.space',
      username: username,
    );
    Host? tested;
    Credentials? testedCredentials;
    Future<void> open(Host host) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => HostEditor(
                    host: host,
                    onSave: (host, credentials) async {
                      await repository.saveHosts([host]);
                      await repository.saveCredentials(host.id, credentials);
                    },
                    onTest: (host, credentials) async {
                      tested = host;
                      testedCredentials = credentials;
                    },
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
    }

    await open(cnbHost);
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(tested?.authMethod, AuthMethod.none);
    expect(tested?.username, username);
    expect(testedCredentials?.password, isEmpty);
    expect(testedCredentials?.privateKey, isEmpty);
    expect(find.text('连接成功，SSH 身份验证已通过。'), findsOneWidget);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    final saved = (await repository.loadHosts()).single;
    expect(saved.authMethod, AuthMethod.none);
    expect(saved.userId, isEmpty);
    expect(await repository.credentials(saved.id), isNull);
    expect(await repository.loginCredentials(saved), isNotNull);

    await open(saved);
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码'),
      'new-password',
    );
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(
      (await repository.loadHosts()).single.authMethod,
      AuthMethod.password,
    );
    expect((await repository.credentials(saved.id))?.password, 'new-password');
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
