
class UnexpectedStreamErrorException implements Exception {
  final String message;
  final Object error;
  final StackTrace stackTrace;

  UnexpectedStreamErrorException(this.message, this.error, this.stackTrace);
}

class UnexpectedStreamDoneException implements Exception {
  final String message;

  UnexpectedStreamDoneException(this.message);
}