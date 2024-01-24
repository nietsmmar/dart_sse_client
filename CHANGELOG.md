## 3.0.0-dev

* Major rewrite.
* Class name changed to `SseClient`, and the connect and disconnect methods are changed to `connect()` and `close()`
  respectively.
* `SseClient` is now an instance class. You can create multiple instances of `SseClient` to connect to multiple servers.
  User should pass the parameters to the constructor instead of the `connect()` method (`subscribeToSSE()` in previous 
  versions).
* `SseClient` will not construct the HTTP request body anymore. Instead, user needs to pass the `Request` object to the
  constructor. This enables users to, for example, pass a `StreamedRequest` object to the constructor to send a large
  request body when really needed.
* The message event emitted to the user, which is now named `MessageEvent` (previously `SSEModel`), is immutable.
* Fixed issue where the event was not closed properly when connection is closed.
* Fixed issue where the message parsing didn't follow the SSE specification.
* Fixed issue where there was no way to tell if the connection was successful or not.
* Fixed issue where the response content type was not checked properly.
* User can now provider their own instance of `HttpClient`.
* User can specify whether to add the `text/event-stream` content type header to the request.
* User can specify the connection timeout.
* Added a new `AutoReconnectSseClient` class which can be used to automatically reconnect to the server when connection
  fails or closes prematurely by the server.
* Added unit tests.

## 2.0.1

* Updated http version to be compatible with the latest http package.

## 2.0.0

* The request type can now be manually set.
* Ability to pass the request body with the request.
* Safe close of the sink added as well which was causing some minor crashes.
* Stability changes in the model to handle null safety.

## 2.0.0-beta.1

* The request type can now be manually set.
* Ability to pass the request body with the request.
* Safe close of the sink added as well which was causing some minor crashes.

## 1.0.0

* Added ability to send custom headers.
* Added error handling.

## 0.1.0

* Added In-line documentation.

## 0.0.6

* Fixed issue causing stackoverflow while loading large chunk data stream.

## 0.0.5

* Fixed issue causing large responses to be split.
* Improved the way UTF8 Encoder was used.

## 0.0.4

* Updated example code.

## 0.0.3

* Added a example dart file for consuming the event.
* Refactored the code to remove redundancy.

## 0.0.2

* The package is now null safe.
* Unused imports have been removed.