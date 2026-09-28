import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';

import 'support.dart';

/// Unique marker that must never appear in a stored file or a plain preference.
const _sentinel = 'SSH-历史-哨兵-9f3a-工具输出';
const _scope = 'host-1|dev.example.com|deploy';

AiConversation _conversation({
  required String id,
  String scope = _scope,
  String title = '检查磁盘',
  String model = 'test-model',
  String text = _sentinel,
  DateTime? updatedAt,
}) => AiConversation(
  id: id,
  scope: scope,
  title: title,
  model: model,
  createdAt: DateTime(2024),
  updatedAt: updatedAt ?? DateTime(2024, 1, 2),
  entries: [
    {'text': '看看磁盘', 'user': true},
    {
      'text': 'df -h',
      'command': true,
      'output': text,
      'exitCode': 0,
      'finished': true,
    },
  ],
  history: [
    {'role': 'user', 'content': '看看磁盘'},
    {'role': 'assistant', 'content': text},
  ],
  contextModel: 'https://example.com/v1|openai|$model',
);

Future<List<File>> _files(Directory root) async => [
  await for (final entity in root.list(recursive: true))
    if (entity is File) entity,
];

Future<File> _indexFile(Directory root) async =>
    (await _files(root)).singleWhere((file) => file.path.endsWith('index.bin'));

Future<File> _contentFile(Directory root) async =>
    (await _files(root))
        .singleWhere((file) => !file.path.endsWith('index.bin'));

/// Mirrors the store's layout so a test can move a specific sealed file.
Future<Directory> _scopeDirectory(Directory root, String scope) async {
  final digest = await Sha256().hash(utf8.encode(scope));
  final name = digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return Directory(
    '${root.path}${Platform.pathSeparator}ai_conversations'
    '${Platform.pathSeparator}$name',
  );
}

Future<File> _contentFileFor(Directory root, String scope, String id) async {
  final directory = await _scopeDirectory(root, scope);
  return File(
    '${directory.path}${Platform.pathSeparator}'
    '${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.bin',
  );
}

void main() {
  late Directory root;
  late MemoryStore secrets;
  late AiConversationStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('harbor-ai-history');
    secrets = MemoryStore();
    store = AiConversationStore(secrets: secrets, directory: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('保存后可列出、打开并删除，删除后不可恢复', () async {
    final first = _conversation(id: 'a', updatedAt: DateTime(2024));
    final second = _conversation(id: 'b', updatedAt: DateTime(2025));
    await store.save(first);
    await store.save(second);

    final listed = await store.list(_scope);
    expect(listed.map((item) => item.id), ['b', 'a']);
    expect(listed.first.title, '检查磁盘');
    expect(listed.first.model, 'test-model');

    final loaded = await store.load(_scope, 'a');
    expect(loaded, isNotNull);
    expect(loaded!.id, 'a');
    expect(loaded.title, '检查磁盘');
    expect(loaded.entries.first['text'], '看看磁盘');
    expect(loaded.entries.last['output'], _sentinel);
    expect(loaded.history.last['content'], _sentinel);
    expect(loaded.contextModel, 'https://example.com/v1|openai|test-model');

    await store.delete(_scope, 'a');
    expect(await store.load(_scope, 'a'), isNull);
    expect((await store.list(_scope)).map((item) => item.id), ['b']);
    expect(
      (await _files(root)).where((file) => file.path.endsWith('.bin')),
      hasLength(2),
      reason: '删除后只剩索引与 b 的密文',
    );
  });

  test('同一 id 重复保存以最后一次为准', () async {
    await store.save(
      _conversation(id: 'a', text: '第一次', updatedAt: DateTime(2024)),
    );
    await store.save(
      _conversation(id: 'a', text: '第二次', updatedAt: DateTime(2025)),
    );
    final loaded = await store.load(_scope, 'a');
    expect(loaded!.entries.last['output'], '第二次');
    expect(await store.list(_scope), hasLength(1));
  });

  test('磁盘与安全存储中都没有明文，密钥只写入 secrets', () async {
    await store.save(_conversation(id: 'a'));
    final files = await _files(root);
    expect(files, isNotEmpty);
    for (final file in files) {
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      expect(text, isNot(contains(_sentinel)), reason: file.path);
      expect(text, isNot(contains('检查磁盘')), reason: file.path);
      expect(text, isNot(contains('df -h')), reason: file.path);
    }
    expect(secrets.values.keys, [AiConversationStore.keyName]);
    final key = base64Decode(secrets.values.values.single);
    expect(key, hasLength(32));
  });

  test('不同 scope 的历史互相隔离', () async {
    await store.save(_conversation(id: 'a', scope: 'host-1|x|u'));
    await store.save(_conversation(id: 'b', scope: 'host-2|y|v'));
    expect((await store.list('host-1|x|u')).single.id, 'a');
    expect((await store.list('host-2|y|v')).single.id, 'b');
    expect(await store.load('host-1|x|u', 'b'), isNull);
  });

  test('内容文件损坏时明确报错，且不覆盖原文件、不影响索引', () async {
    await store.save(_conversation(id: 'a'));
    final file = await _contentFile(root);
    await file.writeAsBytes(utf8.encode('{"format":"broken"}'));
    final corrupted = await file.readAsBytes();

    await expectLater(
      store.load(_scope, 'a'),
      throwsA(isA<AiConversationFailure>()),
    );
    expect(await file.readAsBytes(), corrupted);
    expect((await store.list(_scope)).single.id, 'a');
  });

  test('索引损坏时保存被拒绝，已有密文保持原样', () async {
    await store.save(_conversation(id: 'a', text: '原内容'));
    final content = await _contentFile(root);
    final before = await content.readAsBytes();
    final index = await _indexFile(root);
    await index.writeAsBytes(utf8.encode('{"format":"broken"}'));

    await expectLater(
      store.save(_conversation(id: 'a', text: '新内容')),
      throwsA(isA<AiConversationFailure>()),
    );
    expect(await content.readAsBytes(), before);
    await expectLater(
      store.list(_scope),
      throwsA(isA<AiConversationFailure>()),
    );
  });

  test('历史仍在但密钥缺失时拒绝生成新密钥，不覆盖已有密文', () async {
    await store.save(_conversation(id: 'a'));
    secrets.values.clear();
    final reopened = AiConversationStore(
      secrets: secrets,
      directory: () async => root,
    );

    await expectLater(
      reopened.list(_scope),
      throwsA(isA<AiConversationFailure>()),
    );
    expect(secrets.values, isEmpty);
    expect((await _files(root)), isNotEmpty);
  });

  test('密钥损坏时明确报错并保留原值', () async {
    await store.save(_conversation(id: 'a'));
    secrets.values[AiConversationStore.keyName] = 'not@base64!!';
    final reopened = AiConversationStore(
      secrets: secrets,
      directory: () async => root,
    );

    await expectLater(
      reopened.list(_scope),
      throwsA(isA<AiConversationFailure>()),
    );
    expect(secrets.values[AiConversationStore.keyName], 'not@base64!!');
  });

  test('保存更多历史不会静默淘汰旧对话', () async {
    for (var index = 0; index < 101; index++) {
      await store.save(
        _conversation(
          id: 'id-$index',
          updatedAt: DateTime(2024, 1, 1).add(Duration(minutes: index)),
        ),
      );
    }
    final listed = await store.list(_scope);
    expect(listed, hasLength(101));
    expect(listed.last.id, 'id-0');
    expect(await store.load(_scope, 'id-0'), isNotNull);
    expect(
      (await store.load(_scope, 'id-100'))!.summary.updatedAt,
      listed.first.updatedAt,
    );
  });

  test('删除会连同 .new/.bak 残留一起清除，不会被恢复', () async {
    await store.save(_conversation(id: 'a'));
    final content = await _contentFile(root);
    await content.copy('${content.path}.bak');
    await content.copy('${content.path}.new');

    await store.delete(_scope, 'a');

    expect(await store.load(_scope, 'a'), isNull);
    expect(await content.exists(), isFalse);
    expect(await File('${content.path}.new').exists(), isFalse);
    expect(await File('${content.path}.bak').exists(), isFalse);
    expect(await store.list(_scope), isEmpty);
  });

  test('跨 scope 搬运的密文无法通过认证，原 scope 仍可读', () async {
    await store.save(_conversation(id: 'a', scope: 'host-1|x|u'));
    final source = await _scopeDirectory(root, 'host-1|x|u');
    final target = await _scopeDirectory(root, 'host-2|y|v');
    await target.create(recursive: true);
    for (final file in await _files(source)) {
      await file.copy(
        '${target.path}${Platform.pathSeparator}${file.uri.pathSegments.last}',
      );
    }

    await expectLater(
      store.list('host-2|y|v'),
      throwsA(isA<AiConversationFailure>()),
    );
    await expectLater(
      store.load('host-2|y|v', 'a'),
      throwsA(isA<AiConversationFailure>()),
    );
    expect((await store.list('host-1|x|u')).single.id, 'a');
    expect(
      (await store.load('host-1|x|u', 'a'))!.entries.first['text'],
      '看看磁盘',
    );
  });

  test('同一 scope 内换到别的 id 也无法通过认证', () async {
    await store.save(_conversation(id: 'a', text: '甲的密文'));
    await store.save(_conversation(id: 'b', text: '乙的密文'));
    final fileA = await _contentFileFor(root, _scope, 'a');
    final fileB = await _contentFileFor(root, _scope, 'b');
    await fileA.copy(fileB.path);

    var failures = 0;
    for (final id in ['a', 'b']) {
      try {
        await store.load(_scope, id);
      } on AiConversationFailure {
        failures++;
      }
    }
    expect(failures, 1, reason: '被换位的密文必然认证失败');
    expect((await store.load(_scope, 'a'))!.entries.last['output'], '甲的密文');
  });

  test('中断的写入（.new 残留）在读取时被恢复', () async {
    await store.save(_conversation(id: 'a'));
    final index = await _indexFile(root);
    await index.rename('${index.path}.new');

    expect((await store.list(_scope)).single.id, 'a');
    expect(await index.exists(), isTrue);
    expect(await File('${index.path}.new').exists(), isFalse);
  });
}
