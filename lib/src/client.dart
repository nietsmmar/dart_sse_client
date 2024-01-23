import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'exceptions.dart';
import 'models.dart';

/// Internal buffer for SSE events.
class _EventBuffer {
  final String id;
  final String event;
  final String data;

  _EventBuffer({this.data = '', this.id = '', this.event = ''});

  _EventBuffer copyWith({
    String? id,
    String? event,
    String? data,
  }) =>
      _EventBuffer(
        id: id ?? this.id,
        event: event ?? this.event,
        data: data ?? this.data,
      );

  /// Converts the buffer to a [MessageEvent].
  /// [spec] If the data buffer's last character is a U+000A LINE FEED (LF) character, then remove the last character from the data buffer.
  MessageEvent toMessageEvent() => MessageEvent(
        id: id,
        event: event,
        data: data.endsWith('\n') ? data.substring(0, data.length - 1) : data,
      );
}

enum ConnectionState { connected, connecting, disconnected }

final _numericRegex = RegExp(r'^\d+$');

/// A client for connecting to a Server-Sent Events endpoint.
class SseClient {
  final Logger _logger;
  final String name;

  /// A function that returns an [http.Client] instance. This is useful for testing and when you need to customize the
  /// client. If not specified, a default [http.Client] instance will be used.
  final http.Client Function()? httpClientProvider;

  /// The request to be sent to the server. The request must not be finalized.
  /// When a connection is initialized the request will be used as a base and copied to a new one, with the `Accept`
  /// header set to `text/event-stream` if [setContentTypeHeader] is `true`. This class will not modify other
  /// header parameters.
  final http.BaseRequest _request;

  /// Whether to set the `Accept` header to `text/event-stream` automatically.
  /// The original `Accept` header (if defined) will be overwritten when this is set to `true`.
  /// Defaults to `true`.
  final bool setContentTypeHeader;

  /// The splitter for the request body.
  late final StreamSplitter<List<int>> _splitter;

  /// The timeout for the connection. Defaults to 15 seconds.
  final Duration? timeout;

  /// A callback that will be called when the connection is established.
  final Function? onConnected;

  /// The current connection state.
  ConnectionState _state = ConnectionState.disconnected;

  ConnectionState get state => _state;

  SseClient(this._request,
      {this.httpClientProvider,
      this.name = 'SseClient',
      this.timeout = _defaultTimeout,
      this.onConnected,
      this.setContentTypeHeader = true})
      : _logger = Logger(name),
        assert(!_request.finalized) {
    _splitter = StreamSplitter(_request.finalize());
  }

  http.Client? _client;

  StreamController<MessageEvent>? _streamController;

  /// The last event id. It can be an empty string.
  /// Will be null if no event has been received.
  String? _lastEventId;

  /// Public getter for [_lastEventId].
  String? get lastEventId => _lastEventId;

  /// The reconnection time in milliseconds.
  /// Will be null if no reconnection time has been received.
  int? _reconnectionTime;

  /// Public getter for [_reconnectionTime].
  int? get reconnectionTime => _reconnectionTime;

  /// Code adapted from https://github.com/dart-archive/http_retry/blob/master/lib/http_retry.dart
  /// Returns a copy of the base request.
  http.StreamedRequest _copyRequest() {
    Stream<List<int>> body = _splitter.split();

    final request = http.StreamedRequest(_request.method, _request.url)
      ..contentLength = _request.contentLength
      ..followRedirects = _request.followRedirects
      ..headers.addAll(_request.headers)
      ..headers.addAll(setContentTypeHeader ? {'Accept': 'text/event-stream'} : {})
      ..maxRedirects = _request.maxRedirects
      ..persistentConnection = _request.persistentConnection;

    body.listen(request.sink.add, onError: request.sink.addError, onDone: request.sink.close, cancelOnError: true);

    return request;
  }

  /// Connects to the server and returns a stream of [MessageEvent]s.
  /// The method will throw an exception if the connection fails.
  /// You cannot call this method if the client is already connected or connecting, or an exception will be thrown.
  Future<Stream<MessageEvent>> connect() async {
    if (_state != ConnectionState.disconnected) {
      throw Exception('Already connected or connecting to SSE');
    }

    _logger.finest('Start subscribing to SSE: ${_request.url}');
    var streamController = StreamController<MessageEvent>();

    _state = ConnectionState.connecting;
    _client = httpClientProvider?.call() ?? http.Client();

    http.StreamedResponse? response;

    try {
      var future = _client!.send(_copyRequest());
      if (timeout != null) {
        future = future.timeout(timeout!);
      }

      response = await future;

      /// [spec] if res's status is not 200, or if res's `Content-Type` is not `text/event-stream`, then fail the connection.
      if (response.statusCode != 200) {
        throw Exception('Failed subscribing to SSE - invalid response code ${response.statusCode}');
      }

      if (!response.headers.containsKey('content-type') ||
          (response.headers['content-type']!.split(';')[0] != 'text/event-stream')) {
        throw Exception('Failed subscribing to SSE - unexpected Content-Type ${response.headers['content-type']}');
      }
    } catch (error) {
      _logger.severe('SSE request response error: $error');
      rethrow;
    }

    if (_state != ConnectionState.connecting) {
      // This can happen if disconnect() is called while waiting for the response
      throw Exception(
          'Failed subscribing to SSE - connection is fine but client\'s connection state is not "connecting"');
    }

    _state = ConnectionState.connected;

    /// "[spec]" refers to https://html.spec.whatwg.org/multipage/server-sent-events.html
    _EventBuffer? eventBuffer;
    try {
      response.stream.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((dataLine) {
        if (dataLine.isEmpty) {
          /// [spec] If the line is empty (a blank line), Dispatch the event.
          if (streamController.isClosed) {
            return;
          }

          if (eventBuffer == null) {
            return;
          }

          _lastEventId = eventBuffer!.id;
          streamController.sink.add(eventBuffer!.toMessageEvent());
          eventBuffer = _EventBuffer();
          return;
        }

        if (dataLine.startsWith(':')) {
          /// [spec] If the line starts with a U+003A COLON character (:), ignore the line.
          return;
        }

        String? fieldName;
        String? fieldValue;

        if (dataLine.contains(':')) {
          /// [spec] If the line contains a U+003A COLON character (:)
          /// 1. Collect the characters on the line before the first U+003A COLON character (:), and let field be that string.
          /// 2. Collect the characters on the line after the first U+003A COLON character (:), and let value be that string.
          ///    If value starts with a single U+0020 SPACE character, remove it from value.
          var pos = dataLine.indexOf(':');
          fieldName = dataLine.substring(0, pos);
          fieldValue = dataLine.substring(pos + 1);
          if (fieldValue.startsWith(' ')) {
            fieldValue = fieldValue.substring(1);
          }
        } else {
          /// [spec] Otherwise, the string is not empty but does not contain a U+003A COLON character (:):
          /// Use the whole line as the field name, and the empty string as the field value.
          fieldName = dataLine;
          fieldValue = '';
        }

        eventBuffer ??= _EventBuffer();

        switch (fieldName) {
          /// [spec] Set the event type buffer to field value.
          case 'event':
            eventBuffer = eventBuffer!.copyWith(
              event: fieldValue,
            );

          /// [spec] Append the field value to the data buffer, then append a single U+000A LINE FEED (LF) character to the data buffer.
          case 'data':
            eventBuffer = eventBuffer!.copyWith(
              data: '${eventBuffer!.data}$fieldValue\n',
            );

          /// [spec] If the field value does not contain U+0000 NULL, then set the last event ID buffer to the field value. Otherwise, ignore the field.
          case 'id':
            if (!fieldValue.contains('\u0000')) {
              eventBuffer = eventBuffer!.copyWith(
                id: fieldValue,
              );
            }
          case 'retry':

            /// [spec] If the field value consists of only ASCII digits, then interpret the field value as an integer in base ten,
            /// and set the event stream's reconnection time to that integer. Otherwise, ignore the field.
            if (_numericRegex.hasMatch(fieldValue)) {
              _reconnectionTime = int.parse(fieldValue);
            }
        }
      })
        ..onDone(() {
          if (streamController.isClosed) {
            return;
          }
          _logger.severe('ERROR: server closed the connection.');
          streamController.close();
        })
        ..onError((Object e, StackTrace? s) {
          if (streamController.isClosed) {
            return;
          }
          _logger.severe('ERROR: $e');
          streamController.addError(e, s);
        });
    } catch (error) {
      _logger.severe('SSE Stream error: $error');
      rethrow;
    }

    onConnected?.call();
    _streamController = streamController;
    return streamController.stream;
  }

  /// Closes the connection.
  /// This will close the stream returned by [connect].
  /// Calling this method when the client is not connected will have no effect.
  void close() {
    _state = ConnectionState.disconnected;
    _streamController?.close();
    _streamController = null;
    _client?.close();
    _client = null;
  }
}

enum ConnectionError {
  /// Indicates that the server closed the connection prematurely.
  streamEndedPrematurely,

  /// Indicates that the connection had failed.
  connectionFailed,

  /// Indicates that an error was emitted from the stream.
  errorEmitted
}

/// A callback which expects to return a [RetryStrategy].
/// If the callback returns null, the client will not retry reconnecting to the server, and the error will be
/// emitted to the outer stream.
typedef ReconnectStrategyCallback = RetryStrategy? Function(

    /// The type of the connection error. See [ConnectionError].
    ConnectionError errorType,

    /// The number of times the connection has been retried (excluding the current attempt).
    /// Starts from 0.
    int retryCount,

    /// The reconnection time specified by the server, if any.
    int? reconnectionTime,

    /// The error object.
    Object error,

    /// The stack trace of the error.
    StackTrace stacktrace);

/// A client that will automatically reconnect to the server when the connection is lost.
/// This is separated from [SseClient] because of the different behavior or the [connect] method.
/// See [connect] for more information.
class AutoReconnectSseClient extends SseClient {
  /// The number of times a reconnection should be tried.
  final int _maxRetries;

  /// The callback to determine the retry strategy.
  final ReconnectStrategyCallback _onError;

  final void Function()? _onRetry;
  StreamController<MessageEvent>? _outerStreamController;

  /// The last retry strategy.
  RetryStrategy? _lastRetryStrategy;

  AutoReconnectSseClient(
    super._request, {
    super.httpClientProvider,
    super.name,
    super.timeout = _defaultTimeout,
    super.onConnected,
    super.setContentTypeHeader = true,

    /// The number of times a request should be retried. Setting to -1 (or any negative value) will retry indefinitely,
    /// which is the default.
    int maxRetries = -1,

    /// The callback to determine the retry strategy. See [ReconnectStrategyCallback].
    required ReconnectStrategyCallback onError,
    void Function()? onRetry,
  })  : _maxRetries = maxRetries,
        _onRetry = onRetry,
        _onError = onError;

  /// A factory method to create an [AutoReconnectSseClient] instance with the default retry strategy.
  ///
  /// The constructor parameters in this factory method are the same as [SseClient], so it can be seen as a drop-in
  /// replacement of [SseClient] constructor, with added reconnection functionality. The "default" behavior are as
  /// follows:
  /// 1. It will try to reconnect for unlimited time, when a connection error or a stream error is emitted, or when the
  ///    server closes the connection prematurely.
  /// 2. It will append the `Last-Event-ID` header to the request if it is not null.
  /// 3. It will acknowledge the retry duration specified by the SSE server if any, with a default of 500 milliseconds.
  /// 4. It will retry with exponential backoff.
  ///
  /// You should still be aware of the difference on [connect] method's behavior.
  ///
  /// Constructor the [AutoReconnectSseClient] instance manually if you need more control over the retry strategy and
  /// the number of retries.
  AutoReconnectSseClient.defaultStrategy(super._request,
      {super.httpClientProvider,
      super.name,
      super.timeout = _defaultTimeout,
      super.onConnected,
      super.setContentTypeHeader = true,
      int maxRetries = -1,
      void Function()? onRetry})
      : _maxRetries = maxRetries,
        _onError = _defaultStrategyCallback,
        _onRetry = onRetry;

  @override
  http.StreamedRequest _copyRequest() {
    var copiedRequest = super._copyRequest();
    if ((_lastRetryStrategy?.appendLastIdHeader ?? false) && lastEventId != null) {
      copiedRequest.headers['Last-Event-ID'] = lastEventId!;
    }
    return copiedRequest;
  }

  @override
  void close() {
    print('Disconnecting');
    _outerStreamController?.close();
    super.close();
  }

  /// Connects to the server and returns a stream of [MessageEvent]s.
  ///
  /// Besides the auto-reconnect capability, the main difference between this method and [SseClient.connect] is that
  /// this method will hold an "outer event stream" object that will always be returned to the user before attempting
  /// a connection. Thus, user cannot determine if the connection is successful by just awaiting for the stream.
  /// Instead, do it with the [onConnected] callback.
  @override
  Future<Stream<MessageEvent>> connect() async {
    if (_state != ConnectionState.disconnected) {
      throw Exception('Already connected or connecting to SSE');
    }

    _outerStreamController = StreamController<MessageEvent>();
    _doConnect(0);
    return _outerStreamController!.stream;
  }

  Future<void> _doConnect(int retryCount) async {
    bool didConnect = false;
    try {
      // Start connection to the server.
      var innerStream = await super.connect();
      didConnect = true;

      // Propagate the events to the outer stream.
      await for (final event in innerStream) {
        if (_outerStreamController == null || _outerStreamController!.isClosed) {
          return;
        }
        _outerStreamController!.add(event);
      }

      // The inner stream is closed. This means that the server has closed the connection.
      if (_outerStreamController == null || _outerStreamController!.isClosed) {
        // No need to retry if the outer stream is closed.
        return;
      }

      // Otherwise, the server has closed the connection prematurely.
      throw UnexpectedStreamDoneException('The server event stream is closed.');
    } catch (error, stackTrace) {
      if (_outerStreamController == null || _outerStreamController!.isClosed) {
        return;
      }

      // Define the callback to get the retry strategy and set it to the [_lastRetryStrategy] variable, so that
      // _onError() won't be called if the retry count has reached the limit.
      RetryStrategy? getLastRetryStrategy() => _lastRetryStrategy = _onError(
          didConnect
              ? (error is UnexpectedStreamDoneException
                  ? ConnectionError.streamEndedPrematurely
                  : ConnectionError.errorEmitted)
              : ConnectionError.connectionFailed,
          retryCount,
          reconnectionTime,
          error,
          stackTrace);

      // Ask the callback for the retry strategy.
      if (retryCount == _maxRetries || getLastRetryStrategy() == null) {
        // We've reached the retry limit, or the callback returned null.
        // Emit an error to the outer stream and close it.
        _outerStreamController!.addError(error, stackTrace);
        close();
      } else {
        // Retry with the strategy returned by the callback.
        super.close();
        await Future<void>.delayed(_lastRetryStrategy!.delay);
        _onRetry?.call();
        _doConnect(retryCount + 1);
      }
    }
  }
}

const _defaultTimeout = const Duration(seconds: 15);

final _defaultStrategyCallback =
    (ConnectionError errorType, int retryCount, int? reconnectionTime, Object obj, StackTrace stack) => RetryStrategy(
          delay: Duration(milliseconds: reconnectionTime ?? 500) * math.pow(1.5, math.min(10, retryCount)),
          appendLastIdHeader: true,
        );
