import 'dart:async';

import 'net_core.dart';
import 'net_web.dart';

/// Connects a [NetClient] using a caller-provided [BrowserWebSocket] factory on
/// platforms without `dart:io` (such as web browsers).
Future<NetClient> connectNetClient(
  String url, {
  Duration timeout = const Duration(seconds: 10),
  BrowserWebSocket Function(String url)? socketFactory,
}) async {
  if (socketFactory == null) {
    throw UnsupportedError(
      'On web, pass socketFactory wrapping browser WebSocket to connectNetClient.',
    );
  }
  final ws = socketFactory(url);
  final transport = WebNetTransport(ws);
  final client = NetClient(transport);
  if (!client.connected) {
    final c = Completer<void>();
    client.onConnect = () {
      if (!c.isCompleted) c.complete();
    };
    await c.future.timeout(timeout);
  }
  return client;
}
