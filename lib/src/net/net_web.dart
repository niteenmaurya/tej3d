/// Browser-compatible WebSocket transport implementing [NetTransport] with zero
/// third-party packages.
///
/// On web, pass an adapter backed by the browser's `WebSocket` API (via
/// `dart:js_interop`). On the Dart VM (tests), pass [MockBrowserWebSocket].
library;

import 'dart:async';

import 'net_core.dart';

/// Minimal interface matching the browser `WebSocket` API.
abstract class BrowserWebSocket {
  Stream<String> get onMessage;
  Stream<void> get onOpen;
  Stream<void> get onClose;
  Stream<Object> get onError;

  bool get isOpen;
  void sendText(String data);
  void close([int? code, String? reason]);
}

/// [NetTransport] backed by a [BrowserWebSocket].
class WebNetTransport implements NetTransport {
  WebNetTransport(
    this._socket, {
    this.maxMessageBytes = 1024 * 1024,
  }) {
    _msgSub = _socket.onMessage.listen((msg) {
      if (!_open) return;
      if (msg.length > maxMessageBytes) return;
      _messages.add(msg);
    });
    _closeSub = _socket.onClose.listen((_) => _markClosed());
    _errSub = _socket.onError.listen((_) => _markClosed());
  }

  final BrowserWebSocket _socket;
  final int maxMessageBytes;
  final _messages = StreamController<String>.broadcast();
  final _closed = Completer<void>();
  StreamSubscription<String>? _msgSub;
  StreamSubscription<void>? _closeSub;
  StreamSubscription<Object>? _errSub;
  bool _open = true;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isOpen => _open && _socket.isOpen;

  @override
  void send(String message, {bool reliable = true}) {
    if (!isOpen) return;
    if (message.length > maxMessageBytes) {
      throw ArgumentError('Message exceeds maxMessageBytes ($maxMessageBytes)');
    }
    _socket.sendText(message);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _socket.close(1000, 'normal');
    _markClosed();
  }

  void _markClosed() {
    if (!_open) return;
    _open = false;
    _msgSub?.cancel();
    _closeSub?.cancel();
    _errSub?.cancel();
    if (!_messages.isClosed) _messages.close();
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// In-memory pair of [BrowserWebSocket]s for testing [WebNetTransport] on the
/// Dart VM without needing a real browser.
class MockBrowserWebSocket implements BrowserWebSocket {
  MockBrowserWebSocket();

  MockBrowserWebSocket? _peer;
  final _msg = StreamController<String>.broadcast();
  final _openCtrl = StreamController<void>.broadcast();
  final _closeCtrl = StreamController<void>.broadcast();
  final _errCtrl = StreamController<Object>.broadcast();
  bool _isOpen = true;

  static (MockBrowserWebSocket, MockBrowserWebSocket) pair() {
    final a = MockBrowserWebSocket();
    final b = MockBrowserWebSocket();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  Stream<String> get onMessage => _msg.stream;

  @override
  Stream<void> get onOpen => _openCtrl.stream;

  @override
  Stream<void> get onClose => _closeCtrl.stream;

  @override
  Stream<Object> get onError => _errCtrl.stream;

  @override
  bool get isOpen => _isOpen;

  @override
  void sendText(String data) {
    if (!_isOpen) return;
    final p = _peer;
    if (p != null && p._isOpen) {
      p._msg.add(data);
    }
  }

  @override
  void close([int? code, String? reason]) {
    if (!_isOpen) return;
    _isOpen = false;
    _closeCtrl.add(null);
    _msg.close();
    _openCtrl.close();
    _closeCtrl.close();
    _errCtrl.close();
    final p = _peer;
    if (p != null && p._isOpen) {
      p.close(code, reason);
    }
  }
}
