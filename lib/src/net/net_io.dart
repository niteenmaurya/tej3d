/// Real network for the networking core: WebSocket transport on top of `dart:io`.
///
/// This file needs `dart:io`, so it is NOT exported by `flutter_tej3d.dart` (that library must work
/// on the web). Import it with `package:tej3d/net_io.dart`. Phones, desktop and servers work.
/// A web browser needs another transport (`dart:html` / `package:web`) that implements the same
/// small [NetTransport] interface.
///
/// Host (the boss of the game):
/// ```dart
/// final host = NetHost();
/// final server = await NetWebSocketServer.bind(host, port: 7777, address: InternetAddress.anyIPv4);
/// print(server.url);   // ws://127.0.0.1:7777/
/// ```
/// Player:
/// ```dart
/// final client = await connectNetClient('ws://192.168.1.20:7777/');   // waits for the welcome
/// client.sendToHost('chat', {'text': 'hi'});
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'net_core.dart';

/// Carries engine messages over one WebSocket. Works for both sides (server side after the upgrade,
/// client side after `WebSocket.connect`).
///
/// WebSocket is a reliable, ordered pipe (like TCP). So `reliable: false` is sent the same way:
/// nothing is dropped, but a slow link makes unreliable messages wait too. Binary frames are ignored.
/// A text message longer than [maxMessageLength] closes the connection (a simple guard for a host).
class WebSocketTransport implements NetTransport {
  WebSocketTransport(WebSocket socket, {this.maxMessageLength = 1 << 20}) : _socket = socket {
    _socket.pingInterval ??= const Duration(seconds: 10); // a dead link is noticed by itself
    _sub = _socket.listen(_onData, onDone: _finish, onError: (Object _) => _finish(), cancelOnError: true);
  }

  /// Opens a connection to a host (`ws://host:port/path`). Throws a [WebSocketException], a
  /// [SocketException] or a [TimeoutException] if it cannot.
  static Future<WebSocketTransport> connect(
    String url, {
    Duration timeout = const Duration(seconds: 10),
    Map<String, Object>? headers,
    int maxMessageLength = 1 << 20,
  }) async {
    final pending = WebSocket.connect(url, headers: headers);
    try {
      return WebSocketTransport(await pending.timeout(timeout), maxMessageLength: maxMessageLength);
    } on TimeoutException {
      pending.then((s) => s.close(), onError: (Object _) {}); // do not leave a late connection open
      rethrow;
    }
  }

  final WebSocket _socket;
  final int maxMessageLength;
  late final StreamSubscription<dynamic> _sub;
  final _controller = StreamController<String>(sync: true);
  final _closed = Completer<void>();
  bool _finished = false;
  bool _closing = false;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isOpen => !_finished && !_closing && _socket.readyState == WebSocket.open;

  /// WebSocket close code of the end (null while open). 1000 = normal, 1009 = message too big.
  int? get closeCode => _socket.closeCode;

  @override
  void send(String message, {bool reliable = true}) {
    if (!isOpen) return;
    try {
      _socket.add(message);
    } catch (_) {
      // the socket died under us: the done event finishes this transport
    }
  }

  void _onData(dynamic data) {
    if (data is! String) return; // binary frames are not part of the protocol
    if (data.length > maxMessageLength) {
      close(WebSocketStatus.messageTooBig);
      return;
    }
    if (!_controller.isClosed) _controller.add(data);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    if (!_controller.isClosed) _controller.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    if (_closing) return _closed.future;
    _closing = true;
    try {
      await _socket.close(code);
    } catch (_) {}
    await _sub.cancel();
    _finish();
  }
}

/// Decides if a connection may join. Gets the HTTP upgrade request (look at `request.uri.queryParameters`,
/// `request.headers`, `request.connectionInfo`). Return false to answer 403.
typedef NetAuthorize = FutureOr<bool> Function(HttpRequest request);

/// A WebSocket server that gives every new connection to a [NetHost] (`host.accept`).
class NetWebSocketServer {
  NetWebSocketServer._(this.host, this._server, this.path, this.authorize, this.allowedOrigins, this.maxMessageLength)
      : port = _server.port,
        url = 'ws://${_server.address.host}:${_server.port}$path' {
    _sub = _server.listen(_onRequest);
  }

  /// Starts listening. [port] 0 picks a free port (read it from [port] afterwards).
  ///
  /// [address] defaults to this computer only (`InternetAddress.loopbackIPv4`). To accept other
  /// computers use `InternetAddress.anyIPv4`.
  ///
  /// [allowedOrigins]: if set, a browser page whose `Origin` header is not in the list gets 403
  /// (stops other web sites from opening a socket to your host). Requests with no `Origin`
  /// header (apps) are accepted. [authorize]: your own check (a token in the URL, for example).
  static Future<NetWebSocketServer> bind(
    NetHost host, {
    Object? address,
    int port = 0,
    String path = '/',
    NetAuthorize? authorize,
    List<String>? allowedOrigins,
    int maxMessageLength = 1 << 20,
  }) async {
    final server = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    return NetWebSocketServer._(host, server, path, authorize, allowedOrigins, maxMessageLength);
  }

  final NetHost host;
  final HttpServer _server;
  final String path;
  final NetAuthorize? authorize;
  final List<String>? allowedOrigins;
  final int maxMessageLength;
  late final StreamSubscription<HttpRequest> _sub;
  bool _stopped = false;

  /// The port in use (stays readable after [close]).
  final int port;

  /// Address to give to clients on this computer, like `ws://127.0.0.1:7777/`.
  final String url;

  Future<void> _onRequest(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _refuse(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != path) return _refuse(request, HttpStatus.notFound);
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.headers.set(HttpHeaders.upgradeHeader, 'websocket');
      return _refuse(request, HttpStatus.upgradeRequired);
    }
    final origins = allowedOrigins;
    final origin = request.headers.value('origin');
    if (origins != null && origin != null && !origins.contains(origin)) return _refuse(request, HttpStatus.forbidden);
    final check = authorize;
    if (check != null && !await check(request)) return _refuse(request, HttpStatus.forbidden);
    final socket = await WebSocketTransformer.upgrade(request);
    if (_stopped) {
      await socket.close(WebSocketStatus.goingAway);
      return;
    }
    host.accept(WebSocketTransport(socket, maxMessageLength: maxMessageLength));
  }

  /// Stops accepting new connections. Connections that are already open stay open: close them with
  /// `host.close()`.
  Future<void> close({bool force = false}) async {
    _stopped = true;
    await _server.close(force: force);
    await _sub.cancel();
  }
}

/// A connection could not be made or the host did not let us in (for example it is full).
class NetConnectException implements Exception {
  NetConnectException(this.message);
  final String message;
  @override
  String toString() => 'NetConnectException: $message';
}

/// Connects to a [NetWebSocketServer] and returns a [NetClient].
///
/// With [waitForWelcome] (default) it returns after the host welcomed us (`client.connected` is true,
/// `client.id` is set) and throws [NetConnectException] if the host is full, closes at once, or says
/// nothing for [timeout]. `client.onConnect` and `client.onDisconnect` are free for you afterwards.
Future<NetClient> connectNetClient(
  String url, {
  Duration timeout = const Duration(seconds: 10),
  bool waitForWelcome = true,
  Map<String, Object>? headers,
}) async {
  final transport = await WebSocketTransport.connect(url, timeout: timeout, headers: headers);
  final client = NetClient(transport);
  if (!waitForWelcome) return client;
  final done = Completer<void>();
  client.onConnect = () {
    if (!done.isCompleted) done.complete();
  };
  client.onDisconnect = () {
    if (!done.isCompleted) {
      done.completeError(NetConnectException(client.serverFull ? 'the host is full' : 'the host closed the connection'));
    }
  };
  try {
    await done.future.timeout(timeout, onTimeout: () => throw NetConnectException('the host did not answer'));
  } catch (_) {
    await transport.close();
    rethrow;
  } finally {
    client.onConnect = null;
    client.onDisconnect = null;
  }
  return client;
}
