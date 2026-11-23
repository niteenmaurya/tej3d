/// Real network (WebSocket over `dart:io`) for the engine's networking core.
/// Not for the web: it needs `dart:io`. See `src/net/net_io.dart`.
library;

export 'src/net/net_io.dart'
    show NetAuthorize, NetConnectException, NetWebSocketServer, WebSocketTransport, connectNetClient;
