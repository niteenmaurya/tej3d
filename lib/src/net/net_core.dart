import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../math/vec.dart';

/// A two way pipe that carries text messages between two computers. The engine
/// does not care how: [LoopbackNetwork] (tests, local play), web sockets
/// (`net_io.dart`), or your own (a platform plugin, a relay server).
///
/// Messages must arrive in order and without loss (like TCP) when [reliable]
/// is true. Messages sent with `reliable: false` may be dropped (UDP like);
/// [LoopbackNetwork] can simulate that.
abstract class NetTransport {
  /// Text messages received.
  Stream<String> get messages;

  /// Completes when the pipe is closed (by either side).
  Future<void> get closed;

  bool get isOpen;

  void send(String message, {bool reliable = true});

  Future<void> close();
}

/// Settings of a simulated bad network.
class NetConditions {
  const NetConditions({this.latency = 0.0, this.jitter = 0.0, this.loss = 0.0});

  /// One way delay in seconds.
  final double latency;

  /// Random extra delay (0..jitter seconds) per message. Reliable messages are
  /// still delivered in order.
  final double jitter;

  /// Chance (0..1) that an unreliable message is lost.
  final double loss;
}

/// A network inside the program, with a virtual clock: nothing is delivered
/// until you call [advance]. Gives repeatable tests of lag and packet loss.
class LoopbackNetwork {
  LoopbackNetwork({this.conditions = const NetConditions(), int seed = 1}) : _rng = math.Random(seed);

  NetConditions conditions;
  final math.Random _rng;
  double _now = 0;
  final List<_Pending> _queue = [];
  final Map<_LoopEnd, double> _lastReliable = {};

  /// Virtual time in seconds.
  double get now => _now;

  /// Makes a connected pair: what one sends, the other receives.
  (NetTransport, NetTransport) pair() {
    final a = _LoopEnd(this), b = _LoopEnd(this);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  /// Moves time forward and delivers the messages that are due.
  void advance(double seconds) {
    final target = _now + seconds;
    while (true) {
      _queue.sort((x, y) => x.due != y.due ? x.due.compareTo(y.due) : x.order.compareTo(y.order));
      if (_queue.isEmpty || _queue.first.due > target) break;
      final m = _queue.removeAt(0);
      _now = math.max(_now, m.due);
      m.to._deliver(m.text);
    }
    _now = target;
  }

  int _order = 0;

  void _send(_LoopEnd from, _LoopEnd to, String text, bool reliable) {
    if (!reliable && _rng.nextDouble() < conditions.loss) return;
    var due = _now + conditions.latency + _rng.nextDouble() * conditions.jitter;
    if (reliable) {
      // keep the order of reliable messages
      final last = _lastReliable[from] ?? 0;
      if (due < last) due = last;
      _lastReliable[from] = due;
    }
    _queue.add(_Pending(due, _order++, to, text));
  }

  /// Messages still on the way.
  int get inFlight => _queue.length;
}

class _Pending {
  _Pending(this.due, this.order, this.to, this.text);
  final double due;
  final int order;
  final _LoopEnd to;
  final String text;
}

class _LoopEnd implements NetTransport {
  _LoopEnd(this._net);
  final LoopbackNetwork _net;
  late _LoopEnd _peer;
  final _controller = StreamController<String>(sync: true);
  final _closed = Completer<void>();
  bool _open = true;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isOpen => _open;

  @override
  void send(String message, {bool reliable = true}) {
    if (!_open) return;
    _net._send(this, _peer, message, reliable);
  }

  void _deliver(String text) {
    if (_open) _controller.add(text);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _closed.complete();
    if (!_controller.isClosed) await _controller.close();
    if (_peer._open) await _peer.close();
  }
}

// ======================================================================
// Sessions: a host and clients exchanging named messages
// ======================================================================

/// Someone connected to a [NetHost].
class NetPeer {
  NetPeer._(this.id, this._transport);

  /// Number given by the host (1, 2, 3 ...). The host itself is 0.
  final int id;
  final NetTransport _transport;

  /// Last measured round trip time in seconds (0 until measured).
  double rtt = 0;

  String? name;
  bool get isConnected => _transport.isOpen;
}

typedef NetHandler = void Function(NetPeer from, Map<String, Object?> data);
typedef NetRpcHandler = FutureOr<Object?> Function(NetPeer from, Object? args);

/// One side of the protocol, shared by [NetHost] and [NetClient].
abstract class NetNode {
  final Map<String, List<NetHandler>> _handlers = {};
  final Map<String, NetRpcHandler> _rpc = {};
  final Map<int, Completer<Object?>> _calls = {};
  int _nextCall = 1;

  /// Seconds to wait for an answer to [call].
  double rpcTimeout = 5.0;

  /// Runs [handler] for every message of type [type].
  void on(String type, NetHandler handler) => (_handlers[type] ??= []).add(handler);

  /// Names a function others can call with [call].
  void handleCall(String name, NetRpcHandler handler) => _rpc[name] = handler;

  /// Removes a previously registered RPC handler.
  void removeCallHandler(String name) => _rpc.remove(name);

  void _dispatch(NetPeer from, String raw) {
    Map<String, Object?> m;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return;
      m = d.cast<String, Object?>();
    } catch (_) {
      return; // not ours: ignore
    }
    final type = m['t'];
    if (type is! String) return;
    final data = (m['d'] is Map) ? (m['d'] as Map).cast<String, Object?>() : <String, Object?>{};
    switch (type) {
      case '_rpc':
        _onRpc(from, m);
      case '_ret':
        final c = _calls.remove((m['id'] as num?)?.toInt());
        if (c != null) {
          if (m['err'] != null) {
            c.completeError(NetRpcError(m['err'].toString()));
          } else {
            c.complete(m['r']);
          }
        }
      default:
        for (final h in List.of(_handlers[type] ?? const <NetHandler>[])) {
          h(from, data);
        }
    }
  }

  void _onRpc(NetPeer from, Map<String, Object?> m) {
    final id = (m['id'] as num?)?.toInt();
    final h = _rpc[m['n']];
    if (id == null) return;
    void ok(Object? r) => _sendRaw(from, jsonEncode({'t': '_ret', 'id': id, 'r': r}), true);
    void fail(Object e) => _sendRaw(from, jsonEncode({'t': '_ret', 'id': id, 'err': e.toString()}), true);
    if (h == null) {
      fail('no such call: ${m['n']}');
      return;
    }
    try {
      final r = h(from, m['a']);
      if (r is Future) {
        r.then(ok, onError: fail); // an async handler answers when it is done
      } else {
        ok(r); // a plain handler answers at once
      }
    } catch (e) {
      fail(e);
    }
  }

  void _sendRaw(NetPeer to, String text, bool reliable) => to._transport.send(text, reliable: reliable);

  /// Sends a message of [type] with [data] (anything JSON can carry).
  void send(NetPeer to, String type, [Map<String, Object?> data = const {}, bool reliable = true]) =>
      _sendRaw(to, jsonEncode({'t': type, 'd': data}), reliable);

  /// Calls a function on the other side and waits for its result (a Future).
  /// Fails with [NetRpcError] if the other side has no such function, it threw,
  /// or no answer came within [rpcTimeout] (needs [NetClock] updates to time out).
  Future<Object?> call(NetPeer to, String name, [Object? args]) {
    final id = _nextCall++;
    final c = Completer<Object?>();
    _calls[id] = c;
    _callAges[id] = 0;
    _sendRaw(to, jsonEncode({'t': '_rpc', 'id': id, 'n': name, 'a': args}), true);
    return c.future;
  }

  final Map<int, double> _callAges = {};

  /// Time passes: fails calls that waited too long.
  void tickRpc(double dt) {
    for (final id in List<int>.of(_calls.keys)) {
      final age = (_callAges[id] ?? 0) + dt;
      _callAges[id] = age;
      if (age >= rpcTimeout) {
        _callAges.remove(id);
        _calls.remove(id)?.completeError(NetRpcError('timeout'));
      }
    }
  }
}

class NetRpcError implements Exception {
  NetRpcError(this.message);
  final String message;
  @override
  String toString() => 'NetRpcError: $message';
}

/// The computer that is the boss of a game: clients connect to it.
///
/// ```dart
/// final host = NetHost()..onJoin = (peer) => print('hello ${peer.id}');
/// host.accept(transport);                  // for every new connection
/// host.broadcast('chat', {'text': 'hi'});
/// host.on('chat', (from, data) => ...);
/// ```
class NetHost extends NetNode {
  NetHost({this.maxPeers = 16}) {
    local = NetPeer._(0, _NullTransport());
  }

  /// This computer as a peer (id 0).
  late final NetPeer local;

  final int maxPeers;

  /// The time (seconds) the host tells clients when they ping. Set by `NetReplicator`.
  double Function() time = () => 0.0;
  final Map<int, NetPeer> _peers = {};
  int _nextId = 1;

  void Function(NetPeer peer)? onJoin;
  void Function(NetPeer peer)? onLeave;

  List<NetPeer> get peers => _peers.values.toList();
  int get peerCount => _peers.length;

  /// Handles a new connection. Returns the peer, or null if the host is full.
  NetPeer? accept(NetTransport t) {
    if (_peers.length >= maxPeers) {
      t.send(jsonEncode({'t': '_full'}));
      t.close();
      return null;
    }
    final peer = NetPeer._(_nextId++, t);
    _peers[peer.id] = peer;
    t.messages.listen((raw) => _fromPeer(peer, raw));
    t.closed.then((_) {
      if (_peers.remove(peer.id) != null) onLeave?.call(peer);
    });
    t.send(jsonEncode({'t': '_welcome', 'd': {'id': peer.id}}));
    onJoin?.call(peer);
    return peer;
  }

  void _fromPeer(NetPeer peer, String raw) {
    // built in: ping
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['t'] == '_ping') {
        final pd = Map<String, Object?>.from((d['d'] as Map).cast<String, Object?>())..['h'] = time();
        peer._transport.send(jsonEncode({'t': '_pong', 'd': pd}));
        return;
      }
      if (d is Map && d['t'] == '_rtt') {
        peer.rtt = ((d['d'] as Map?)?['rtt'] as num?)?.toDouble() ?? peer.rtt;
        return;
      }
      if (d is Map && d['t'] == '_name') {
        peer.name = (d['d'] as Map?)?['name']?.toString();
      }
    } catch (_) {}
    _dispatch(peer, raw);
  }

  /// Sends to everybody (except [except]).
  void broadcast(String type, [Map<String, Object?> data = const {}, bool reliable = true, NetPeer? except]) {
    final text = jsonEncode({'t': type, 'd': data});
    for (final p in _peers.values) {
      if (p != except) p._transport.send(text, reliable: reliable);
    }
  }

  /// Sends one message to [to]. (Same as `send`.)
  void sendTo(NetPeer to, String type, [Map<String, Object?> data = const {}, bool reliable = true]) =>
      send(to, type, data, reliable);

  /// Throws a peer out.
  Future<void> kick(NetPeer peer) => peer._transport.close();

  Future<void> close() async {
    for (final p in List.of(_peers.values)) {
      await p._transport.close();
    }
  }
}

/// The player's side: connects to a [NetHost].
class NetClient extends NetNode {
  NetClient(this._transport) {
    server = NetPeer._(0, _transport);
    _transport.messages.listen(_receive);
    _transport.closed.then((_) {
      connected = false;
      onDisconnect?.call();
    });
  }

  final NetTransport _transport;

  /// The host as a peer.
  late final NetPeer server;

  /// Our number, once the host has welcomed us (-1 before).
  int id = -1;

  bool connected = false;
  bool serverFull = false;

  void Function()? onConnect;
  void Function()? onDisconnect;

  final Map<int, double> _pings = {};
  int _pingId = 0;

  /// Round trip time to the host in seconds (smoothed; 0 until measured).
  double rtt = 0;

  /// Host time minus our time, estimated from pings (seconds).
  double clockOffset = 0;
  double _localTime = 0;

  void _receive(String raw) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        if (d['t'] == '_welcome') {
          id = ((d['d'] as Map)['id'] as num).toInt();
          connected = true;
          onConnect?.call();
          return;
        }
        if (d['t'] == '_full') {
          serverFull = true;
          return;
        }
        if (d['t'] == '_pong') {
          final data = (d['d'] as Map).cast<String, Object?>();
          final sent = _pings.remove((data['i'] as num).toInt());
          if (sent != null) {
            final sample = _localTime - sent;
            rtt = rtt == 0 ? sample : rtt * 0.8 + sample * 0.2;
            final hostTime = (data['h'] as num?)?.toDouble();
            if (hostTime != null) clockOffset = hostTime + sample / 2 - _localTime;
            send(server, '_rtt', {'rtt': rtt});
          }
          return;
        }
      }
    } catch (_) {}
    _dispatch(server, raw);
  }

  /// Measures the round trip time. Call every second or so, with time passing
  /// through [update].
  void ping() {
    final i = _pingId++;
    _pings[i] = _localTime;
    _transport.send(jsonEncode({'t': '_ping', 'd': {'i': i, 'h': 0}}));
  }

  /// Time passes (use your frame time). Needed for ping times and RPC time outs.
  void update(double dt) {
    _localTime += dt;
    tickRpc(dt);
  }

  /// Sends to the host.
  void sendToHost(String type, [Map<String, Object?> data = const {}, bool reliable = true]) => send(server, type, data, reliable);

  /// Calls a function on the host.
  Future<Object?> callHost(String name, [Object? args]) => call(server, name, args);

  Future<void> close() => _transport.close();
}

class _NullTransport implements NetTransport {
  @override
  Stream<String> get messages => const Stream.empty();
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  bool get isOpen => true;
  @override
  void send(String message, {bool reliable = true}) {}
  @override
  Future<void> close() async {}
}

// ======================================================================
// Smooth movement of things that other players control
// ======================================================================

/// Remembers where a remote object was and when, and tells where it was at
/// any time in between (snapshot interpolation). Render a little in the past
/// ([delay], for example 0.1 s) so there is always a next snapshot to blend to.
class SnapshotBuffer {
  SnapshotBuffer({this.maxSnapshots = 64, this.maxExtrapolation = 0.25});

  final int maxSnapshots;

  /// How long (seconds) it keeps moving on its last speed when no newer snapshot came.
  final double maxExtrapolation;

  final List<_Snap> _snaps = [];

  int get length => _snaps.length;

  /// Adds a snapshot taken at [time] (seconds, same clock for all). Snapshots
  /// that arrive late (older than the newest) are put in the right place.
  void add(double time, Vector3 position, Quaternion rotation) {
    final s = _Snap(time, position.clone(), rotation.clone());
    var i = _snaps.length;
    while (i > 0 && _snaps[i - 1].time > time) {
      i--;
    }
    if (i > 0 && _snaps[i - 1].time == time) {
      _snaps[i - 1] = s;
    } else {
      _snaps.insert(i, s);
    }
    while (_snaps.length > maxSnapshots) {
      _snaps.removeAt(0);
    }
  }

  /// Position and rotation at [time]; null if nothing was added yet.
  (Vector3, Quaternion)? sample(double time) {
    if (_snaps.isEmpty) return null;
    if (time <= _snaps.first.time) return (_snaps.first.position.clone(), _snaps.first.rotation.clone());
    final last = _snaps.last;
    if (time >= last.time) {
      if (_snaps.length < 2 || maxExtrapolation <= 0) return (last.position.clone(), last.rotation.clone());
      final prev = _snaps[_snaps.length - 2];
      final dt = last.time - prev.time;
      final over = math.min(time - last.time, maxExtrapolation);
      final v = dt > 1e-9 ? (last.position - prev.position) / dt : Vector3.zero();
      return (last.position + v * over, last.rotation.clone());
    }
    var i = 1;
    while (_snaps[i].time < time) {
      i++;
    }
    final a = _snaps[i - 1], b = _snaps[i];
    final k = (time - a.time) / (b.time - a.time);
    return (_lerp(a.position, b.position, k), _slerp(a.rotation, b.rotation, k));
  }

  static Vector3 _lerp(Vector3 a, Vector3 b, double t) => a + (b - a) * t;

  static Quaternion _slerp(Quaternion a, Quaternion b, double t) {
    var cosHalf = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    var bq = b;
    if (cosHalf < 0) {
      bq = Quaternion(-b.x, -b.y, -b.z, -b.w);
      cosHalf = -cosHalf;
    }
    if (cosHalf > 0.9995) {
      return Quaternion(a.x + (bq.x - a.x) * t, a.y + (bq.y - a.y) * t, a.z + (bq.z - a.z) * t, a.w + (bq.w - a.w) * t)..normalize();
    }
    final half = math.acos(cosHalf);
    final s = math.sin(half);
    final wa = math.sin((1 - t) * half) / s, wb = math.sin(t * half) / s;
    return Quaternion(a.x * wa + bq.x * wb, a.y * wa + bq.y * wb, a.z * wa + bq.z * wb, a.w * wa + bq.w * wb);
  }

  void clear() => _snaps.clear();
}

class _Snap {
  _Snap(this.time, this.position, this.rotation);
  final double time;
  final Vector3 position;
  final Quaternion rotation;
}
