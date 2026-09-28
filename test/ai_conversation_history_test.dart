import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

import 'support.dart';

const _scope = 'host-1|dev.example.com|deploy';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

/// Mirrors the store's per-scope directory so a test can break writes only.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late MemoryStore secrets;
  late bool directoryFails;
  late AiConversationStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('harbor-ai-controller');
    secrets = MemoryStore();
    directoryFails = false;
    store = AiConversationStore(
      secrets: secrets,
      directory: () async {
        if (directoryFails) throw const FileSystemException('磁盘不可用');
        return root;
      },
    );
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await root.exists()) await root.delete(recursive: true);
        return;
      } on FileSystemException {
        // A background save may still hold a handle on Windows.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  AiTaskController build(
    TerminalAiClient client, {
    String model = 'base-model',
    bool withHistory = true,
  }) => AiTaskController(
    settings: () => AiSettings(baseUrl: 'https://example.com/v1', model: model),
    executorFactory: _Executor.new,
    connected: () => true,
    clientFactory: () => client,
    historyStore: withHistory ? store : null,
    historyScope: withHistory ? _scope : null,
  );

  test('重启后列出历史并继续对话，条目与上下文一起恢复', () async {
    final first = build(_Client([]));
    await first.start('检查磁盘空间');
    final id = first.activeConversationId;
    expect(id, isNotNull);
    await first.loadHistory();
    expect(first.conversations.single.id, id);
    expect(first.conversations.single.title, '检查磁盘空间');
    first.dispose();

    final client = _Client([]);
    final reopened = build(client);
    await reopened.loadHistory();
    expect(reopened.conversations.map((item) => item.id), [id]);
    expect(reopened.activeConversationId, isNull);

    await reopened.openConversation(id!);
    expect(reopened.activeConversationId, id);
    expect(reopened.entries.first.text, '检查磁盘空间');

    await reopened.start('继续');
    final sent = client.requests.last;
    expect(sent.map((message) => message['role']), [
      'system',
      'user',
      'assistant',
      'user',
    ]);
    expect(jsonEncode(sent), contains('检查磁盘空间'));
  });

  test('切换会话恢复对应的条目与模型', () async {
    final task = build(_Client([]));
    await task.start('第一个话题');
    final firstId = task.activeConversationId!;
    task.setModel('second-model');
    await task.newConversation();
    await task.start('第二个话题');
    final secondId = task.activeConversationId!;
    expect(secondId, isNot(firstId));
    expect(task.activeModel, 'second-model');

    await task.openConversation(firstId);
    expect(task.activeConversationId, firstId);
    expect(task.entries.first.text, '第一个话题');
    expect(task.activeModel, 'base-model');

    await task.openConversation(secondId);
    expect(task.activeConversationId, secondId);
    expect(task.entries.first.text, '第二个话题');
    expect(task.activeModel, 'second-model');
    task.dispose();
  });

  test('新对话先归档当前会话再清空，历史仍可打开', () async {
    final task = build(_Client([]));
    await task.start('第一轮');
    final id = task.activeConversationId!;

    await task.newConversation();
    expect(task.entries, isEmpty);
    expect(task.activeConversationId, isNull);

    await task.loadHistory();
    expect(task.conversations.single.id, id);
    await task.openConversation(id);
    expect(task.entries.first.text, '第一轮');
    task.dispose();
  });

  test('删除当前会话后回到空白会话，且删除不可恢复', () async {
    final task = build(_Client([]));
    await task.start('第一轮');
    final id = task.activeConversationId!;
    await task.loadHistory();
    expect(task.conversations, hasLength(1));

    await task.deleteConversation(id);
    expect(task.conversations, isEmpty);
    expect(task.activeConversationId, isNull);
    expect(task.entries, isEmpty);
    expect(await store.load(_scope, id), isNull);
    task.dispose();
  });

  test('任务运行中禁止切换与删除历史', () async {
    final seed = build(_Client([]));
    await seed.start('历史话题');
    final id = seed.activeConversationId!;
    await seed.newConversation();
    await seed.loadHistory();
    expect(seed.conversations.single.id, id);
    seed.dispose();

    final client = _Client([])..pending = Completer<AiReply>();
    final task = build(client);
    await task.loadHistory();
    final started = task.start('进行中的任务');
    expect(task.running, isTrue);

    await task.openConversation(id);
    expect(task.activeConversationId, isNull);
    expect(task.entries.single.text, '进行中的任务');

    await task.deleteConversation(id);
    expect(task.conversations.map((item) => item.id), [id]);

    task.stop();
    await started;
    expect(task.running, isFalse);
    task.dispose();
  });

  test('保存失败时保留当前会话、显示错误且不覆盖既有密文', () async {
    final task = build(_Client([]));
    await task.start('第一轮');
    final id = task.activeConversationId!;
    await task.loadHistory();
    expect((await store.load(_scope, id))!.entries.first['text'], '第一轮');

    directoryFails = true;
    await task.start('第二轮');
    await task.loadHistory();

    expect(task.historyFailure, contains('历史对话失败'));
    expect(task.activeConversationId, id);
    expect(task.entries.map((entry) => entry.text), contains('第二轮'));

    directoryFails = false;
    final stored = await store.load(_scope, id);
    expect(stored, isNotNull);
    expect(stored!.entries.first['text'], '第一轮');
    expect(jsonEncode(stored.history), isNot(contains('第二轮')));
    task.dispose();
  });

  test('图片随对话加密保存，恢复后条目与下一轮上下文一致', () async {
    final image = await AiImage.fromBytes('shot.png', base64Decode(_png));
    final first = build(_Client([]));
    await first.start('看看这张图', images: [image]);
    final id = first.activeConversationId!;
    await first.loadHistory();
    first.dispose();

    final reopened = build(_Client([]));
    await reopened.loadHistory();
    await reopened.openConversation(id);
    expect(reopened.entries.first.images, hasLength(1));
    expect(reopened.entries.first.images!.single.bytes, base64Decode(_png));

    final client = _Client([]);
    final resumed = build(client);
    await resumed.openConversation(id);
    await resumed.start('继续');
    expect(
      jsonEncode(client.requests.last),
      contains('data:image/png;base64,'),
    );
    resumed.dispose();
  });

  test('历史中的图片无法解码时打开失败并保留当前会话', () async {
    await store.save(
      AiConversation(
        id: 'broken-image',
        scope: _scope,
        title: '带图对话',
        model: 'base-model',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        entries: [
          {
            'text': '看看这张图',
            'user': true,
            'images': [
              {
                'name': 'broken.png',
                'mime': 'image/png',
                'bytes': base64Encode(utf8.encode('not an image')),
              },
            ],
          },
        ],
        history: [
          {'role': 'user', 'content': '看看这张图'},
        ],
      ),
    );

    final task = build(_Client([]));
    await task.start('当前会话');
    await task.loadHistory();
    await task.openConversation('broken-image');

    expect(task.historyFailure, contains('图片'));
    expect(task.activeConversationId, isNot('broken-image'));
    expect(task.entries.first.text, '当前会话');
    task.dispose();
  });

  test('新对话保存失败时保留当前会话，保存成功后恢复', () async {
    final task = build(_Client([]));
    await task.start('第一轮');
    await task.loadHistory();
    expect(task.entries, isNotEmpty);
    final currentId = task.activeConversationId;

    directoryFails = true;
    await task.newConversation();
    expect(task.historyFailure, contains('历史对话失败'));
    expect(task.entries.map((entry) => entry.text), contains('第一轮'));
    expect(task.activeConversationId, currentId);

    directoryFails = false;
    await task.newConversation();
    expect(task.historyFailure, isNull);
    expect(task.entries, isEmpty);
    expect(task.activeConversationId, isNull);
    task.dispose();
  });

  test('切换会话前保存失败时不切走当前会话', () async {
    final seed = build(_Client([]));
    await seed.start('旧话题');
    final id = seed.activeConversationId!;
    await seed.newConversation();
    await seed.loadHistory();
    expect(seed.conversations.single.id, id);
    seed.dispose();

    final task = build(_Client([]));
    await task.start('当前话题');
    await task.loadHistory();
    final currentId = task.activeConversationId;

    directoryFails = true;
    await task.openConversation(id);

    expect(task.historyFailure, contains('历史对话失败'));
    expect(task.entries.first.text, '当前话题');
    expect(task.activeConversationId, currentId);
    task.dispose();
  });

  test('读取成功不会抹掉未解决的保存错误', () async {
    final task = build(_Client([]));
    await task.start('第一轮');
    await task.loadHistory();
    expect(task.conversations, hasLength(1));

    // 让 scope 目录变成文件：读取退化为空索引，写入必然失败。
    final directory = await _scopeDirectory(root, _scope);
    await directory.delete(recursive: true);
    await File(directory.path).writeAsString('blocked');

    await task.start('第二轮');
    await task.loadHistory();

    expect(task.historyFailure, contains('历史对话失败'));
    expect(task.entries.map((entry) => entry.text), contains('第二轮'));
    task.dispose();
  });

  test('未接入历史存储时不触碰平台存储，单会话行为不变', () async {
    final task = build(_Client([]), withHistory: false);
    await task.loadHistory();
    expect(task.conversations, isEmpty);
    expect(task.historyLoading, isFalse);
    expect(task.historyFailure, isNull);

    await task.start('第一轮');
    expect(task.entries.first.text, '第一轮');
    expect(task.activeConversationId, isNull);
    // 未接入历史存储时仍同步清空，既有行为不变。
    task.newConversation();
    expect(task.entries, isEmpty);
    await task.deleteConversation('missing');
    expect(task.conversations, isEmpty);
    task.dispose();
  });

  test('纯预览历史不改变当前会话，预览后继续仍用当前上下文', () async {
    final seed = build(_Client([]));
    await seed.start('历史话题B');
    final archivedId = seed.activeConversationId!;
    await seed.loadHistory();
    expect(seed.conversations.single.id, archivedId);
    seed.dispose();

    final client = _Client([
      const AiReply({'role': 'assistant', 'content': 'A的回答'}, []),
    ]);
    final task = build(client);
    await task.start('当前话题A');
    final currentId = task.activeConversationId;
    final entriesBefore = [for (final entry in task.entries) entry.text];
    final modelBefore = task.activeModel;

    final preview = await task.previewConversation(archivedId);
    expect(preview, isNotNull);
    expect(preview!.map((entry) => entry.text), contains('历史话题B'));
    expect(preview.map((entry) => entry.text), isNot(contains('当前话题A')));

    // 纯预览不改活跃会话、模型或当前条目。
    expect(task.activeConversationId, currentId);
    expect(task.activeModel, modelBefore);
    expect([for (final entry in task.entries) entry.text], entriesBefore);

    // 预览当前会话只给出实时条目快照。
    final live = await task.previewConversation(currentId!);
    expect(live!.map((entry) => entry.text), contains('当前话题A'));
    expect(task.activeConversationId, currentId);

    // 预览历史后继续当前对话，仍发送当前会话的上下文而非被预览的会话。
    client.requests.clear();
    await task.start('继续A');
    final sent = jsonEncode(client.requests.last);
    expect(sent, contains('当前话题A'));
    expect(sent, contains('继续A'));
    expect(sent, isNot(contains('历史话题B')));
    task.dispose();
  });

  test('预览损坏或缺失的历史记录时报错、返回空且保留当前会话', () async {
    await store.save(
      AiConversation(
        id: 'broken-preview',
        scope: _scope,
        title: '带图对话',
        model: 'base-model',
        createdAt: DateTime(2024),
        updatedAt: DateTime(2024),
        entries: [
          {
            'text': '看看这张图',
            'user': true,
            'images': [
              {
                'name': 'broken.png',
                'mime': 'image/png',
                'bytes': base64Encode(utf8.encode('not an image')),
              },
            ],
          },
        ],
        history: [
          {'role': 'user', 'content': '看看这张图'},
        ],
      ),
    );

    final task = build(_Client([]));
    await task.start('当前会话');
    final currentId = task.activeConversationId;
    final entriesBefore = [for (final entry in task.entries) entry.text];

    final preview = await task.previewConversation('broken-preview');
    expect(preview, isNull);
    expect(task.historyFailure, contains('图片'));
    expect(task.activeConversationId, currentId);
    expect([for (final entry in task.entries) entry.text], entriesBefore);

    final missing = await task.previewConversation('no-such-id');
    expect(missing, isNull);
    expect(task.historyFailure, contains('不存在'));
    expect(task.activeConversationId, currentId);
    task.dispose();
  });

  test('任务运行中允许预览，但预览不改变进行中的会话', () async {
    final seed = build(_Client([]));
    await seed.start('历史话题B');
    final archivedId = seed.activeConversationId!;
    await seed.loadHistory();
    seed.dispose();

    final client = _Client([])..pending = Completer<AiReply>();
    final task = build(client);
    await task.loadHistory();
    final started = task.start('进行中的任务');
    expect(task.running, isTrue);
    final entriesBefore = [for (final entry in task.entries) entry.text];

    final preview = await task.previewConversation(archivedId);
    expect(preview, isNotNull);
    expect(preview!.map((entry) => entry.text), contains('历史话题B'));
    expect(task.entries.map((entry) => entry.text), entriesBefore);
    expect(task.activeConversationId, isNull);
    expect(task.running, isTrue);

    task.stop();
    await started;
    task.dispose();
  });
}

class _Client extends TerminalAiClient {
  _Client(this.replies);
  final List<AiReply> replies;
  final requests = <List<Map<String, dynamic>>>[];
  Completer<AiReply>? pending;

  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    requests.add([
      for (final message in messages) Map<String, dynamic>.from(message),
    ]);
    final blocked = pending;
    if (blocked != null) return blocked.future;
    if (replies.isEmpty) {
      return const AiReply({'role': 'assistant', 'content': '完成'}, []);
    }
    return replies.removeAt(0);
  }

  @override
  void cancel() {
    final blocked = pending;
    if (blocked != null && !blocked.isCompleted) {
      blocked.complete(
        const AiReply({'role': 'assistant', 'content': '已取消'}, []),
      );
    }
  }
}

class _Executor implements AiCommandExecutor {
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    onOutput('ok');
    return const AiCommandResult('ok', 0);
  }

  @override
  void cancel() {}
}
