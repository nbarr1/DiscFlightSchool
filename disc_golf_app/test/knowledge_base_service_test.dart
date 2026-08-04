import 'dart:async' show TimeoutException;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:disc_golf_app/services/knowledge_base_service.dart';

/// Build a service whose Anthropic calls are served by [handler].
Future<KnowledgeBaseService> serviceWith(
  Future<http.Response> Function(http.Request request) handler, {
  String apiKey = 'sk-ant-test',
}) async {
  final service = KnowledgeBaseService(client: MockClient(handler));
  // Wait on the constructor's key load explicitly. Draining a fixed number of
  // microtasks instead is a race: when the load lands late the request is
  // never sent, and the test fails on an unassigned `late` variable.
  await service.initialized;
  await service.setApiKey(apiKey);
  return service;
}

String messageBody({
  List<Map<String, dynamic>>? content,
  String stopReason = 'end_turn',
}) {
  return jsonEncode({
    'id': 'msg_1',
    'type': 'message',
    'role': 'assistant',
    'model': KnowledgeBaseService.claudeModel,
    'stop_reason': stopReason,
    'content': content ?? [
      {'type': 'text', 'text': 'Grip pressure matters (Greenway, 2007).'}
    ],
    'usage': {'input_tokens': 10, 'output_tokens': 5},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('extractAnswerText', () {
    test('reads a plain text block', () {
      final body = {
        'content': [
          {'type': 'text', 'text': 'hello'}
        ]
      };
      expect(KnowledgeBaseService.extractAnswerText(body), 'hello');
    });

    test('skips a leading thinking block', () {
      // Regression: the old code read content[0]['text'] unconditionally. On
      // claude-sonnet-5 adaptive thinking is on by default when `thinking` is
      // omitted, so content[0] can be a thinking block with no `text` field —
      // the cast threw instead of returning the answer.
      final body = {
        'content': [
          {'type': 'thinking', 'thinking': '', 'signature': 'abc'},
          {'type': 'text', 'text': 'the real answer'},
        ]
      };
      expect(KnowledgeBaseService.extractAnswerText(body), 'the real answer');
    });

    test('concatenates multiple text blocks', () {
      final body = {
        'content': [
          {'type': 'text', 'text': 'part one. '},
          {'type': 'text', 'text': 'part two.'},
        ]
      };
      expect(
        KnowledgeBaseService.extractAnswerText(body),
        'part one. part two.',
      );
    });

    test('ignores non-text blocks entirely', () {
      final body = {
        'content': [
          {'type': 'tool_use', 'id': 't1', 'name': 'x', 'input': {}},
          {'type': 'redacted_thinking', 'data': 'zzz'},
        ]
      };
      expect(KnowledgeBaseService.extractAnswerText(body), isNull);
    });

    test('returns null for an empty content list', () {
      expect(KnowledgeBaseService.extractAnswerText({'content': []}), isNull);
    });

    test('returns null when content is missing or malformed', () {
      expect(KnowledgeBaseService.extractAnswerText({}), isNull);
      expect(
        KnowledgeBaseService.extractAnswerText({'content': 'not a list'}),
        isNull,
      );
    });

    test('returns null when text blocks are blank', () {
      final body = {
        'content': [
          {'type': 'text', 'text': '   '}
        ]
      };
      expect(KnowledgeBaseService.extractAnswerText(body), isNull);
    });

    test('tolerates a text block with a non-string text field', () {
      final body = {
        'content': [
          {'type': 'text', 'text': 42},
          {'type': 'text', 'text': 'ok'},
        ]
      };
      expect(KnowledgeBaseService.extractAnswerText(body), 'ok');
    });
  });

  group('messageForErrorStatus', () {
    test('401 tells the user to check their key', () {
      expect(
        KnowledgeBaseService.messageForErrorStatus(401),
        contains('Invalid API key'),
      );
    });

    test('429 mentions rate limiting', () {
      expect(
        KnowledgeBaseService.messageForErrorStatus(429),
        contains('Rate limited'),
      );
    });

    test('529 mentions overload', () {
      expect(
        KnowledgeBaseService.messageForErrorStatus(529),
        contains('overloaded'),
      );
    });

    test('5xx is reported as a server error', () {
      expect(
        KnowledgeBaseService.messageForErrorStatus(500),
        contains('server error'),
      );
    });

    test('unknown statuses still produce a message with the code', () {
      expect(KnowledgeBaseService.messageForErrorStatus(418), contains('418'));
    });
  });

  group('askQuestion request shape', () {
    test('targets a current, non-retired model', () {
      // claude-sonnet-4-20250514 reached its retirement date; pinning a dated
      // snapshot here is what broke AI search.
      expect(KnowledgeBaseService.claudeModel, isNot(contains('20250514')));
      expect(KnowledgeBaseService.claudeModel, 'claude-sonnet-5');
    });

    test('sends the documented headers and body', () async {
      late http.Request captured;
      final service = await serviceWith((request) async {
        captured = request;
        return http.Response(messageBody(), 200);
      });

      await service.askQuestion('How do I throw further?');

      expect(captured.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(captured.headers['x-api-key'], 'sk-ant-test');
      expect(captured.headers['anthropic-version'], '2023-06-01');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['model'], KnowledgeBaseService.claudeModel);
      expect(body['max_tokens'], KnowledgeBaseService.claudeMaxTokens);
      expect(body['system'], contains('disc golf research assistant'));
      expect((body['messages'] as List).single['content'],
          'How do I throw further?');
    });

    test('disables thinking explicitly so max_tokens covers only the answer',
        () async {
      // On claude-sonnet-5, omitting `thinking` runs adaptive thinking, and
      // max_tokens caps thinking + text together — a short cap would truncate
      // the answer.
      late Map<String, dynamic> body;
      final service = await serviceWith((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(messageBody(), 200);
      });

      await service.askQuestion('q');

      expect(body['thinking'], {'type': 'disabled'});
    });

    test('does not send removed sampling parameters', () async {
      // temperature/top_p/top_k are rejected with a 400 on current models.
      late Map<String, dynamic> body;
      final service = await serviceWith((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(messageBody(), 200);
      });

      await service.askQuestion('q');

      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('top_k'), isFalse);
    });

    test('does not use an assistant prefill', () async {
      // Trailing assistant turns are rejected on current models.
      late Map<String, dynamic> body;
      final service = await serviceWith((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(messageBody(), 200);
      });

      await service.askQuestion('q');

      final messages = body['messages'] as List;
      expect(messages.last['role'], 'user');
    });
  });

  group('askQuestion response handling', () {
    test('returns the answer text', () async {
      final service = await serviceWith(
        (_) async => http.Response(messageBody(), 200),
      );
      expect(
        await service.askQuestion('q'),
        'Grip pressure matters (Greenway, 2007).',
      );
    });

    test('survives a thinking block arriving first', () async {
      final service = await serviceWith(
        (_) async => http.Response(
          messageBody(content: [
            {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
            {'type': 'text', 'text': 'answer after thinking'},
          ]),
          200,
        ),
      );
      expect(await service.askQuestion('q'), 'answer after thinking');
    });

    test('flags a truncated answer instead of presenting it as complete',
        () async {
      final service = await serviceWith(
        (_) async => http.Response(
          messageBody(stopReason: 'max_tokens'),
          200,
        ),
      );
      final answer = await service.askQuestion('q');
      expect(answer, contains('Grip pressure matters'));
      expect(answer, contains('cut off'));
    });

    test('reports a refusal distinctly', () async {
      final service = await serviceWith(
        (_) async => http.Response(
          messageBody(content: [], stopReason: 'refusal'),
          200,
        ),
      );
      expect(await service.askQuestion('q'), contains('declined'));
    });

    test('maps a 401 to the invalid-key message', () async {
      final service = await serviceWith(
        (_) async => http.Response('{"error":{}}', 401),
      );
      expect(await service.askQuestion('q'), contains('Invalid API key'));
    });

    test('handles a non-JSON body without throwing', () async {
      final service = await serviceWith(
        (_) async => http.Response('<html>gateway</html>', 200),
      );
      expect(await service.askQuestion('q'), contains('Connection error'));
    });

    test('handles a JSON body that is not an object', () async {
      final service = await serviceWith(
        (_) async => http.Response('[1,2,3]', 200),
      );
      expect(await service.askQuestion('q'), contains('Unexpected response'));
    });

    test('reports a network failure as a connection error', () async {
      final service = await serviceWith(
        (_) async => throw const SocketExceptionStub(),
      );
      expect(await service.askQuestion('q'), contains('Connection error'));
    });

    test('a TimeoutException is reported distinctly from a connection error',
        () async {
      // Raised directly rather than by waiting out the real 45s timeout, so
      // this stays a fast unit test.
      final service = await serviceWith(
        (_) async => throw TimeoutException('deadline exceeded'),
      );
      expect(await service.askQuestion('q'), contains('timed out'));
    });

    test('a request timeout is configured', () {
      expect(KnowledgeBaseService.claudeTimeout.inSeconds, greaterThan(0));
      expect(
        KnowledgeBaseService.claudeTimeout.inSeconds,
        lessThanOrEqualTo(120),
        reason: 'a mobile client should not hang for minutes on a dead server',
      );
    });

    test('asks for a key when none is configured', () async {
      final service = KnowledgeBaseService(
        client: MockClient((_) async => throw StateError('should not be called')),
      );
      await service.initialized;
      expect(await service.askQuestion('q'), contains('add your Anthropic API key'));
    });
  });

  group('API key loading', () {
    test('initialized completes even when secure storage is unavailable', () async {
      // flutter_secure_storage throws MissingPluginException in unit tests,
      // which is the same shape as a real storage failure on device.
      final service = KnowledgeBaseService(
        client: MockClient((_) async => http.Response(messageBody(), 200)),
      );
      await expectLater(service.initialized, completes);
    });

    test('a key set during startup is not clobbered by the load finishing',
        () async {
      // Regression: the load's error path unconditionally set _apiKey = null,
      // so a key set while the constructor's load was still in flight was
      // silently discarded and AI search stayed disabled.
      final service = KnowledgeBaseService(
        client: MockClient((_) async => http.Response(messageBody(), 200)),
      );
      // Deliberately do NOT await initialized first.
      await service.setApiKey('set-during-startup');
      await service.initialized;

      expect(service.hasApiKey, isTrue);
    });

    test('hasApiKey is false before any key is set', () async {
      final service = KnowledgeBaseService(
        client: MockClient((_) async => http.Response(messageBody(), 200)),
      );
      await service.initialized;
      expect(service.hasApiKey, isFalse);
    });
  });

  group('local keyword search', () {
    test('asks for a more specific question when the query has no keywords',
        () async {
      final service = await serviceWith(
        (_) async => http.Response(messageBody(), 200),
      );
      expect(service.searchLocal('a an of'), contains('more specific'));
      expect(service.searchLocal(''), contains('more specific'));
    });

    test('reports no matches against an empty library', () async {
      final service = await serviceWith(
        (_) async => http.Response(messageBody(), 200),
      );
      expect(service.searchLocal('hyzer flip distance'), contains('No matching'));
    });
  });
}

/// Stand-in for a network failure — MockClient handlers cannot easily raise a
/// real SocketException without importing dart:io into a shared test.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection failed';
}
