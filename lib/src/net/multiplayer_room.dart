import 'dart:math' as math;

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';

/// Server-authoritative state of one player inside [MultiplayerRoomServer].
class RoomPlayerState {
  RoomPlayerState({
    required this.playerId,
    required this.displayName,
    Vector3? position,
    this.yaw = 0.0,
    this.health = 100.0,
    this.kills = 0,
    this.alive = true,
  }) : position = position?.clone() ?? Vector3.zero();

  final String playerId;
  final String displayName;
  Vector3 position;
  double yaw;
  double health;
  int kills;
  bool alive;

  Map<String, Object?> toJson() => {
        'id': playerId,
        'name': displayName,
        'x': position.x,
        'y': position.y,
        'z': position.z,
        'yaw': yaw,
        'hp': health,
        'kills': kills,
        'alive': alive,
      };
}

/// Authoritative Battle Royale / Multiplayer Room Server (pure Dart, up to 50 players).
/// Handles lobby join/leave, speed-hack clamped movement sync, server-side ray hit
/// validation, kill feed events, and safe-zone radius broadcast.
class MultiplayerRoomServer {
  MultiplayerRoomServer({
    required this.roomId,
    this.maxPlayers = 50,
    this.maxMoveSpeedMs = 14.0,
    this.safeZoneRadius = 50.0,
  });

  final String roomId;
  final int maxPlayers;
  final double maxMoveSpeedMs;

  double safeZoneRadius;
  int serverTick = 0;

  final Map<String, RoomPlayerState> players = {};
  final List<String> killFeed = [];

  int get aliveCount => players.values.where((p) => p.alive).length;

  /// Joins a player into the room if space is available.
  RoomPlayerState? join(String playerId, String displayName, {Vector3? spawnPos}) {
    if (players.containsKey(playerId)) return players[playerId];
    if (players.length >= maxPlayers) return null;
    final state = RoomPlayerState(
      playerId: playerId,
      displayName: displayName,
      position: spawnPos ?? Vector3(0, 0, 0),
    );
    players[playerId] = state;
    return state;
  }

  void leave(String playerId) => players.remove(playerId);

  /// Validates and applies a client's requested position update (anti-teleport clamp).
  bool applyMove(String playerId, Vector3 targetPos, double yaw, double dt) {
    final p = players[playerId];
    if (p == null || !p.alive) return false;
    final delta = targetPos - p.position;
    final maxDist = maxMoveSpeedMs * math.max(dt, 1.0 / 60.0) * 1.5;
    if (delta.length > maxDist) {
      p.position = p.position + delta.normalized() * maxDist;
    } else {
      p.position = targetPos.clone();
    }
    p.yaw = yaw;
    return true;
  }

  /// Server-authoritative hitscan fire check against all other alive players.
  /// Returns the hit player's ID if a hit was validated, else null.
  String? validateFire({
    required String shooterId,
    required Vector3 origin,
    required Vector3 direction,
    double damage = 28.0,
    double maxRange = 90.0,
    double hitRadius = 1.0,
  }) {
    final shooter = players[shooterId];
    if (shooter == null || !shooter.alive) return null;
    final dir = direction.normalized();
    RoomPlayerState? hitPlayer;
    var bestDist = maxRange;

    for (final p in players.values) {
      if (p.playerId == shooterId || !p.alive) continue;
      final center = p.position + Vector3(0, 0.9, 0);
      final toTarget = center - origin;
      final proj = toTarget.dot(dir);
      if (proj < 0 || proj > bestDist) continue;
      final closest = origin + dir * proj;
      if ((center - closest).length <= hitRadius) {
        bestDist = proj;
        hitPlayer = p;
      }
    }

    if (hitPlayer == null) return null;
    hitPlayer.health = math.max(0.0, hitPlayer.health - damage);
    if (hitPlayer.health <= 0.0) {
      hitPlayer.alive = false;
      shooter.kills++;
      killFeed.add('${shooter.displayName} eliminated ${hitPlayer.displayName}');
    }
    return hitPlayer.playerId;
  }

  /// Advances one authoritative server tick and returns a serializable world snapshot.
  Map<String, Object?> stepSnapshot(double dt, {double zoneShrinkSpeed = 0.8}) {
    serverTick++;
    if (safeZoneRadius > 6.0) {
      safeZoneRadius = math.max(6.0, safeZoneRadius - zoneShrinkSpeed * dt);
    }
    return {
      'room': roomId,
      'tick': serverTick,
      'zoneRadius': safeZoneRadius,
      'alive': aliveCount,
      'players': [for (final p in players.values) p.toJson()],
      'killFeed': List<String>.of(killFeed),
    };
  }
}

/// Client-side multiplayer sync component binding a [GameObject] to a [MultiplayerRoomServer]
/// (or remote WebSocket/UDP snapshot stream) with smooth remote interpolation.
class MultiplayerSyncComponent extends Component implements Inspectable {
  MultiplayerSyncComponent({
    this.playerId = 'player_1',
    this.displayName = 'Player 1',
    this.isLocalPlayer = true,
    this.interpolationSpeed = 12.0,
    this.room,
  });

  String playerId;
  String displayName;
  bool isLocalPlayer;
  double interpolationSpeed;
  MultiplayerRoomServer? room;

  Vector3 _remoteTargetPos = Vector3.zero();
  bool _hasRemoteTarget = false;

  /// Applies an incoming authoritative snapshot for remote player interpolation.
  void applyRemoteState(Vector3 pos) {
    _remoteTargetPos = pos.clone();
    _hasRemoteTarget = true;
  }

  @override
  void update(double dt) {
    final r = room;
    if (isLocalPlayer) {
      if (r != null) {
        r.join(playerId, displayName, spawnPos: transform.worldPosition);
        r.applyMove(playerId, transform.worldPosition, 0.0, dt);
      }
    } else {
      if (r != null && r.players.containsKey(playerId)) {
        _remoteTargetPos = r.players[playerId]!.position.clone();
        _hasRemoteTarget = true;
      }
      if (_hasRemoteTarget) {
        final t = (interpolationSpeed * dt).clamp(0.0, 1.0);
        transform.worldPosition = transform.worldPosition + (_remoteTargetPos - transform.worldPosition) * t;
      }
    }
  }

  String get inspectorTitle => 'Multiplayer Sync ($playerId)';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('Player ID', () => playerId, (v) => playerId = v),
        InspectorField.text('Name', () => displayName, (v) => displayName = v),
        InspectorField.boolean('Local Player', () => isLocalPlayer, (v) => isLocalPlayer = v),
      ];
}
