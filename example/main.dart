import 'package:http/http.dart' as http;
import 'package:sse_client/sse_client.dart';

Future<void> main() async {
  // Create an SSE client.
  var sseClient = SseClient(
    http.Request('GET', Uri.parse('http://192.168.1.2:3000/api/activity-stream?historySnapshot=FIVE_MINUTE'))
      ..headers.addAll({
        'Cookie':
            'jwt=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6InRlc3QiLCJpYXQiOjE2NDMyMTAyMzEsImV4cCI6MTY0MzgxNTAzMX0.U0aCAM2fKE1OVnGFbgAU_UVBvNwOMMquvPY8QaLD138; Path=/; Expires=Wed, 02 Feb 2022 15:17:11 GMT; HttpOnly; SameSite=Strict',
        'Cache-Control': 'no-cache',
      }),
  );

  try {
    // Connect to the server. If the connection fails, an exception will be thrown.
    var stream = await sseClient.connect();

    // Connection successful; now listen to the stream.
    stream.listen((event) {
      print('Id: ' + event.id);
      print('Event: ' + event.event);
      print('Data: ' + event.data);
    })
      ..onError(
        (Object error) {
          print('Error: $error');
        },
      )
      ..onDone(() {
        print('Disconnected by the server');
      });
  } catch (e) {
    print('Connection Error: $e');
  }

  // Use `sseClient.close()` to close the connection.
  sseClient.close();
}
