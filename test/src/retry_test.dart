import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sse_client/sse_client.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {});
  tearDown(() {});

  var _responseStreamOf = (StreamController<List<int>> controller, [int statusCode = 200]) =>
      Future.value(http.StreamedResponse(controller.stream, statusCode, headers: {
        'content-type': statusCode == 200 ? 'text/event-stream' : 'text/html',
      }));

  test('keep retry until connection is successful', () async {
    int retryCount = 0;
    AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () => MockClient.streaming((request, bodyStream) {
        if (retryCount == 3) {
          var controller = StreamController<List<int>>();
          return _responseStreamOf(controller);
        } else {
          var controller = StreamController<List<int>>()..close();
          return _responseStreamOf(controller, 404);
        }
      }),
      onRetry: expectAsync0(() {
        retryCount++;
      }, count: 3),
      onConnected: expectAsync0(() {
        expect(retryCount, 3);
      }),
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: const Duration(milliseconds: 1),
        appendLastIdHeader: false,
      ),
    ).connect();
  });

  test('retry if stream ended prematurely', () async {
    int connectAttempt = 0;
    int retryAttempt = 0;
    Completer<int> completer = Completer<int>();
    AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              connectAttempt++;
              var controller = StreamController<List<int>>();
              if (connectAttempt == 1) {
                Future.delayed(const Duration(milliseconds: 1), () {
                  controller.close(); // close the stream by server
                });
              }
              return _responseStreamOf(controller);
            }),
        onConnected: expectAsync0(() {
          if (retryAttempt == 1) {
            completer.complete(retryAttempt);
          }
        }, count: 2),
        onRetry: expectAsync0(() {
          retryAttempt++;
        }, count: 1),
        onError: expectAsync5((errorType, retryCount, reconnectionTime, error, stacktrace) {
          expect(retryCount, 0);
          expect(errorType, ConnectionError.streamEndedPrematurely);
          return ReconnectStrategy(
            delay: Duration.zero,
            appendLastIdHeader: false,
          );
        })).connect();

    expect(await completer.future, 1);
  });

  test('retry if error emitted', () async {
    int connectAttempt = 0;
    int retryAttempt = 0;
    Completer<int> completer = Completer<int>();
    AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              connectAttempt++;
              var controller = StreamController<List<int>>();

              if (connectAttempt == 1) {
                Future.delayed(const Duration(milliseconds: 1), () {
                  controller.addError(Exception('Something went wrong!')); // emits an error
                });
              }

              return _responseStreamOf(controller);
            }),
        onConnected: expectAsync0(() {
          if (retryAttempt == 1) {
            completer.complete(retryAttempt);
          }
        }, count: 2),
        onRetry: expectAsync0(() {
          retryAttempt++;
        }),
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

  test('should not retry on client disconnection', () async {
    var client = AutoReconnectSseClient(http.Request('GET', Uri.parse('http://example.com/subscribe')),
        httpClientProvider: () => MockClient.streaming((request, bodyStream) {
              var controller = StreamController<List<int>>();
              return _responseStreamOf(controller);
            }),
        onConnected: expectAsync0(() {}),
        onRetry: expectAsync0(() {}, count: 0),
        onError: expectAsync5((errorType, retryCount, reconnectionTime, error, stacktrace) {
          fail('This should not be called');
        }, count: 0))
      ..connect();

    await Future<void>.delayed(const Duration(milliseconds: 1));
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('should not retry if retry more than retry count', () async {
    final completer = Completer<void>();
    var client = AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: () =>
          MockClient.streaming((request, bodyStream) => _responseStreamOf(StreamController<List<int>>()..close())),
      onRetry: expectAsync0(() {}, count: 3),
      onConnected: expectAsync0(() {}, count: 0),
      maxRetries: 3,
      onError: expectAsync5(
          (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
                delay: Duration.zero,
              ),
          count: 3),
    );

    try {
      var stream = await client.connect();
      await for (final _ in stream) {}
    } catch (e) {
      expect(e, isA<Exception>());
      completer.complete();
    }

    await completer.future;
  });

  test('should send last event ID by default', () async {
    final completer = Completer<String>();
    int retryCount = 0;
    AutoReconnectSseClient(
      http.Request('GET', Uri.parse('http://example.com/subscribe')),
      httpClientProvider: expectAsync0(
          () => MockClient.streaming((request, bodyStream) {
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
                return _responseStreamOf(controller);
              }),
          count: 2),
      onRetry: expectAsync0(() {
        retryCount++;
      }),
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
      httpClientProvider: expectAsync0(
          () => MockClient.streaming((request, bodyStream) {
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
                return _responseStreamOf(controller);
              }),
          count: 2),
      onRetry: () {
        retryCount++;
      },
      onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => ReconnectStrategy(
        delay: Duration.zero,
        appendLastIdHeader: false,
      ),
    )..connect();

    expect(await completer.future, false);
  });

  // test('should ack retry interval', () async {});
}
