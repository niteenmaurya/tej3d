#include "character.h"

#include <algorithm>
#include <cmath>

namespace tej {

namespace {
const int kMaxHits = 16;
float cosSlope(const CharacterDesc& d) { return std::cos(d.slopeLimitDeg * 3.14159265f / 180.0f); }
}  // namespace

// Pushes the capsule (feet at p) out of everything it overlaps. The capsule is
// tested as a row of spheres from the bottom to the top.
Character::Contacts Character::depenetrate(PhysicsWorld& w, V3& p, bool ride, bool pushBodies) const {
  Contacts c;
  const float r = d.radius;
  const float axis = std::max(0.0f, d.height - 2 * r);
  const int samples = std::max(2, (int)std::ceil(axis / (r * 0.9f)) + 1);
  const float cs = cosSlope(d);
  SphereHit hits[kMaxHits];
  for (int iter = 0; iter < 6; iter++) {
    bool moved = false;
    for (int s = 0; s < samples; s++) {
      float t = samples == 1 ? 0.0f : (float)s / (samples - 1);
      V3 center = p + V3(0, r + axis * t, 0);
      int n = w.overlapSphere(center, r, d.mask, d.ignoreBody, hits, kMaxHits);
      for (int i = 0; i < n; i++) {
        const SphereHit& h = hits[i];
        const V3& pu = h.push;
        if (pu.y >= cs) {
          p.y += h.depth / std::max(pu.y, 0.3f);
          if (!c.ground || pu.y > c.groundNormal.y) { c.groundNormal = pu; c.groundBody = h.body; }
          c.ground = true;
        } else if (pu.y <= -0.5f) {
          p = p + pu * h.depth;
          c.ceiling = true;
        } else if (ride && pu.y > 0.1f) {
          V3 hp(pu.x, 0, pu.z);
          float hl = len(hp);
          bool onWalkableLip = false;
          if (hl > 1e-4f) {
            V3 contactPt = center - pu * r;
            V3 inward = hp * (-1.0f / hl);
            RayHit lip;
            if (w.raycast(contactPt + inward * 0.03f + V3(0, 0.08f, 0), V3(0, -1, 0), 0.16f, d.mask, d.ignoreBody, lip) &&
                lip.normal.y >= cs) {
              onWalkableLip = true;
            }
          }
          if (onWalkableLip) {
            p.y += h.depth / std::max(pu.y, 0.3f);
            if (!c.ground || pu.y > c.groundNormal.y) { c.groundNormal = V3(0, 1, 0); c.groundBody = h.body; }
            c.ground = true;
          } else if (hl > 1e-4f) {
            p = p + hp * (h.depth / std::max(hl, 0.3f) / hl);
            c.wall = true;
          }
        } else {
          V3 hp(pu.x, 0, pu.z);
          float hl = len(hp);
          if (hl > 1e-4f) {
            if (pushBodies && pushForce > 0.0f && iter == 0) {
              if (Body* b = w.body(h.body)) {
                if (b->isDynamic()) {
                  V3 pushDir = hp * (-1.0f / hl);
                  V3 contactPt = center - pu * r;
                  w.applyImpulse(h.body, pushDir * (pushForce * std::min(1.0f, h.depth * 10.0f + 0.25f)), contactPt);
                }
              }
            }
            p = p + hp * (h.depth / std::max(hl, 0.3f) / hl);
            c.wall = true;
          }
        }
        moved = true;
      }
    }
    if (!moved) break;
  }
  return c;
}

bool Character::setCrouch(PhysicsWorld& w, bool wantCrouch, float crouchHeight) {
  const float minH = d.radius * 2.0f + 0.05f;
  if (!crouched && standingHeight < d.height) standingHeight = d.height;
  if (wantCrouch) {
    if (!crouched) standingHeight = d.height;
    d.height = std::max(minH, std::min(crouchHeight, standingHeight));
    crouched = true;
    return true;
  }
  if (!crouched) return true;
  // Check ceiling clearance before standing back up.
  const float r = d.radius;
  const float targetAxis = std::max(0.0f, standingHeight - 2 * r);
  const float curAxis = std::max(0.0f, d.height - 2 * r);
  SphereHit hits[kMaxHits];
  for (int i = 1; i <= 3; i++) {
    float frac = (float)i / 3.0f;
    float y = curAxis + (targetAxis - curAxis) * frac;
    V3 center = pos + V3(0, r + y, 0);
    int n = w.overlapSphere(center, r * 0.95f, d.mask, d.ignoreBody, hits, kMaxHits);
    for (int k = 0; k < n; k++) {
      if (hits[k].depth > 1e-3f) return false;  // blocked by ceiling
    }
  }
  d.height = standingHeight;
  crouched = false;
  return true;
}

void Character::probeGround(PhysicsWorld& w) {
  const float cs = cosSlope(d);
  SphereHit hits[kMaxHits];
  const float probe = 0.06f;
  int n = w.overlapSphere(pos + V3(0, d.radius - probe, 0), d.radius, d.mask, d.ignoreBody, hits, kMaxHits);
  grounded = false;
  groundBody = -1;
  groundNormal = V3(0, 1, 0);
  for (int i = 0; i < n; i++) {
    if (hits[i].push.y >= cs && (!grounded || hits[i].push.y > groundNormal.y)) {
      grounded = true;
      groundNormal = hits[i].push;
      groundBody = hits[i].body;
    } else if (!grounded && hits[i].push.y > 0.1f) {
      V3 hp(hits[i].push.x, 0, hits[i].push.z);
      float hl = len(hp);
      if (hl > 1e-4f) {
        V3 center = pos + V3(0, d.radius - probe, 0);
        V3 contactPt = center - hits[i].push * d.radius;
        V3 inward = hp * (-1.0f / hl);
        RayHit lip;
        if (w.raycast(contactPt + inward * 0.03f + V3(0, 0.08f, 0), V3(0, -1, 0), 0.16f, d.mask, d.ignoreBody, lip) &&
            lip.normal.y >= cs) {
          grounded = true;
          groundNormal = lip.normal;
          groundBody = hits[i].body;
        }
      }
    }
  }
}

float Character::moveVertical(PhysicsWorld& w, float dy) {
  if (dy == 0) return 0;
  const float startY = pos.y;
  int steps = std::max(1, (int)std::ceil(std::fabs(dy) / (d.radius * 0.5f)));
  float dyStep = dy / steps;
  for (int i = 0; i < steps; i++) {
    pos.y += dyStep;
    Contacts c = depenetrate(w, pos, true);
    if (dy > 0 && c.ceiling) { hitCeiling = true; break; }
    if (dy < 0 && c.ground) break;
  }
  return pos.y - startY;
}

void Character::moveHorizontal(PhysicsWorld& w, V3 h) {
  float dist = len(h);
  if (dist < 1e-6f) return;
  int steps = std::max(1, (int)std::ceil(dist / (d.radius * 0.5f)));
  V3 hs = h * (1.0f / steps);
  for (int i = 0; i < steps; i++) {
    V3 before = pos;
    V3 a = pos + hs;
    Contacts ca = depenetrate(w, a, false, true);
    const bool blocked = ca.wall;
    if (blocked && grounded && d.stepHeight > 0 && !climbing) {
      V3 b = before + V3(0, d.stepHeight, 0);
      Contacts up = depenetrate(w, b);
      if (!up.ceiling && std::fabs(b.y - (before.y + d.stepHeight)) < 1e-3f) {
        V3 b2 = b + hs, b3 = b2;
        depenetrate(w, b3);
        if (len(b3 - b2) < 1e-3f) {
          // Confirm there is a walkable surface (normal.y >= cosSlope) ahead, not a steep ramp.
          float hLen = len(hs);
          V3 hDir = hLen > 1e-6f ? hs * (1.0f / hLen) : V3(0, 0, 0);
          RayHit tread;
          V3 rayOrigin = before + V3(0, d.stepHeight + 0.05f, 0) + hDir * (d.radius + 0.05f);
          bool hasWalkableTread =
              w.raycast(rayOrigin, V3(0, -1, 0), d.stepHeight + 0.08f, d.mask, d.ignoreBody, tread) &&
              tread.normal.y >= cosSlope(d) &&
              tread.point.y > before.y + 1e-3f &&
              tread.point.y <= before.y + d.stepHeight + 0.02f;
          if (!hasWalkableTread) {
            V3 rayOrigin2 = b2 + V3(0, 0.05f, 0);
            hasWalkableTread =
                w.raycast(rayOrigin2, V3(0, -1, 0), d.stepHeight + 0.08f, d.mask, d.ignoreBody, tread) &&
                tread.normal.y >= cosSlope(d) &&
                tread.point.y > before.y + 1e-3f &&
                tread.point.y <= before.y + d.stepHeight + 0.02f;
          }
          if (hasWalkableTread) {
            // Settle down onto the step lip/tread so probeGround finds real ground support.
            V3 down = b3;
            float drop = std::max(0.0f, b3.y - before.y);
            int dsteps = std::max(1, (int)std::ceil(drop / (d.radius * 0.25f)));
            float ddy = drop / dsteps;
            for (int k = 0; k < dsteps; k++) {
              down.y -= ddy;
              Contacts dc = depenetrate(w, down, true);
              if (dc.ground) break;
            }
            pos = down;
            stepping_ = true;
            continue;
          }
        }
      }
    }
    if (ca.wall) hitWall = true;
    stepping_ = false;
    pos = a;
  }
}

void Character::move(PhysicsWorld& w, const V3& delta, bool snapToGround) {
  hitCeiling = false;
  hitWall = false;
  stepping_ = false;

  // Carry character with moving ground platform if still standing on it.
  if (grounded && groundBody >= 0 && groundBody == lastGroundBody_) {
    if (Body* gb = w.body(groundBody)) {
      V3 platDelta = gb->pos - lastGroundPos_;
      if (len2(platDelta) > 1e-10f) {
        pos = pos + platDelta;
      }
    }
  }

  depenetrate(w, pos);
  const bool wasGrounded = grounded;

  moveHorizontal(w, V3(delta.x, 0, delta.z));

  float dy = delta.y;
  if (climbing) {
    moveVertical(w, dy);
  } else if (dy > 0) {
    moveVertical(w, dy);
  } else if (stepping_) {
    // Climbing a step: do not pull back down.
  } else {
    float allowed = dy;
    const bool snap = snapToGround && wasGrounded && dy > -d.stepHeight;
    if (snap) allowed = -(d.stepHeight + 0.02f);
    float before = pos.y;
    float moved = moveVertical(w, allowed);
    if (snap && moved <= -(d.stepHeight + 0.01f)) {
      pos.y = before + dy;
    }
  }
  probeGround(w);

  if (grounded && groundBody >= 0) {
    if (Body* gb = w.body(groundBody)) {
      lastGroundBody_ = groundBody;
      lastGroundPos_ = gb->pos;
    }
  } else {
    lastGroundBody_ = -1;
  }
}

}  // namespace tej
