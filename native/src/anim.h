// tej3d animation: skeletons, keyframe clips, crossfade animator, skinning matrices.
#pragma once
#include <vector>
#include "tmath.h"

namespace tej {

struct Xform {
  V3 t;
  Q r;
  V3 s{1, 1, 1};
};

struct Skeleton {
  std::vector<int> parent;      // parent[i] < i, -1 for roots
  std::vector<Xform> bind;      // local bind pose
  std::vector<M4> invBindModel; // inverse of model space bind pose
  void finalize();              // computes invBindModel
  int count() const { return (int)parent.size(); }
};

template <typename T>
struct Channel {
  std::vector<float> times;
  std::vector<T> values;
  bool empty() const { return times.empty(); }
};

struct JointTrack {
  Channel<V3> t, s;
  Channel<Q> r;
};

struct Clip {
  float duration = 1;
  std::vector<JointTrack> tracks;  // one per joint
  void sample(float time, const Skeleton& sk, std::vector<Xform>& out) const;
};

struct AnimState {
  const Clip* clip = nullptr;
  float time = 0, speed = 1;
  bool loop = true;
};

class Animator {
 public:
  const Skeleton* skeleton = nullptr;
  void play(const Clip* c, bool loop, float speed);
  void crossfade(const Clip* c, float seconds, bool loop, float speed);
  void update(float dt);
  const std::vector<Xform>& pose() const { return pose_; }
  // Fills 16 floats per joint (column major) = model * inverseBind.
  void skinMatrices(std::vector<float>& out) const;
  void modelMatrices(std::vector<M4>& out) const;
  float normalizedTime() const;
  bool finished() const {
    if (!cur_.clip || cur_.loop) return false;
    return cur_.speed < 0.0f ? cur_.time <= 0.0f : cur_.time >= cur_.clip->duration;
  }

 private:
  AnimState cur_, prev_;
  float fade_ = 0, fadeDur_ = 0;
  std::vector<Xform> pose_, tmp_;
  static void advance(AnimState& s, float dt);
};

}  // namespace tej
