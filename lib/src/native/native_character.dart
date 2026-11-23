import '../math/vec.dart';

import '../engine/game_object.dart';
import 'native_physics.dart';

/// A walking character (player or NPC): a capsule you steer by hand. It
/// walks, jumps, climbs low steps, stands on slopes, crouches, climbs ladders,
/// pushes dynamic bodies and slides along walls.
///
/// The object's position is the **feet**. Put the model's origin at its feet.
class NativeCharacterController extends Component {
  NativeCharacterController(
    this.physics, {
    this.radius = 0.4,
    this.height = 1.8,
    this.crouchHeight = 1.0,
    this.stepHeight = 0.35,
    this.slopeLimitDegrees = 50,
    this.mask = 0xFFFFFFFF,
    this.gravityScale = 1.0,
    double pushForce = 0.0,
    bool climbing = false,
  }) : assert(height >= radius * 2, 'height must be at least 2 * radius'),
       _pushForce = pushForce,
       _climbing = climbing {
    physics.registerCharacter(this);
  }

  final NativePhysics physics;

  /// Capsule size in meters. [height] is the whole capsule.
  final double radius, height;

  /// Capsule height when crouched.
  final double crouchHeight;

  /// Highest step it climbs, in meters.
  final double stepHeight;

  /// Slopes steeper than this (degrees) count as walls.
  final double slopeLimitDegrees;

  /// Layers it collides with.
  final int mask;

  /// 1 uses the physics gravity, 0 turns it off (swimming, flying), 2 doubles it.
  double gravityScale;

  double _pushForce;
  bool _climbing;

  /// Horizontal impulse strength applied to dynamic rigid bodies when walking into them.
  double get pushForce => _pushForce;
  set pushForce(double value) {
    _pushForce = value;
    if (characterId >= 0) physics.world.setCharacterPushForce(characterId, value);
  }

  /// When true, the character climbs vertically (e.g. ladders) without gravity pulling it down.
  bool get climbing => _climbing;
  set climbing(bool value) {
    _climbing = value;
    if (characterId >= 0) physics.world.setCharacterClimbing(characterId, value);
  }

  /// Requests crouch ([crouch] = true) or stand up ([crouch] = false).
  /// Standing up checks ceiling clearance and returns false if blocked.
  bool setCrouch(bool crouch, {double? height}) {
    ensureCreated();
    if (characterId < 0) return false;
    return physics.world.setCharacterCrouch(characterId, crouch, crouchHeight: height ?? crouchHeight);
  }

  /// True while the character capsule is crouched.
  bool get isCrouched {
    if (characterId < 0) return false;
    return physics.world.isCharacterCrouched(characterId);
  }

  /// Where you want to walk, in meters per second. When [climbing] is true,
  /// the y component drives vertical climbing speed.
  Vector3 moveVelocity = Vector3.zero();

  /// Up (+) and down (-) speed in meters per second.
  double verticalVelocity = 0;

  /// Keep the feet on the ground over small drops (stairs and slopes going
  /// down). Switched off by itself while moving upward.
  bool snapToGround = true;

  int characterId = -1;
  bool isGrounded = false;
  bool hitCeiling = false;
  bool hitWall = false;
  Vector3 groundNormal = Vector3(0, 1, 0);

  /// Body id of what it stands on, or -1 (a mesh collider has no object).
  int groundBodyId = -1;

  /// The object it stands on, if that is a [NativeRigidBody].
  GameObject? get groundObject => physics.bodies[groundBodyId]?.gameObject;

  /// Jumps with [speed] meters per second (v*v / 2g high) if it stands on the
  /// ground. Returns false in the air.
  bool jump(double speed) {
    if (!isGrounded) return false;
    verticalVelocity = speed;
    isGrounded = false;
    return true;
  }

  /// Puts the feet at [feet] at once, with no collision.
  void teleport(Vector3 feet) {
    ensureCreated();
    transform.worldPosition = feet;
    verticalVelocity = 0;
    if (characterId >= 0) physics.world.teleportCharacter(characterId, feet);
  }

  /// Ensures the native character capsule exists even before the first `scene.update()`.
  void ensureCreated() {
    if (characterId >= 0 || !isAttached) return;
    characterId = physics.world.createCharacter(
      radius: radius,
      height: height,
      stepHeight: stepHeight,
      slopeLimitDegrees: slopeLimitDegrees,
      mask: mask,
      position: transform.worldPosition,
    );
    if (_pushForce != 0.0) physics.world.setCharacterPushForce(characterId, _pushForce);
    if (_climbing) physics.world.setCharacterClimbing(characterId, true);
    if (!physics.characters.contains(this)) physics.characters.add(this);
  }

  @override
  void awake() => ensureCreated();

  /// Called by [NativePhysics.step]. You do not call this yourself.
  void physicsStep(double dt) {
    ensureCreated();
    if (characterId < 0 || dt <= 0) return;
    double vy;
    if (_climbing) {
      vy = moveVelocity.y != 0.0 ? moveVelocity.y : verticalVelocity;
      verticalVelocity = vy;
    } else {
      verticalVelocity += physics.gravity.y * gravityScale * dt;
      if (isGrounded && verticalVelocity < 0) verticalVelocity = -1.0; // press onto the ground
      vy = verticalVelocity;
    }
    final delta = Vector3(moveVelocity.x * dt, vy * dt, moveVelocity.z * dt);
    physics.world.moveCharacter(
      characterId,
      delta,
      snapToGround: !_climbing && snapToGround && vy <= 0,
    );
    final s = physics.world.characterState(characterId);
    isGrounded = s.grounded;
    hitCeiling = s.hitCeiling;
    hitWall = s.hitWall;
    groundNormal = s.groundNormal;
    groundBodyId = s.groundBody;
    if (!_climbing && isGrounded && verticalVelocity < 0) verticalVelocity = 0;
    if (hitCeiling && verticalVelocity > 0) verticalVelocity = 0;
    transform.worldPosition = s.position;
  }

  @override
  void onDestroy() {
    physics.unregisterCharacter(this);
    if (characterId >= 0) {
      physics.world.destroyCharacter(characterId);
      characterId = -1;
    }
  }
}
