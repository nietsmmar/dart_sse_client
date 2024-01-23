/// Message event dispatched by the SSE client.
class MessageEvent {
  /// The last event id. It can be an empty string.
  final String id;

  /// The event type. It can be an empty string.
  final String event;

  /// The data. It can be multi-line.
  final String data;

  const MessageEvent({
    required this.id,
    required this.event,
    required this.data,
  });

  @override
  String toString() => 'MessageEvent{id: $id, event: $event, data: $data}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is MessageEvent && other.id == id && other.event == event && other.data == data;
  }

  @override
  int get hashCode => id.hashCode ^ event.hashCode ^ data.hashCode;
}

/// The strategy of retrying the connection.
class RetryStrategy {
  /// The delay before the next retry.
  final Duration delay;

  /// Whether to append the `Last-Event-ID` header to the request.
  final bool appendLastIdHeader;

  const RetryStrategy({
    required this.delay,
    this.appendLastIdHeader = true,
  });
}
