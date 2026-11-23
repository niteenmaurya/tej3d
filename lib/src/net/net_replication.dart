import 'dart:async';
import 'dart:math' as math;

import '../math/vec.dart';

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import 'net_core.dart';

/// Put on every object that exists on all computers (a player, a rocket).
/// [NetReplicator] fills in the numbers.
class NetIdentity extends Component implements Inspectable {
  /// Same on all computers. -1 until it is spawned through the replicator.
  int netId = -1;

  /// Who controls it: peer id (0 is the host).
  int ownerId = 0;

  /// The name it was spawned with.
  String prefab = '';

  /// How often (per second) the owner sends where it is.
  double sendRate = 20;

  NetReplicator? _replicator;
  final SnapshotBuffer buffer = SnapshotBuffer();
  double _sendTimer = 0;

  /// True on the computer that controls this object. Only there you move it
  /// (read input); on all others it is moved by the network.
  bool get isLocal => _replicator != null && ownerId == _replicator!.localId;

  @override
  void update(double dt) {
    final r = _replicator;
    if (r == null) return;
    if (isLocal) {
      _sendTimer += dt;
      if (_sendTimer >= 1.0 / sendRate) {
        _sendTimer = 0;
        r._sendTransform(this);
      }
    } else {
      final s = buffer.sample(r.time - r.interpolationDelay);
      if (s != null) {
        transform.worldPosition = s.$1;
        transform.worldRotation = s.$2;
      }
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.integer('netId', () => netId, null, help: 'Given by the host when spawned'),
        InspectorField.integer('ownerId', () => ownerId, null, help: 'Peer that controls it (0 is the host)'),
        InspectorField.text('prefab', () => prefab, null),
        InspectorField.float('sendRate', () => sendRate, (v) => sendRate = v, min: 1, max: 240, help: 'Sends per second by the owner'),
      ];
}

typedef NetPrefab = GameObject Function();

/// Keeps the objects of a game the same on all computers: spawning, removing
/// and moving. The host decides what exists; the owner of an object decides
/// where it is (and is trusted: see [validateMove]).
///
/// ```dart
/// // host
/// final net = NetReplicator.host(host, scene, {'Player': () => makePlayer()});
/// net.spawn('Player', owner: peer.id);
/// // client
/// final net = NetReplicator.client(client, scene, {'Player': () => makePlayer()});
/// // every frame on both
/// net.update(dt);
/// ```
///
/// Both sides need the same prefab names. Objects made by a prefab get a
/// [NetIdentity] if they do not have one.
class NetReplicator {
  NetReplicator.host(NetHost host, this.scene, this.prefabs)
      : _host = host,
        _client = null {
    host.time = () => time;
    host.onJoin = (peer) {
      for (final go in objects.values) {
        host.send(peer, 'spawn', _spawnData(go));
      }
      onPeerJoin?.call(peer);
    };
    host.onLeave = (peer) {
      if (despawnOnLeave) {
        for (final go in List.of(objects.values)) {
          if (go.getComponent<NetIdentity>()!.ownerId == peer.id) despawn(go);
        }
      }
      onPeerLeave?.call(peer);
    };
    host.on('xf', (from, d) {
      final id = (d['id'] as num).toInt();
      final go = objects[id];
      if (go == null) return;
      final ident = go.getComponent<NetIdentity>()!;
      if (ident.ownerId != from.id) return; // only the owner may move it
      final p = _vec(d['p']), q = _quat(d['r']);
      if (p == null || q == null) return;
      if (validateMove != null && !validateMove!(from, go, p)) return;
      final t = (d['t'] as num?)?.toDouble() ?? time;
      ident.buffer.add(t, p, q);
      host.broadcast('xf', d, false, from);
    });
    host.handleCall('spawn', (from, args) {
      final a = (args as Map?)?.cast<String, Object?>() ?? {};
      final name = a['prefab']?.toString();
      if (name == null || !prefabs.containsKey(name)) throw 'unknown prefab $name';
      if (allowClientSpawn != null && !allowClientSpawn!(from, name)) throw 'not allowed';
      final go = spawn(name, position: _vec(a['p']), rotation: _quat(a['r']), owner: from.id)!;
      return go.getComponent<NetIdentity>()!.netId;
    });
  }

  NetReplicator.client(NetClient client, this.scene, this.prefabs)
      : _host = null,
        _client = client {
    client.on('spawn', (_, d) => _onSpawn(d));
    client.on('despawn', (_, d) {
      final go = objects.remove((d['id'] as num).toInt());
      go?.destroy();
    });
    client.on('xf', (_, d) {
      final go = objects[(d['id'] as num).toInt()];
      if (go == null) return;
      final ident = go.getComponent<NetIdentity>()!;
      if (ident.ownerId == localId) return; // we move it ourselves
      final p = _vec(d['p']), q = _quat(d['r']);
      if (p == null || q == null) return;
      ident.buffer.add((d['t'] as num?)?.toDouble() ?? time, p, q);
    });
  }

  final Scene scene;
  final Map<String, NetPrefab> prefabs;
  final NetHost? _host;
  final NetClient? _client;

  /// All replicated objects by network id.
  final Map<int, GameObject> objects = {};

  /// Called when an object was created or removed here.
  void Function(GameObject go)? onSpawned;
  void Function(GameObject go)? onDespawned;
  void Function(NetPeer peer)? onPeerJoin;
  void Function(NetPeer peer)? onPeerLeave;

  /// Host: remove the objects of a player who left.
  bool despawnOnLeave = true;

  /// Host: return false to refuse a move (cheating, teleporting).
  bool Function(NetPeer from, GameObject go, Vector3 newPosition)? validateMove;

  /// Host: return false to refuse a spawn requested by a client.
  bool Function(NetPeer from, String prefab)? allowClientSpawn;

  /// Seconds that remote objects are shown in the past, so there is always a
  /// next snapshot to move towards. Bigger is smoother but later.
  double interpolationDelay = 0.1;

  double _time = 0;
  int _nextNetId = 1;
  double _pingTimer = 0;
  double _clockOffset = 0;
  bool _haveClock = false;

  bool get isHost => _host != null;

  /// Our number: 0 for the host, the number the host gave us for a client (-1 before we are welcomed).
  int get localId => _host != null ? 0 : _client!.id;

  /// The game time all computers share (the host's time).
  double get time => _host != null ? _time : _time + _clockOffset;

  /// Makes a [prefab] object on all computers. Host only. [owner] is the peer
  /// that controls it (default: the host).
  GameObject? spawn(String prefab, {Vector3? position, Quaternion? rotation, int owner = 0}) {
    final host = _host;
    if (host == null) throw StateError('Only the host spawns objects. Clients ask with requestSpawn().');
    final make = prefabs[prefab];
    if (make == null) throw ArgumentError('Unknown prefab "$prefab". Known: ${prefabs.keys.join(', ')}');
    final go = make();
    final ident = go.getComponent<NetIdentity>() ?? go.addComponent(NetIdentity());
    ident.netId = _nextNetId++;
    ident.ownerId = owner;
    ident.prefab = prefab;
    ident._replicator = this;
    if (position != null) go.transform.worldPosition = position;
    if (rotation != null) go.transform.worldRotation = rotation;
    scene.add(go);
    objects[ident.netId] = go;
    host.broadcast('spawn', _spawnData(go));
    onSpawned?.call(go);
    return go;
  }

  /// Client: asks the host to make an object that we control. Completes with
  /// its network id (the object appears through the normal spawn message).
  Future<int> requestSpawn(String prefab, {Vector3? position, Quaternion? rotation}) async {
    final c = _client;
    if (c == null) throw StateError('The host uses spawn().');
    final r = await c.callHost('spawn', {
      'prefab': prefab,
      if (position != null) 'p': [position.x, position.y, position.z],
      if (rotation != null) 'r': [rotation.x, rotation.y, rotation.z, rotation.w],
    });
    return (r as num).toInt();
  }

  /// Removes an object on all computers. Host only.
  void despawn(GameObject go) {
    final host = _host;
    if (host == null) throw StateError('Only the host removes objects.');
    final ident = go.getComponent<NetIdentity>();
    if (ident == null || objects.remove(ident.netId) == null) return;
    host.broadcast('despawn', {'id': ident.netId});
    go.destroy();
    onDespawned?.call(go);
  }

  /// The object with this id, or null.
  GameObject? find(int netId) => objects[netId];

  /// Call every frame (before `scene.update`).
  void update(double dt) {
    _time += dt;
    final c = _client;
    if (c != null) {
      c.update(dt);
      _pingTimer += dt;
      if (c.connected && (_pingTimer >= 1.0 || (!_haveClock && _pingTimer >= 0.05))) {
        _pingTimer = 0;
        c.ping();
      }
      if (c.rtt > 0 || c.clockOffset != 0) {
        // the offset of the clock: host time = our time + offset (smoothed, jumps at the first measurement)
        final target = c.clockOffset;
        _clockOffset = _haveClock ? _clockOffset + (target - _clockOffset) * math.min(1.0, dt * 4) : target;
        if (!_haveClock) _haveClock = true;
      }
    } else {
      _host!.tickRpc(dt);
    }
  }

  // ---- internals

  Map<String, Object?> _spawnData(GameObject go) {
    final i = go.getComponent<NetIdentity>()!;
    final p = go.transform.worldPosition, q = go.transform.worldRotation;
    return {
      'id': i.netId,
      'prefab': i.prefab,
      'owner': i.ownerId,
      'p': [p.x, p.y, p.z],
      'r': [q.x, q.y, q.z, q.w],
    };
  }

  void _onSpawn(Map<String, Object?> d) {
    final id = (d['id'] as num).toInt();
    if (objects.containsKey(id)) return;
    final make = prefabs[d['prefab']];
    if (make == null) return; // this build does not know the prefab: ignore
    final go = make();
    final ident = go.getComponent<NetIdentity>() ?? go.addComponent(NetIdentity());
    ident.netId = id;
    ident.ownerId = (d['owner'] as num).toInt();
    ident.prefab = d['prefab'].toString();
    ident._replicator = this;
    final p = _vec(d['p']), q = _quat(d['r']);
    if (p != null) go.transform.worldPosition = p;
    if (q != null) go.transform.worldRotation = q;
    if (p != null && q != null) ident.buffer.add(time, p, q);
    scene.add(go);
    objects[id] = go;
    onSpawned?.call(go);
  }

  void _sendTransform(NetIdentity ident) {
    final p = ident.transform.worldPosition, q = ident.transform.worldRotation;
    final d = {
      'id': ident.netId,
      't': time,
      'p': [p.x, p.y, p.z],
      'r': [q.x, q.y, q.z, q.w],
    };
    final h = _host;
    if (h != null) {
      h.broadcast('xf', d, false);
    } else {
      _client!.sendToHost('xf', d, false);
    }
  }

  static Vector3? _vec(Object? o) {
    if (o is! List || o.length != 3) return null;
    return Vector3((o[0] as num).toDouble(), (o[1] as num).toDouble(), (o[2] as num).toDouble());
  }

  static Quaternion? _quat(Object? o) {
    if (o is! List || o.length != 4) return null;
    return Quaternion((o[0] as num).toDouble(), (o[1] as num).toDouble(), (o[2] as num).toDouble(), (o[3] as num).toDouble());
  }
}
