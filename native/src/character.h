// tej3d character controller: a capsule that you move by hand (walk, run,
// jump, climb stairs, stand on slopes, push dynamic bodies, ride moving
// platforms, crouch with ceiling clearance, climb ladders).
#pragma once
#include <cstdint>
#include "physics.h"
#include "tmath.h"

namespace tej {

struct CharacterDesc {
  float radius = 0.4f;
  float height = 1.8f;           // whole capsule, at least 2 * radius
  float stepHeight = 0.35f;      // highest step it climbs
  float slopeLimitDeg = 50.0f;   // steeper than this counts as a wall
  uint32_t mask = 0xFFFFFFFFu;   // layers it collides with
  int ignoreBody = -1;           // a body to skip (for example its own)
};

struct Character {
  bool alive = false;
  CharacterDesc d;
  V3 pos;                        // feet, bottom of the capsule
  bool grounded = false;         // standing on something walkable
  bool hitCeiling = false;       // last move bumped its head
  bool hitWall = false;          // last move touched a wall
  V3 groundNormal{0, 1, 0};
  int groundBody = -1;

  // Extras:
  float pushForce = 5.0f;        // impulse strength applied when pushing dynamic bodies
  bool crouched = false;
  float standingHeight = 1.8f;
  bool climbing = false;         // ladder/swim mode: disables slope blocking & ground snap

  // Moves by [delta] (world meters, include the vertical part) with collision.
  void move(PhysicsWorld& w, const V3& delta, bool snapToGround);

  // Toggles crouch. When standing up, checks ceiling clearance first.
  // Returns true if crouched state matches [wantCrouch].
  bool setCrouch(PhysicsWorld& w, bool wantCrouch, float crouchHeight);

  // Puts it somewhere without collision (spawn, teleport).
  void teleport(const V3& feet) {
    pos = feet;
    grounded = false;
    groundBody = -1;
    lastGroundBody_ = -1;
  }

 private:
  struct Contacts {
    bool ground = false, ceiling = false, wall = false;
    V3 groundNormal{0, 1, 0};
    int groundBody = -1;
  };
  Contacts depenetrate(PhysicsWorld& w, V3& p, bool ride = false, bool pushBodies = false) const;
  bool stepping_ = false;
  int lastGroundBody_ = -1;
  V3 lastGroundPos_;
  void probeGround(PhysicsWorld& w);
  void moveHorizontal(PhysicsWorld& w, V3 h);
  float moveVertical(PhysicsWorld& w, float dy);
};

}  // namespace tej
