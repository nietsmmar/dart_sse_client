import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dart_sse_client/sse_client.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {});
  tearDown(() {});

  test('basic successful connection', () async {
    var client = SseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient((request) {
        if (request.url.path == '/subscribe') {
          return Future.value(http.Response('{"status": "ok"}', 200, headers: {
            'content-type': 'text/event-stream',
          }));
        }
        return Future.value(http.Response('Not found', 400));
      }),
    );

    expect(client.connect(), completion(isA<Stream<MessageEvent>>()));
  });

  test('exception should throw on unexpected content type', () async {
    var client = SseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient((request) {
        if (request.url.path == '/subscribe') {
          return Future.value(http.Response('{"status": "ok"}', 200, headers: {
            'content-type': 'text/plain',
          }));
        }
        return Future.value(http.Response('Not found', 400));
      }),
    );

    expect(client.connect(), throwsA(isA<Exception>()));
  });

  test('connect more than once', () async {
    var client = SseClient(http.Request('POST', Uri.parse('http://example.com/subscribe'))..body = 'Hello World',
        httpClientProvider: () => MockClient((request) {
              // validate the request body is correct
              expect(request.body, 'Hello World');

              return Future.value(http.Response('{"status": "ok"}', 200, headers: {
                'content-type': 'text/event-stream',
              }));
            }),
        onConnected: expectAsync0(() {}, count: 2));

    await client.connect();
    client.close();

    await client.connect();
  });

  test('cannot run connect again when connection is active', () async {
    var client = SseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient(
        (request) => Future.value(http.Response('{"status": "ok"}', 200, headers: {
          'content-type': 'text/event-stream',
        })),
      ),
    );

    expect(await client.connect(), isA<Stream<MessageEvent>>());
    await expectLater(client.connect(), throwsA(isA<Exception>()));
  });

  test('should emit received event', () async {
    var client = SseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        var controller = StreamController<List<int>>();

        Future.delayed(const Duration(seconds: 1), () {
          controller
            ..add('event: test\n'.codeUnits)
            ..add('data: {"success": 200}\n'.codeUnits)
            ..add('id: 3457\n'.codeUnits)
            ..add('\n'.codeUnits);
        });
        return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
          'content-type': 'text/event-stream',
        }));
      }),
    );

    expect(await client.connect(), emits(const MessageEvent(event: 'test', data: '{"success": 200}', id: '3457')));
  });

  // Testing message event parsing behavior as per https://html.spec.whatwg.org/multipage/server-sent-events.html .
  test('spec example 1', () async {
    var items = await _executeSseConnection(
      onSendData: (sink) {
        sink
          ..add('data: YHOO\n'.codeUnits)
          ..add('data: +2\n'.codeUnits)
          ..add('data: 10\n'.codeUnits)
          ..add('\n'.codeUnits);
        return false;
      },
      expectedCount: 1,
    );

    expect(items[0], const MessageEvent(event: '', data: 'YHOO\n+2\n10', id: ''));
  });

  test('spec example 2', () async {
    var items = await _executeSseConnection(
      onSendData: (sink) {
        sink
          // Item 1 - not an event
          ..add(': test stream\n'.codeUnits)
          ..add('\n'.codeUnits)
          // Item 2
          ..add('data: first event\n'.codeUnits)
          ..add('id: 1\n'.codeUnits)
          ..add('\n'.codeUnits)
          // Item3
          ..add('data:second event\n'.codeUnits)
          ..add('id\n'.codeUnits)
          ..add('\n'.codeUnits)
          // Item 4
          ..add('data:  third event\n'.codeUnits)
          ..add('\n'.codeUnits);
        return true; // Disconnect after sending the third event
      },
    );
    expect(items.length, 3);
    expect(items[0], const MessageEvent(event: '', data: 'first event', id: '1'));
    expect(items[1], const MessageEvent(event: '', data: 'second event', id: ''));
    expect(items[2], const MessageEvent(event: '', data: ' third event', id: ''));
  });

  test('spec example 3', () async {
    var items = await _executeSseConnection(
      onSendData: (sink) {
        sink
          ..add('data\n'.codeUnits)
          ..add('\n'.codeUnits)
          ..add('data\n'.codeUnits)
          ..add('data\n'.codeUnits)
          ..add('\n'.codeUnits)
          ..add('data:\n'.codeUnits);
        return true; // Disconnect after sending the third event
      },
    );
    expect(items.length, 2);
    expect(items[0], const MessageEvent(event: '', data: '', id: ''));
    expect(items[1], const MessageEvent(event: '', data: '\n', id: ''));
  });

  test('spec example 4', () async {
    var items = await _executeSseConnection(
      onSendData: (sink) {
        sink
          ..add('data:test\n'.codeUnits)
          ..add('\n'.codeUnits)
          ..add('data: test\n'.codeUnits)
          ..add('\n'.codeUnits);
        return true; // Disconnect after sending the third event
      },
    );
    expect(items.length, 2);
    expect(items[0], const MessageEvent(event: '', data: 'test', id: ''));
    expect(items[1], const MessageEvent(event: '', data: 'test', id: ''));
  });

  // utf-8 character test
  test('utf8 test', () async {
    var items = await _executeSseConnection(
      onSendData: (sink) {
        sink
          ..add(utf8.encode('data: 搭𨋢😃\n'))
          ..add('\n'.codeUnits);
        return false;
      },
      expectedCount: 1,
    ).timeout(const Duration(seconds: 5));

    expect(items[0], const MessageEvent(event: '', data: '搭𨋢😃', id: ''));
  });
}

Future<List<MessageEvent>> _executeSseConnection({
  required bool Function(EventSink<List<int>> sink) onSendData,
  int? expectedCount,
}) async {
  List<MessageEvent> events = [];
  var client = SseClient(
    http.Request('GET', Uri.parse('http://example.com/subscribe')),
    httpClientProvider: () => MockClient.streaming((request, bodyStream) {
      var controller = StreamController<List<int>>();

      Future.delayed(const Duration(seconds: 1), () {
        var shouldDisconnect = onSendData(controller.sink);
        if (shouldDisconnect) {
          controller.close();
        }
      });
      return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
        'content-type': 'text/event-stream',
      }));
    }),
  );

  var stream = await client.connect();
  var completer = Completer<List<MessageEvent>>();
  stream.listen((event) {
    events.add(event);
    // If expectedCount is set, complete the future when we reach the expected count.
    // Otherwise complete the future when the stream is closed.
    if (events.length == expectedCount) {
      completer.complete(events);
      client.close();
    }
  }).onDone(() {
    if (!completer.isCompleted) {
      completer.complete(events);
    }
  });

  return completer.future;
}
