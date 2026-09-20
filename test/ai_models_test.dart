import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';

void main() {
  for (final protocol in AiProtocol.values) {
    test('获取模型 ${protocol.name}：无需模型名称，验证鉴权、去重和分页', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var pages = 0;
      server.listen((request) async {
        pages++;
        expect(request.method, 'GET');
        expect(request.uri.path, '/proxy/v1/models');
        if (protocol == AiProtocol.anthropic) {
          expect(request.headers.value('x-api-key'), 'test-key');
          expect(request.headers.value('anthropic-version'), '2023-06-01');
          expect(request.headers.value('authorization'), isNull);
          expect(request.uri.queryParameters['limit'], '100');
          if (pages == 2) {
            expect(request.uri.queryParameters['after_id'], 'model-b');
          }
        } else {
          expect(request.headers.value('authorization'), 'Bearer test-key');
          expect(request.headers.value('x-api-key'), isNull);
        }
        request.response.write(
          jsonEncode({
            'data': [
              {'id': pages == 1 ? 'model-b' : 'model-c'},
              {'id': 'model-a'},
              {'id': 'model-a'},
              {'id': ''},
            ],
            if (protocol == AiProtocol.anthropic) ...{
              'has_more': pages == 1,
              'last_id': pages == 1 ? 'model-b' : 'model-c',
            },
          }),
        );
        await request.response.close();
      });
      final client = TerminalAiClient();
      final models = await client.listModels(
        AiSettings(
          baseUrl:
              'http://127.0.0.1:${server.port}/proxy/v1/${protocol == AiProtocol.anthropic ? 'messages' : 'chat/completions'}',
          apiKey: 'test-key',
          protocol: protocol,
        ),
      );
      expect(
        models,
        protocol == AiProtocol.anthropic
            ? ['model-a', 'model-b', 'model-c']
            : ['model-a', 'model-b'],
      );
      client.cancel();
    });
  }

  test('获取失败、空列表、重复分页均返回明确错误且不泄露响应正文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var mode = 0;
    server.listen((request) async {
      if (mode == 0) {
        request.response.statusCode = 401;
        request.response.write('private-response-detail');
      } else if (mode == 1) {
        request.response.write('{"data":[]}');
      } else if (mode == 2) {
        request.response.write(
          '{"data":[{"id":"m"}],"has_more":true,"last_id":"m"}',
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final client = TerminalAiClient();
    final config = AiSettings(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      protocol: AiProtocol.anthropic,
    );
    await expectLater(
      client.listModels(config),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('API Key'), isNot(contains('private'))),
        ),
      ),
    );
    mode = 1;
    await expectLater(
      client.listModels(config),
      throwsA(
        isA<AiFailure>().having((e) => e.message, 'message', contains('未返回')),
      ),
    );
    mode = 2;
    await expectLater(
      client.listModels(config),
      throwsA(
        isA<AiFailure>().having((e) => e.message, 'message', contains('分页无效')),
      ),
    );
    mode = 3;
    await expectLater(
      client.listModels(config),
      throwsA(
        isA<AiFailure>().having((e) => e.message, 'message', contains('手动填写')),
      ),
    );
    client.cancel();
  });
}
