import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

void main() {
  test('图片按内容识别，拒绝伪装、损坏与过大文件，限制附件数量和总大小', () async {
    final image = await AiImage.fromBytes('renamed.jpg', base64Decode(png));
    expect(image.mimeType, 'image/png');
    expect(image.bytes, base64Decode(png));
    await expectLater(
      AiImage.fromBytes(
        'fake.png',
        Uint8List.fromList(utf8.encode('not an image')),
      ),
      throwsA(isA<AiFailure>()),
    );
    await expectLater(
      AiImage.fromBytes(
        'broken.png',
        Uint8List.fromList(base64Decode(png).take(16).toList()),
      ),
      throwsA(isA<AiFailure>()),
    );
    await expectLater(
      AiImage.fromStream(
        'large.png',
        Stream.fromIterable([
          Uint8List(AiImage.maxBytes),
          [0],
        ]),
      ),
      throwsA(
        isA<AiFailure>().having((e) => e.message, 'message', contains('5 MB')),
      ),
    );
    expect(
      () => AiImage.validateBatch(List.filled(5, image)),
      throwsA(isA<AiFailure>()),
    );
    // Trailing bytes are legal for this decoder; they still count toward limits.
    final padded = Uint8List(4 * 1024 * 1024 + 1)..setAll(0, base64Decode(png));
    final large = await AiImage.fromBytes('padded.png', padded);
    expect(
      () => AiImage.validateBatch(List.filled(3, large)),
      throwsA(isA<AiFailure>()),
    );
  });

  for (final protocol in AiProtocol.values) {
    for (final text in ['', '根据图片检查服务器']) {
      test(
        '$protocol 图片消息与工具结果通过真实 HTTP 完整往返（文字：${text.isNotEmpty}）',
        () async {
          final image = await AiImage.fromBytes(
            'screenshot.png',
            base64Decode(png),
          );
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <Map>[];
          server.listen((request) async {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            requests.add(body);
            final messages = body['messages'] as List;
            final user = messages.firstWhere((m) => m['role'] == 'user') as Map;
            final blocks = user['content'] as List;
            expect(blocks.length, text.isEmpty ? 2 : 3);
            for (final block in blocks.take(2)) {
              if (protocol == AiProtocol.openai) {
                expect(block['type'], 'image_url');
                expect(block['image_url']['url'], 'data:image/png;base64,$png');
              } else {
                expect(block['type'], 'image');
                expect(block['source'], {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': png,
                });
              }
            }
            if (text.isNotEmpty) {
              expect(blocks.last, {'type': 'text', 'text': text});
            }
            if (requests.length == 2) {
              expect(jsonEncode(messages.last), contains('server output'));
            }
            final call = {
              'command': 'pwd',
              'reason': '检查工作目录',
              'requires_approval': false,
            };
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode(
                protocol == AiProtocol.openai
                    ? {
                        'choices': [
                          {
                            'finish_reason': requests.length == 1
                                ? 'tool_calls'
                                : 'stop',
                            'message': {
                              'role': 'assistant',
                              'content': requests.length == 1 ? null : '图片已分析',
                              if (requests.length == 1)
                                'tool_calls': [
                                  {
                                    'id': 'tool-1',
                                    'type': 'function',
                                    'function': {
                                      'name': 'run_command',
                                      'arguments': jsonEncode(call),
                                    },
                                  },
                                ],
                            },
                          },
                        ],
                      }
                    : {
                        'type': 'message',
                        'role': 'assistant',
                        'stop_reason': requests.length == 1
                            ? 'tool_use'
                            : 'end_turn',
                        'content': [
                          requests.length == 1
                              ? {
                                  'type': 'tool_use',
                                  'id': 'tool-1',
                                  'name': 'run_command',
                                  'input': call,
                                }
                              : {'type': 'text', 'text': '图片已分析'},
                        ],
                      },
              ),
            );
            await request.response.close();
          });
          final executor = _Executor();
          final task = AiTaskController(
            settings: () => AiSettings(
              baseUrl: 'http://127.0.0.1:${server.port}/v1',
              model: 'vision',
              protocol: protocol,
            ),
            executorFactory: () => executor,
            connected: () => true,
          );
          await task.start(text, images: [image, image]);
          expect(task.failure, isNull);
          expect(requests, hasLength(2));
          expect(executor.calls, 1);
          expect(task.entries.first.images, hasLength(2));
          expect(task.entries.last.text, '图片已分析');
          await task.start('接着解释上一张截图');
          expect(task.failure, isNull);
          expect(requests, hasLength(3));
          final history = requests.last['messages'] as List;
          expect(jsonEncode(history), contains('server output'));
          expect(jsonEncode(history), contains('图片已分析'));
          expect(jsonEncode(history.last), contains('接着解释上一张截图'));
          expect(task.entries.where((e) => e.user == true), hasLength(2));
          expect(task.entries.first.images, hasLength(2));
          task.dispose();
        },
      );
    }
  }

  test('图片被模型拒绝时给出清晰错误，不执行命令或回显服务端内容', () async {
    final image = await AiImage.fromBytes('screenshot.png', base64Decode(png));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.statusCode = 400;
      request.response.write('secret server error');
      await request.response.close();
    });
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'text-only',
      ),
      executorFactory: () => executor,
      connected: () => true,
    );
    await task.start('', images: [image]);
    expect(requests, 1);
    expect(task.failure, allOf(contains('支持图片'), isNot(contains('secret'))));
    expect(executor.calls, 0);
    expect(task.entries.first.images, hasLength(1));
    task.dispose();
  });
}

class _Executor implements AiCommandExecutor {
  int calls = 0;
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    calls++;
    return const AiCommandResult('server output', 0);
  }

  @override
  void cancel() {}
}
