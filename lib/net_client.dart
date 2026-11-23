/// Cross-platform client connection helper.
///
/// On VM/mobile/desktop (`dart:io`), uses `WebSocketTransport` from `net_io.dart`.
/// On web, uses `WebNetTransport` from `net_web.dart`.
library;

export 'src/net/net_client_stub.dart'
    if (dart.library.io) 'src/net/net_io.dart'
    show connectNetClient;
export 'src/net/net_web.dart'
    show BrowserWebSocket, MockBrowserWebSocket, WebNetTransport;
