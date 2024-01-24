import 'package:http/http.dart' as http;
import 'package:sse_client/sse_client.dart';

Future<void> main() async {
  /// EXAMPLE 1: Single connecting client

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

  /// EXAMPLE 2: Auto reconnecting client

  final autoReconnectingClient = AutoReconnectSseClient(
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
    onError: (errorType, retryCount, reconnectionTime, error, stacktrace) => RetryStrategy(
      /// The delay before the next retry. By default it will acknowledge `reconnectionTime` with an exponential backoff.
      delay: Duration(seconds: 5),

      /// Whether to append the `Last-Event-ID` header to the request. Defaults to true.
      appendLastIdHeader: true,
    ),
  );
}
