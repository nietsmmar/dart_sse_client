import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sse_client/sse_client.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {});
  tearDown(() {});

  test('retry until connection successful', () async {
    int retryCount = 0;
    Completer<int> completer = Completer<int>();
    AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        if (request.url.path == '/subscribe' && retryCount == 3) {
          var controller = StreamController<List<int>>();
          return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
            'content-type': 'text/event-stream',
          }));
        } else {
          var controller = StreamController<List<int>>()..close();
          return Future.value(http.StreamedResponse(controller.stream, 404, headers: {
            'content-type': 'text/html',
          }));
        }
      }),
      onRetry: () {
        retryCount++;
      },
      onConnected: () {
        expect(retryCount, 3);
        completer.complete(retryCount);
      },
      retries: 10,
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: const Duration(milliseconds: 1),
        appendLastIdHeader: false,
      ),
    ).connect();

    expect(await completer.future.timeout(Duration(seconds: 5)), 3);
  });

  test('retry if stream ended prematurely', () async {
    int connectAttempt = 0;
    int retryAttempt = 0;
    Completer<int> completer = Completer<int>();
    AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              print('Connect attempt received');
              connectAttempt++;
              var controller = StreamController<List<int>>();

              if (connectAttempt == 1) {
                Future.delayed(const Duration(milliseconds: 200), () {
                  controller.close();
                });
              }

              return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
                'content-type': 'text/event-stream',
              }));
            }),
        onConnected: () {
          if (retryAttempt == 1) {
            completer.complete(retryAttempt);
          }
        },
        onRetry: () {
          retryAttempt++;
        },
        retries: 10,
        onError: (errorType, retryCount, reconnectionTime, error, stacktrace) {
          expect(retryCount, 0);
          expect(errorType, ConnectionError.streamEndedPrematurely);
          return ReconnectStrategy(
            delay: const Duration(milliseconds: 1),
            appendLastIdHeader: false,
          );
        }).connect();

    expect(await completer.future.timeout(Duration(seconds: 5)), 1);
  });

  test('retry if error emitted', () async {
    int connectAttempt = 0;
    int retryAttempt = 0;
    Completer<int> completer = Completer<int>();
    AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              print('Connect attempt received');
              connectAttempt++;
              var controller = StreamController<List<int>>();

              if (connectAttempt == 1) {
                Future.delayed(const Duration(milliseconds: 200), () {
                  controller.addError(Exception('Something went wrong!'));
                });
              }

              return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
                'content-type': 'text/event-stream',
              }));
            }),
        onConnected: () {
          if (retryAttempt == 1) {
            completer.complete(retryAttempt);
          }
        },
        onRetry: () {
          retryAttempt++;
        },
        retries: 10,
        onError: (errorType, retryCount, reconnectionTime, error, stacktrace) {
          expect(retryCount, 0);
          expect(errorType, ConnectionError.errorEmitted);
          return ReconnectStrategy(
            delay: const Duration(milliseconds: 1),
            appendLastIdHeader: false,
          );
        }).connect();

    expect(await completer.future, 1);
  });

  test('should not retry if proactively disconnected', () async {
    int connectAttempt = 0;
    int retryAttempt = 0;
    var client = AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              var controller = StreamController<List<int>>();
              return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
                'content-type': 'text/event-stream',
              }));
            }),
        onConnected: () {
          connectAttempt++;
        },
        onRetry: () {
          retryAttempt++;
        },
        retries: 10,
        onError: (errorType, retryCount, reconnectionTime, error, stacktrace) {
          fail('This should not be called');
        })
      ..connect();

    await Future<void>.delayed(const Duration(milliseconds: 10));
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(connectAttempt, 1);
    expect(retryAttempt, 0);
  });

  test('should not retry if retry more than retry count', () async {
    final completer = Completer<void>();
    int retryCount = 0;
    var client = AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        var controller = StreamController<List<int>>()..close();
        return Future.value(http.StreamedResponse(controller.stream, 404, headers: {
          'content-type': 'text/html',
        }));
      }),
      onRetry: () {
        retryCount++;
      },
      onConnected: () {
        fail('This should not be called');
      },
      retries: 3,
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: Duration.zero,
      ),
    );

    try {
      var stream = await client.connect();
      await for (final _ in stream) {}
    } catch (e) {
      expect(e, isA<Exception>());
      completer.complete();
    }

    await completer.future;
    expect(retryCount, 3);
  });

  test('should send last event ID by default', () async {
    final completer = Completer<String>();
    int retryCount = 0;
    AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        var controller = StreamController<List<int>>();
        if (retryCount == 1) {
          completer.complete(request.headers['last-event-id']);
        }

        if (retryCount == 0) {
          Future.delayed(const Duration(milliseconds: 1), () {
            controller
              ..add('event: test\n'.codeUnits)
              ..add('data: {"success": 200}\n'.codeUnits)
              ..add('id: b3457a\n'.codeUnits)
              ..add('\n'.codeUnits);
          });

          Future.delayed(const Duration(milliseconds: 2), () {
            controller.close();
          });
        }
        return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
          'content-type': 'text/event-stream',
        }));
      }),
      onRetry: () {
        retryCount++;
      },
      retries: 3,
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: Duration.zero,
      ),
    )..connect();

    expect(await completer.future, 'b3457a');
  });

  test('should not send last event ID if told not to', () async {
    final completer = Completer<bool>();
    int retryCount = 0;
    AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        var controller = StreamController<List<int>>();
        if (retryCount == 1) {
          completer.complete(request.headers.containsKey('last-event-id'));
        }

        if (retryCount == 0) {
          Future.delayed(const Duration(milliseconds: 1), () {
            controller
              ..add('event: test\n'.codeUnits)
              ..add('data: {"success": 200}\n'.codeUnits)
              ..add('id: b3457a\n'.codeUnits)
              ..add('\n'.codeUnits);
          });

          Future.delayed(const Duration(milliseconds: 2), () {
            controller.close();
          });
        }
        return Future.value(http.StreamedResponse(controller.stream, 200, headers: {
          'content-type': 'text/event-stream',
        }));
      }),
      onRetry: () {
        retryCount++;
      },
      retries: 3,
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: Duration.zero,
        appendLastIdHeader: false,
      ),
    )..connect();

    expect(await completer.future, false);
  });

  // test('should ack retry interval', () async {});
}
