#include "anim.h"

#include <algorithm>
#include <cmath>

namespace tej {

void Skeleton::finalize() {
  int n = count();
  std::vector<M4> model(n);
  invBindModel.resize(n);
  for (int i = 0; i < n; i++) {
    M4 local = trs(bind[i].t, bind[i].r, bind[i].s);
    model[i] = parent[i] >= 0 ? model[parent[i]] * local : local;
    invBindModel[i] = inverseAffine(model[i]);
  }
}

template <typename T, typename L>
static bool sampleChannel(const Channel<T>& c, float time, T& out, L lerpFn) {
  size_t n = c.times.size();
  if (n == 0 || c.values.size() < n) return false;
  if (!std::isfinite(time) || n == 1 || time <= c.times.front()) { out = c.values.front(); return true; }
  if (time >= c.times.back()) { out = c.values.back(); return true; }
  size_t hi = (size_t)(std::upper_bound(c.times.begin(), c.times.end(), time) - c.times.begin());
  if (hi == 0) { out = c.values.front(); return true; }
  if (hi >= n) { out = c.values.back(); return true; }
  size_t lo = hi - 1;
  float span = c.times[hi] - c.times[lo];
  float f = span > 1e-9f ? (time - c.times[lo]) / span : 0.0f;
  out = lerpFn(c.values[lo], c.values[hi], f);
  return true;
}

void Clip::sample(float time, const Skeleton& sk, std::vector<Xform>& out) const {
  int n = sk.count();
  out.resize(n);
  for (int i = 0; i < n; i++) {
    Xform x = sk.bind[i];
    if (i < (int)tracks.size()) {
      const JointTrack& tr = tracks[i];
      sampleChannel<V3>(tr.t, time, x.t, [](const V3& a, const V3& b, float f) { return lerp(a, b, f); });
      sampleChannel<Q>(tr.r, time, x.r, [](const Q& a, const Q& b, float f) { return slerp(a, b, f); });
      sampleChannel<V3>(tr.s, time, x.s, [](const V3& a, const V3& b, float f) { return lerp(a, b, f); });
    }
    out[i] = x;
  }
}

void Animator::advance(AnimState& s, float dt) {
  if (!s.clip || !std::isfinite(dt)) return;
  if (!std::isfinite(s.time)) s.time = 0.0f;
  s.time += dt * s.speed;
  float d = s.clip->duration;
  if (!std::isfinite(s.time)) { s.time = 0.0f; return; }
  if (s.loop && d > 0) {
    s.time = std::fmod(s.time, d);
    if (s.time < 0) s.time += d;
  } else s.time = std::max(0.0f, std::min(d, s.time));
}

void Animator::play(const Clip* c, bool loop, float speed) {
  cur_ = {c, 0, speed, loop};
  prev_ = AnimState();
  fade_ = fadeDur_ = 0;
}

void Animator::crossfade(const Clip* c, float seconds, bool loop, float speed) {
  if (!cur_.clip || seconds <= 0) { play(c, loop, speed); return; }
  prev_ = cur_;
  cur_ = {c, 0, speed, loop};
  fade_ = 0;
  fadeDur_ = seconds;
}

void Animator::update(float dt) {
  if (!skeleton) return;
  advance(cur_, dt);
  if (cur_.clip) cur_.clip->sample(cur_.time, *skeleton, pose_);
  else pose_ = skeleton->bind;
  if (prev_.clip && fadeDur_ > 0) {
    advance(prev_, dt);
    fade_ += dt;
    float w = std::min(1.0f, fade_ / fadeDur_);
    prev_.clip->sample(prev_.time, *skeleton, tmp_);
    for (size_t i = 0; i < pose_.size(); i++) {
      pose_[i].t = lerp(tmp_[i].t, pose_[i].t, w);
      pose_[i].r = slerp(tmp_[i].r, pose_[i].r, w);
      pose_[i].s = lerp(tmp_[i].s, pose_[i].s, w);
    }
    if (w >= 1) { prev_ = AnimState(); fadeDur_ = 0; }
  }
}

void Animator::modelMatrices(std::vector<M4>& out) const {
  int n = (int)pose_.size();
  out.resize(n);
  for (int i = 0; i < n; i++) {
    M4 local = trs(pose_[i].t, pose_[i].r, pose_[i].s);
    out[i] = skeleton->parent[i] >= 0 ? out[skeleton->parent[i]] * local : local;
  }
}

void Animator::skinMatrices(std::vector<float>& out) const {
  std::vector<M4> model;
  modelMatrices(model);
  out.resize(model.size() * 16);
  for (size_t i = 0; i < model.size(); i++) {
    M4 s = model[i] * skeleton->invBindModel[i];
    for (int k = 0; k < 16; k++) out[i * 16 + k] = s.m[k];
  }
}

float Animator::normalizedTime() const {
  return (cur_.clip && cur_.clip->duration > 0) ? cur_.time / cur_.clip->duration : 0.0f;
}

}  // namespace tej
