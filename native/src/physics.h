// tej3d physics: our own rigid body engine.
// Shapes: sphere, box. Sequential impulse solver, SAT + clipping for boxes,
// sleeping, layers, sensors (triggers), events and raycasts.
#pragma once
#include <algorithm>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include "tmath.h"
#include "trimesh.h"

namespace tej {

enum class ShapeType : int {
  Sphere = 0,    // half.x is the radius
  Box = 1,       // half is the half size on each axis
  Mesh = 2,      // triangle mesh, static only
  Capsule = 3,   // half.x is the radius, half.y is half the length of the straight part (axis: local Y)
  Compound = 4,  // several shapes in one body: see BodyDesc::children
  ConvexHull = 5, // convex polyhedron: see BodyDesc::hullVerts
};

/// One part of a compound body. Only Sphere, Box and Capsule are allowed here.
struct ChildShape {
  ShapeType shape = ShapeType::Box;
  V3 half{0.5f, 0.5f, 0.5f};
  V3 pos;   // in the local space of the body
  Q rot;
};

struct BodyDesc {
  ShapeType shape = ShapeType::Box;
  V3 half{0.5f, 0.5f, 0.5f};  // box half extents; sphere radius is half.x
  float mass = 1.0f;          // 0 = static
  bool kinematic = false;     // moved by code, pushes dynamic bodies
  bool sensor = false;        // trigger: reports overlaps, no collision response
  V3 pos;
  Q rot;
  float friction = 0.5f;
  float restitution = 0.0f;
  float linearDamping = 0.01f;
  float angularDamping = 0.05f;
  uint32_t layer = 0;           // 0..31
  uint32_t mask = 0xFFFFFFFFu;  // layers this body collides with
  float gravityScale = 1.0f;
  bool ccd = false;             // continuous collision detection for fast bodies
  int triMesh = -1;             // for ShapeType::Mesh: id from createTriMesh
  std::vector<ChildShape> children;  // for ShapeType::Compound
  std::vector<V3> hullVerts;         // for ShapeType::ConvexHull (local space)
};

struct Body {
  bool alive = false;
  BodyDesc d;
  V3 pos, linVel, angVel, force, torque;
  Q rot;
  float invMass = 0;
  V3 invInertiaLocal;
  float sleepTimer = 0;
  bool sleeping = false;
  bool isStatic() const { return invMass == 0 && !d.kinematic; }
  bool isDynamic() const { return invMass > 0; }
};

struct RayHit {
  int body = -1;
  float t = 0;
  V3 point, normal;
};

struct SphereHit {
  V3 push;       // unit direction that moves the sphere out of the body
  float depth;   // how far it is inside, in meters
  int body;
};

enum class JointType { Ball, Fixed, Hinge, Rope, Spring, Slider, ConeTwist };

/// Connects two bodies (or a body and the world).
///  - Ball:   the anchors stay together; the bodies can turn freely (shoulder, chain link, pendulum).
///  - Fixed:  the anchors stay together and the bodies cannot turn against each other (glue).
///  - Hinge:  like Ball, and the bodies can only turn around one axis (door, wheel, lever).
///            Optional angle limits and a motor.
///  - Rope:   the anchors are kept between minLen and maxLen apart (rope, leash, chain limit).
///  - Spring: pulls the anchors to restLen with a soft spring (suspension, bungee).
/// A body id of -1 means the world: the anchor on that side is a world position.
struct JointDesc {
  JointType type = JointType::Ball;
  int a = -1, b = -1;
  V3 anchorA, anchorB;          // local to each body (a world position for the world side)
  V3 axis{0, 1, 0};             // Hinge: the turning axis, in the local space of A (world if a is the world)
  bool limit = false;           // Hinge: keep the angle between lower and upper (radians)
  float lower = 0, upper = 0;
  float motorSpeed = 0;         // Hinge: wanted turning speed of A relative to B, in rad/s
  float motorMaxTorque = 0;     // Hinge: 0 = motor off
  float minLen = 0, maxLen = 1; // Rope
  float restLen = 1, hz = 4, damping = 0.5f;  // Spring: frequency in Hz, damping ratio 0..1
  float breakForce = 0;         // above this force (newtons) the joint breaks; 0 = never
  bool collideConnected = false;  // may the two bodies collide with each other?
};

// One scalar constraint of a joint (a direction the two bodies may not move along).
struct JointRow {
  int a = -1, b = -1, joint = -1;
  bool angular = false;
  bool isForce = false;     // counts for the break force (linear rows that hold the anchors together)
  V3 dir, rA, rB;
  float mass = 0, target = 0, gamma = 0, imp = 0;
  float lo = -1e30f, hi = 1e30f;
  // Block row: the three directions x, y, z solved together (a point that must stay put).
  bool block = false;
  float kinv[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};  // inverse effective mass, row major
  V3 impV, targetV;
};

// A simple shape a capsule or compound is made of.
struct Prim { ShapeType shape; V3 half; V3 pos; Q rot; };

struct Event {
  int a, b;
  int type;     // 0 = begin, 1 = end
  int sensor;   // 1 if one side was a sensor (trigger event)
};

class PhysicsWorld {
 public:
  V3 gravity{0, -9.81f, 0};
  int solverIterations = 14;
  bool sleepingEnabled = true;

  int createTriMesh(const float* xyz, int vertexCount, const uint32_t* indices, int indexCount);
  int createBody(const BodyDesc& d);
  void destroyBody(int id);
  // Compound bodies: set the parts (and the inertia that follows from them). The body origin is taken as its
  // center of mass. Returns false if a part has a shape that is not allowed.
  bool setChildren(int id, const std::vector<ChildShape>& parts);
  bool setConvexHull(int id, const V3* verts, int count);
  Body* body(int id) { return (id >= 0 && id < (int)bodies_.size() && bodies_[id].alive) ? &bodies_[id] : nullptr; }
  int bodyCount() const { return aliveCount_; }

  void setTransform(int id, const V3& p, const Q& q);
  void applyForce(int id, const V3& f);
  void applyImpulse(int id, const V3& impulse, const V3& worldPoint);
  void wake(int id);
  void setCcd(int id, bool enabled) { if (auto* b = body(id)) b->d.ccd = enabled; }

  void step(float dt);
  // ---- joints
  int createJoint(const JointDesc& d);      // returns an id, or -1 if the bodies do not exist
  void destroyJoint(int id);
  bool jointAlive(int id) const { return id >= 0 && id < (int)joints_.size() && joints_[id].alive; }
  bool jointBroken(int id) const { return id >= 0 && id < (int)joints_.size() && joints_[id].broken; }
  void setJointMotor(int id, float speed, float maxTorque) { if (id >= 0 && id < (int)joints_.size()) { joints_[id].d.motorSpeed = speed; joints_[id].d.motorMaxTorque = maxTorque; } }
  void setJointLimits(int id, bool on, float lower, float upper) { if (id >= 0 && id < (int)joints_.size()) { joints_[id].d.limit = on; joints_[id].d.lower = lower; joints_[id].d.upper = upper; } }
  float jointAngle(int id) const;           // Hinge: how far A is turned relative to B, in radians (-pi..pi), 0 at creation
  float jointForce(int id) const { return id >= 0 && id < (int)joints_.size() ? joints_[id].lastForce : 0.0f; }
  int jointCount() const { int n = 0; for (auto& j : joints_) if (j.alive) n++; return n; }

  bool raycast(const V3& o, const V3& dir, float maxDist, uint32_t mask, int ignore, RayHit& hit);
  // Which bodies a sphere at [c] with radius [r] is inside (not sensors). Fills
  // [out] (up to [maxOut]) and returns how many. Uses the same shape tests as
  // the solver, so spheres, boxes and triangle meshes all work.
  int overlapSphere(const V3& c, float r, uint32_t mask, int ignore, SphereHit* out, int maxOut);

  const std::vector<Event>& events() const { return events_; }
  int contactCount() const { return lastContacts_; }
  int awakeCount() const;


 private:
  struct Contact {
    V3 p;
    float depth;
  };
  struct Manifold {
    int a, b, n = 0;
    V3 normal;  // from a to b
    Contact c[8];
  };
  struct Solved {
    int a, b;
    V3 rA, rB, n, t1, t2;
    float mN, mT1, mT2, target, jn = 0, jt1 = 0, jt2 = 0, mu;
  };
  struct Joint {
    bool alive = false, broken = false;
    JointDesc d;
    int bodyA = -1, bodyB = -1;      // real body ids (the world is a hidden static body)
    V3 axisA, axisB, refA, refB;     // hinge axes and zero angle directions, local to each body
    Q rel;                           // Fixed: wanted relative orientation
    float lastForce = 0;
  };
  static uint64_t pairKey(int a, int b) {
    return ((uint64_t)std::min(a, b) << 32) | (uint32_t)std::max(a, b);
  }
  void addNoCollide(int a, int b) {
    if (a < 0 || b < 0) return;
    noCollide_[pairKey(a, b)]++;
  }
  void removeNoCollide(int a, int b) {
    if (a < 0 || b < 0) return;
    auto it = noCollide_.find(pairKey(a, b));
    if (it != noCollide_.end()) {
      if (--it->second <= 0) noCollide_.erase(it);
    }
  }
  std::vector<Joint> joints_;
  std::unordered_map<uint64_t, int> noCollide_;  // ref-counted body pairs joined with collideConnected = false
  int worldBody_ = -1;
  void prepareJoints(float dt, std::vector<struct JointRow>& rows);
  void solveRow(struct JointRow& r);
  std::vector<Body> bodies_;
  std::vector<int> freeList_;
  std::vector<Event> events_;
  std::unordered_set<uint64_t> touching_;
  std::vector<std::pair<float, int>> sap_;
  int aliveCount_ = 0, lastContacts_ = 0;

  bool collide(int a, int b, Manifold& m);
  bool collideBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const;
  bool collideMeshBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const;
  bool collideCompositeBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const;
  void primitivesOfBody(const Body& b, std::vector<Prim>& out) const;
  bool rayTriMesh(const Body& b, const V3& o, const V3& d, float maxT, float& t, V3& n) const;
  std::vector<TriMesh> triMeshes_;
  float stepDt_ = 1.0f / 60.0f;  // length of the step being solved
  static V3 velAt(const Body& b, const V3& p) { return b.linVel + cross(b.angVel, p - b.pos); }
  V3 mulInvI(const Body& b, const V3& v) const;
  void aabb(const Body& b, V3& lo, V3& hi) const;
};

}  // namespace tej
