import 'dart:math' as math;

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';

/// Health + Shield + Damage component for players, enemy bots, vehicles, and destructible props.
class HealthDamageComponent extends Component implements Inspectable {
  HealthDamageComponent({
    this.maxHealth = 100.0,
    double? currentHealth,
    this.maxShield = 50.0,
    this.shield = 25.0,
    this.destroyOnDeath = false,
  }) : currentHealth = currentHealth ?? maxHealth;

  double maxHealth;
  double currentHealth;
  double maxShield;
  double shield;
  bool destroyOnDeath;

  bool get isDead => currentHealth <= 0.0;
  double get healthFraction => maxHealth > 0 ? (currentHealth / maxHealth).clamp(0.0, 1.0) : 0.0;

  void Function(double amount, GameObject? attacker)? onDamaged;
  void Function(GameObject? killer)? onDeath;

  /// Applies [amount] damage (absorbs with [shield] first). Returns true if this hit caused death.
  bool takeDamage(double amount, {GameObject? attacker}) {
    if (isDead || amount <= 0) return false;
    var remaining = amount;
    if (shield > 0) {
      final absorbed = math.min(shield, remaining);
      shield -= absorbed;
      remaining -= absorbed;
    }
    currentHealth = math.max(0.0, currentHealth - remaining);
    onDamaged?.call(amount, attacker);
    if (isDead) {
      onDeath?.call(attacker);
      if (destroyOnDeath && isAttached) {
        gameObject.destroy();
      }
      return true;
    }
    return false;
  }

  void heal(double amount) {
    if (isDead || amount <= 0) return;
    currentHealth = math.min(maxHealth, currentHealth + amount);
  }

  void addShield(double amount) {
    if (isDead || amount <= 0) return;
    shield = math.min(maxShield, shield + amount);
  }

  void revive() {
    currentHealth = maxHealth;
    shield = maxShield * 0.5;
  }

  String get inspectorTitle => 'Health & Damage';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Max Health', () => maxHealth, (v) => maxHealth = v, min: 1, max: 1000),
        InspectorField.float('Health', () => currentHealth, (v) => currentHealth = v, min: 0, max: 1000),
        InspectorField.float('Shield', () => shield, (v) => shield = v, min: 0, max: 500),
        InspectorField.boolean('Destroy On Death', () => destroyOnDeath, (v) => destroyOnDeath = v),
      ];
}

/// Result of a weapon shot fired by [WeaponComponent].
class WeaponShotResult {
  const WeaponShotResult({
    required this.fired,
    this.hitTarget,
    this.hitPoint,
    this.hitDistance = 0.0,
    this.damageDealt = 0.0,
    this.eliminated = false,
  });

  final bool fired;
  final GameObject? hitTarget;
  final Vector3? hitPoint;
  final double hitDistance;
  final double damageDealt;
  final bool eliminated;
}

/// Battle Royale / FPS weapon component with fire rate, magazine/reserve ammo,
/// reload timer, recoil kick, and instant hitscan sphere-cast target detection.
class WeaponComponent extends Component implements Inspectable {
  WeaponComponent({
    this.weaponName = 'AK-47 Tactical',
    this.damage = 28.0,
    this.fireRate = 8.5,
    this.magSize = 30,
    int? ammo,
    this.reserveAmmo = 120,
    this.reloadDuration = 1.6,
    this.range = 85.0,
    this.recoilKick = 0.04,
  }) : ammo = ammo ?? magSize;

  String weaponName;
  double damage;
  double fireRate;
  int magSize;
  int ammo;
  int reserveAmmo;
  double reloadDuration;
  double range;
  double recoilKick;

  double _cooldown = 0.0;
  double _reloadTimer = 0.0;
  double currentRecoil = 0.0;
  int shotsFired = 0;

  bool get isReloading => _reloadTimer > 0.0;
  bool get canFire => !isReloading && _cooldown <= 0.0 && ammo > 0;

  void Function(Vector3 origin, Vector3 direction, WeaponShotResult result)? onFired;

  @override
  void update(double dt) {
    if (_cooldown > 0) _cooldown = math.max(0.0, _cooldown - dt);
    if (currentRecoil > 0) currentRecoil = math.max(0.0, currentRecoil - dt * 0.25);
    if (_reloadTimer > 0) {
      _reloadTimer -= dt;
      if (_reloadTimer <= 0) {
        _reloadTimer = 0;
        final needed = magSize - ammo;
        final taken = math.min(needed, reserveAmmo);
        ammo += taken;
        reserveAmmo -= taken;
      }
    }
  }

  /// Begins reloading from [reserveAmmo].
  bool startReload() {
    if (isReloading || ammo >= magSize || reserveAmmo <= 0) return false;
    _reloadTimer = reloadDuration;
    return true;
  }

  /// Fires one shot from [origin] along [direction] against all active [HealthDamageComponent] targets in [scene].
  WeaponShotResult fire({
    required Scene scene,
    Vector3? origin,
    Vector3? direction,
    GameObject? shooter,
    double hitRadius = 1.15,
  }) {
    if (!canFire) return const WeaponShotResult(fired: false);
    ammo--;
    shotsFired++;
    _cooldown = 1.0 / math.max(0.5, fireRate);
    currentRecoil = math.min(0.45, currentRecoil + recoilKick);

    final o = origin ?? (isAttached ? transform.worldPosition + Vector3(0, 1.35, 0) : Vector3.zero());
    final d = (direction ?? (isAttached ? transform.forward : Vector3(0, 0, -1))).normalized();
    final self = shooter ?? (isAttached ? gameObject : null);

    GameObject? bestTarget;
    HealthDamageComponent? bestHealth;
    var bestDist = range;
    Vector3? bestPt;

    scene.forEachActive((go) {
      if (go == self) return;
      final hp = go.getComponent<HealthDamageComponent>();
      if (hp == null || hp.isDead) return;
      final center = go.transform.worldPosition + Vector3(0, 0.9, 0);
      final toTarget = center - o;
      final proj = toTarget.dot(d);
      if (proj < 0 || proj > bestDist) return;
      final closest = o + d * proj;
      if ((center - closest).length <= hitRadius) {
        bestDist = proj;
        bestTarget = go;
        bestHealth = hp;
        bestPt = closest;
      }
    });

    var killed = false;
    var dealt = 0.0;
    if (bestTarget != null && bestHealth != null) {
      dealt = damage;
      killed = bestHealth!.takeDamage(damage, attacker: self);
    }

    final result = WeaponShotResult(
      fired: true,
      hitTarget: bestTarget,
      hitPoint: bestPt,
      hitDistance: bestTarget != null ? bestDist : range,
      damageDealt: dealt,
      eliminated: killed,
    );
    onFired?.call(o, d, result);
    if (ammo == 0 && reserveAmmo > 0) startReload();
    return result;
  }

  String get inspectorTitle => 'Weapon';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('Name', () => weaponName, (v) => weaponName = v),
        InspectorField.float('Damage', () => damage, (v) => damage = v, min: 1, max: 500),
        InspectorField.float('Fire Rate', () => fireRate, (v) => fireRate = v, min: 0.5, max: 30),
        InspectorField.float('Range', () => range, (v) => range = v, min: 5, max: 300),
      ];
}

/// AI state for [EnemyBotAiComponent].
enum BotAiState { patrol, chase, attack, dead }

/// Autonomous Battle Royale / Shooter enemy bot: patrols waypoints, detects targets,
/// chases within engagement distance, and fires its [WeaponComponent] at the player.
class EnemyBotAiComponent extends Component implements Inspectable {
  EnemyBotAiComponent({
    this.targetTag = 'Player',
    this.detectRange = 28.0,
    this.attackRange = 18.0,
    this.moveSpeed = 4.2,
    this.patrolRadius = 10.0,
  });

  String targetTag;
  double detectRange;
  double attackRange;
  double moveSpeed;
  double patrolRadius;

  BotAiState state = BotAiState.patrol;
  Vector3? _spawnOrigin;
  double _patrolAngle = 0.0;

  @override
  void update(double dt) {
    final hp = gameObject.getComponent<HealthDamageComponent>();
    if (hp != null && hp.isDead) {
      state = BotAiState.dead;
      return;
    }
    final scene = gameObject.scene;
    if (scene == null) return;
    _spawnOrigin ??= transform.worldPosition.clone();

    // Find closest alive target matching targetTag
    GameObject? target;
    var bestDist = detectRange;
    scene.forEachActive((go) {
      if (go == gameObject || go.tag != targetTag) return;
      final thp = go.getComponent<HealthDamageComponent>();
      if (thp != null && thp.isDead) return;
      final d = (go.transform.worldPosition - transform.worldPosition).length;
      if (d < bestDist) {
        bestDist = d;
        target = go;
      }
    });

    if (target == null) {
      state = BotAiState.patrol;
      _patrolAngle += dt * 0.65;
      final goal = _spawnOrigin! + Vector3(math.cos(_patrolAngle) * patrolRadius, 0, math.sin(_patrolAngle) * patrolRadius);
      _moveToward(goal, dt);
      return;
    }

    final toTarget = target!.transform.worldPosition - transform.worldPosition;
    final flatDir = Vector3(toTarget.x, 0, toTarget.z);
    if (flatDir.length2 > 1e-4) {
      final yaw = math.atan2(-flatDir.x, -flatDir.z);
      transform.localRotation = Quaternion.axisAngle(Vector3(0, 1, 0), yaw);
    }

    if (bestDist <= attackRange) {
      state = BotAiState.attack;
      final weapon = gameObject.getComponent<WeaponComponent>();
      if (weapon != null && weapon.canFire) {
        weapon.fire(
          scene: scene,
          origin: transform.worldPosition + Vector3(0, 1.35, 0),
          direction: toTarget.normalized(),
          shooter: gameObject,
        );
      }
    } else {
      state = BotAiState.chase;
      _moveToward(target!.transform.worldPosition, dt);
    }
  }

  void _moveToward(Vector3 goal, double dt) {
    final diff = Vector3(goal.x - transform.worldPosition.x, 0, goal.z - transform.worldPosition.z);
    final dist = diff.length;
    if (dist < 0.2) return;
    final step = math.min(dist, moveSpeed * dt);
    transform.localPosition = transform.localPosition + diff.normalized() * step;
  }

  String get inspectorTitle => 'Enemy Bot AI';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('Target Tag', () => targetTag, (v) => targetTag = v),
        InspectorField.float('Detect Range', () => detectRange, (v) => detectRange = v, min: 4, max: 120),
        InspectorField.float('Attack Range', () => attackRange, (v) => attackRange = v, min: 2, max: 100),
        InspectorField.float('Move Speed', () => moveSpeed, (v) => moveSpeed = v, min: 0.5, max: 20),
      ];
}

/// Loot pickup types for [LootSpawnerComponent].
enum LootType { medkit, ammoPack, shieldPack }

/// Battle Royale loot pickup that grants health, ammo, or shield when the player walks near it.
class LootSpawnerComponent extends Component implements Inspectable {
  LootSpawnerComponent({
    this.lootType = LootType.medkit,
    this.amount = 35.0,
    this.pickupRadius = 2.0,
    this.respawnSeconds = 12.0,
  });

  LootType lootType;
  double amount;
  double pickupRadius;
  double respawnSeconds;

  bool available = true;
  double _respawnTimer = 0.0;

  @override
  void update(double dt) {
    if (!available) {
      _respawnTimer -= dt;
      if (_respawnTimer <= 0) {
        available = true;
      }
      return;
    }
    final scene = gameObject.scene;
    if (scene == null) return;
    scene.forEachActive((go) {
      if (!available || go == gameObject || go.tag != 'Player') return;
      if ((go.transform.worldPosition - transform.worldPosition).length <= pickupRadius) {
        switch (lootType) {
          case LootType.medkit:
            go.getComponent<HealthDamageComponent>()?.heal(amount);
          case LootType.shieldPack:
            go.getComponent<HealthDamageComponent>()?.addShield(amount);
          case LootType.ammoPack:
            final w = go.getComponent<WeaponComponent>();
            if (w != null) w.reserveAmmo += amount.round();
        }
        available = false;
        _respawnTimer = respawnSeconds;
      }
    });
  }

  String get inspectorTitle => 'Loot Spawner';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Amount', () => amount, (v) => amount = v, min: 5, max: 200),
        InspectorField.float('Pickup Radius', () => pickupRadius, (v) => pickupRadius = v, min: 0.5, max: 10),
        InspectorField.float('Respawn Sec', () => respawnSeconds, (v) => respawnSeconds = v, min: 1, max: 120),
      ];
}

/// Shrinking Battle Royale Safe Zone that damages any [HealthDamageComponent] outside [currentRadius].
class SafeZoneComponent extends Component implements Inspectable {
  SafeZoneComponent({
    Vector3? center,
    this.initialRadius = 48.0,
    this.minRadius = 6.0,
    this.shrinkSpeed = 1.4,
    this.damagePerSecond = 8.0,
  }) : center = center?.clone() ?? Vector3.zero(),
       currentRadius = initialRadius;

  Vector3 center;
  double initialRadius;
  double minRadius;
  double shrinkSpeed;
  double damagePerSecond;
  double currentRadius;

  bool isInsideZone(Vector3 pos) {
    final dx = pos.x - center.x;
    final dz = pos.z - center.z;
    return (dx * dx + dz * dz) <= currentRadius * currentRadius;
  }

  @override
  void update(double dt) {
    if (currentRadius > minRadius) {
      currentRadius = math.max(minRadius, currentRadius - shrinkSpeed * dt);
    }
    final scene = gameObject.scene;
    if (scene == null || damagePerSecond <= 0) return;
    scene.forEachActive((go) {
      final hp = go.getComponent<HealthDamageComponent>();
      if (hp == null || hp.isDead) return;
      if (!isInsideZone(go.transform.worldPosition)) {
        hp.takeDamage(damagePerSecond * dt);
      }
    });
  }

  String get inspectorTitle => 'Battle Royale Safe Zone';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Current Radius', () => currentRadius, (v) => currentRadius = v, min: 2, max: 200),
        InspectorField.float('Min Radius', () => minRadius, (v) => minRadius = v, min: 1, max: 100),
        InspectorField.float('Shrink Speed', () => shrinkSpeed, (v) => shrinkSpeed = v, min: 0, max: 20),
        InspectorField.float('Zone DPS', () => damagePerSecond, (v) => damagePerSecond = v, min: 0, max: 100),
      ];
}
