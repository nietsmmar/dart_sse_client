# SSE Client (Dart)

SSE Client is a Dart package that enables you to receive updates from a server using Server Sent Events. It helps you
connect to a server that streams events using the text/event-stream MIME type, and provides a parsed representation of
the event, id and the data fields.


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

```dart
import 'package:http/http.dart' as http;

/// Create the client.
final client = SseClient(
  /// Must supply a [Request] object. You can add all necessary headers here.  
  http.Request('GET', Uri.parse('http://192.168.1.2:3000/api/activity-stream?historySnapshot=FIVE_MINUTE'))
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
      print('Id: ' + event.id);
      print('Event: ' + event.event);
      print('Data: ' + event.data);
    })..onError((Object error) {
      print('Error: $error');
    })..onDone(() {
      print('Disconnected by the server');
    });
} catch (e) {
  print('Connection Error: $e');
}

/// Closes the connection manually.
sseClient.close();
```

When using `SseClient`, developers are in full control on how to handle the connection failures. When `connect()` is
called it returns a `Future`. The code will complete with an error when connection fails. After connecting to the server,
you can use the `onError()` and `onDone()` callbacks to handle errors and disconnections.

Alternately, you can use the `AutoReconnectSseClient` class to automatically reconnect to the server when connection
fails or closes prematurely by the server. This class uses an exponential backoff algorithm to reconnect to the server.
There is a `AutoReconnectSseClient.defaultStrategy` which can be used to create a client with default settings. The
constructor parameters are just the same as `SseClient`, so you can just replace `SseClient` with
`AutoReconnectSseClient.defaultStrategy` in the above example to use this class.

Do note that when using `AutoReconnectSseClient`, you must NOT rely on `await`-ing the `connect()` method to know when
the connection is established, as the `connect()` method in `AutoReconnectSseClient` will return a stream immediately.
Instead, you should use the `onConnected` callback, which is called every time a connection is established. Also,
`AutoReconnectSseClient` will consume all errors and disconnections, so `onError()` and `onDone()` of the stream may
not reflect what is happening with the actual connection (unless when e.g. the maximum retry number is reached and the
error is propagated to the stream).

More fine-grained control can be achieved by using the `AutoReconnectSseClient` class directly:

```dart
final client = AutoReconnectSseClient(
  /// Same as SseClient, see above.  
  http.Request('GET', Uri.parse('http://192.168.1.2:3000/api/activity-stream?historySnapshot=FIVE_MINUTE'))
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
  onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => RetryStrategy(
      /// The delay before the next retry. By default it will acknowledge `reconnectionTime` with an exponential backoff.  
      delay: Duration(seconds: 5),

      /// Whether to append the "Last ID"
      appendLastIdHeader: true,
  ),
);
```
