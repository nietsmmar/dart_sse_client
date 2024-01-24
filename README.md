# A note from the fork author

This is a fork of the original [flutter_client_sse](https://github.com/pratikbaid3/flutter_client_sse) package. I made
some big changes, fixed some issues and added some features, and is waiting for the original author's response about my
changes. In the meantime, if you want to try this package, you can add the following import to the `pubspec.yaml` file:

```yaml
dart_sse_client:
  git:
    url: https://github.com/tamcy/dart_sse_client/
    ref: tamcy-dev
```

# SSE Client (Dart)

`dart_sse_client` is a Dart package that helps you to connect to a server using Server-Sent Events (SSE). SSE is a protocol
that enables the server to push data to the client over a persistent HTTP connection. This package will parse the
event stream and provide a parsed representation of the event, id and data fields.

## Getting Started

### Installation

To use this package, add the following import to the `pubspec.yaml` file:

```yaml
client_sse:
  git:
    url: https://github.com/pratikbaid3/flutter_client_sse
    path:
```

### Usage

#### Single connecting client

```dart
import 'package:http/http.dart' as http;
import 'package:sse_client/sse_client.dart';

Future<void> main() async {
  /// Create the client.
  final client = SseClient(

    /// Must supply a [Request] object. You can add all necessary headers here.
    http.Request('GET', Uri.parse('http://example.com/subscribe'))
      ..headers.addAll({
        'Authorization': 'Bearer (token)',
        'Cache-Control': 'no-cache',
      }),

    /// You can supply a custom [http.HttpClient] provider. Useful if you want to use a custom [HttpClient] implementation.
    /// If not supplied, the default [http.HttpClient] will be used.
    httpClientProvider: () => http.Client(),

    /// Connection timeout. The default is 15 seconds.
    timeout: Duration(seconds: 15),

    /// Called when the connection is established.
    onConnected: () {
      print('Connected');
    },

    /// Whether the class should add the "text/event-stream" content type header to the request. The default is `true`.
    setContentTypeHeader: true,
  );

  /// Now you can connect to the server.
  try {
    /// Connects to the server. Here we are using the `await` keyword to wait for the connection to be established.
    /// If the connection fails, an exception will be thrown.
    var stream = await client.connect();

    /// Connection is successful, now listen to the stream.
    /// Connection will be closed when onError() or onDone() is called.
    stream.listen((event) {
      print('Id: ${event.id}');
      print('Event: ${event.event}');
      print('Data: ${event.data}');
    })
      ..onError((Object error) {
        print('Error: $error');
      })
      ..onDone(() {
        /// This will not be called when the connection is closed by the client via [client.close()].
        /// So, [onDone()] means the connection is closed by the server, which is usually not normal,
        /// and a reconnection is probably needed.
        print('Disconnected by the server');
      });
  } catch (e) {
    print('Connection Error: $e');
  }

  /// Closes the connection manually.
  client.close();
}
```

With `SseClient`, you have full control over how to handle connection failures. When you call `connect()`, it returns
a `Future` that completes with an error if the connection fails. Once connected, you can use the `onError()` and
`onDone()` callbacks to handle any errors or disconnections that occur.

#### Auto reconnecting client

If you want to automatically reconnect to the server when the connection is lost or closed by the server, you can use
the `AutoReconnectSseClient` class. This class provides a default reconnection strategy that you can use by calling the
`AutoReconnectSseClient.defaultStrategy` factory constructor. The parameters of this constructor are the same as
`SseClient`, so you can easily switch from one to the other (note that the behavior of `connect()` is different,
see below).

Alternatively, you can customize the reconnection strategy by using the `AutoReconnectSseClient` class directly. For
example, you can specify the maximum number of retries, the delay between retries, or the conditions for retrying.

```dart

final client = AutoReconnectSseClient(

  /// Same as SseClient, see above.  
  http.Request('GET', Uri.parse('http://example.com/subscribe'))
    ..headers.addAll({
      'Authorization': 'Bearer (token)',
      'Cache-Control': 'no-cache',
    }),
  httpClientProvider: () => http.Client(),
  timeout: Duration(seconds: 10),
  onConnected: () {
    print('Connected');
  },
  setContentTypeHeader: true,

  /// Maximum number of retries before giving up. The default is -1, which means infinite retries.
  /// The number of retry won't accumulate, it will reset every time a connection is successfully established.
  /// If the maximum number of retries is reached, the stream will close with an error. 
  maxRetries: -1,

  /// Called when an error occurred and a reconnection is about to be made.
  /// The callback won't be called if the maximum number of retries is reached.
  /// If this callback returns `null`, no retry will be made, and the error will be propagated to the stream.
  /// Check the source code's `ReconnectStrategyCallback` typedef for details of the callback parameters.
  onError: (errorType, retryCount, reconnectionTime, error, stacktrace) =>
      RetryStrategy(

        /// The delay before the next retry. By default it will acknowledge `reconnectionTime` with an exponential backoff.  
        delay: Duration(seconds: 5),

        /// Whether to append the "Last ID"
        appendLastIdHeader: true,
      ),
);
```

#### Notes

Note that when using `AutoReconnectSseClient`, you should not rely on `await`-ing the `connect()` method and catching
errors thrown by it to see when the connection is successfully established, as it returns a stream immediately. Instead,
use the `onConnected` callback, which is called every time a connection is made.

Also, note that `AutoReconnectSseClient` will consume all “errors” and “done” events from the underlying connection(s)
when a reconnection is attempted, so the `onError()` and `onDone()` callbacks of the outer stream may not reflect the
actual connection status, unless the reconnection fails permanently (i.e. the maximum number of retry is reached of
`onError` returns a `null`) and the error is propagated to the outer stream.