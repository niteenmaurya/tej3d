import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';

import '../editor/inspector.dart';
import 'game_object.dart';

/// Where new particles start.
enum EmitterShape {
  /// All from one point.
  point,

  /// Inside a sphere of [ParticleSystem.shapeSize] radius.
  sphere,

  /// Inside a box of half size [ParticleSystem.shapeSize] on every side.
  box,
}

/// How a particle looks.
enum ParticleShape {
  /// Round with soft edges (smoke, glow).
  soft,

  /// Round with a sharp edge (dots, sparks).
  round,

  /// A square.
  square,
}

/// A color at a moment of the particle life (0 = born, 1 = dies).
class ColorStop {
  const ColorStop(this.time, this.color);
  final double time;
  final Vector4 color;
}

/// The sprites to draw this frame, in the format of the native renderer.
class ParticleBatch {
  Float32List _data = Float32List(9 * 256);
  int count = 0;

  void add(double x, double y, double z, double size, double r, double g, double b, double a, int flags) {
    if ((count + 1) * 9 > _data.length) {
      final bigger = Float32List(_data.length * 2)..setAll(0, _data);
      _data = bigger;
    }
    final i = count * 9;
    _data[i] = x;
    _data[i + 1] = y;
    _data[i + 2] = z;
    _data[i + 3] = size;
    _data[i + 4] = r;
    _data[i + 5] = g;
    _data[i + 6] = b;
    _data[i + 7] = a;
    _data[i + 8] = flags.toDouble();
    count++;
  }

  /// 9 numbers per sprite: x y z size r g b a flags.
  Float32List toFloats() => Float32List.sublistView(_data, 0, count * 9);

  void clear() => count = 0;
}

/// Makes many small camera facing sprites: smoke, fire, sparks, dust, rain.
///
/// ```dart
/// final fire = GameObject('Fire')..addComponent(ParticleSystem(
///   emissionRate: 60, lifetime: (0.6, 1.2), speed: (1, 2.5), coneAngleDegrees: 15,
///   gravity: Vector3(0, 1.5, 0),                         // rises
///   startSize: 0.5, endSize: 0.05, additive: true,
///   colors: [ColorStop(0, Vector4(1, 0.9, 0.4, 1)), ColorStop(1, Vector4(0.8, 0.1, 0, 0))]));
/// ```
///
/// The native renderer draws them (the plain Dart renderer does not). A
/// particle never hides behind another one wrongly (they are sorted), but they
/// do not cast shadows. Particles are drawn as round or square sprites; there
/// is no texture support yet.
class ParticleSystem extends Component implements Inspectable {
  ParticleSystem({
    this.maxParticles = 1000,
    this.emissionRate = 20,
    this.lifetime = (1.0, 1.0),
    this.speed = (1.0, 1.0),
    this.coneAngleDegrees = 0,
    this.shape = EmitterShape.point,
    this.shapeSize = 0.5,
    Vector3? gravity,
    this.drag = 0,
    this.startSize = 0.2,
    this.endSize = 0.2,
    List<ColorStop>? colors,
    this.additive = false,
    this.particleShape = ParticleShape.soft,
    this.localSpace = false,
    this.loop = true,
    this.duration = 5,
    this.playOnAwake = true,
    this.seed = 1,
  })  : gravity = gravity ?? Vector3(0, -9.81, 0),
        colors = colors ?? [ColorStop(0, Vector4(1, 1, 1, 1)), ColorStop(1, Vector4(1, 1, 1, 1))],
        _rng = math.Random(seed),
        _cap = maxParticles {
    _alloc(maxParticles);
  }

  static final Vector4 _white = Vector4(1, 1, 1, 1);

  /// Most particles alive at the same time.
  final int maxParticles;

  /// New particles per second.
  double emissionRate;

  /// Life of a new particle in seconds, a random value between the two.
  (double, double) lifetime;

  /// Start speed in meters per second, random between the two.
  (double, double) speed;

  /// 0: straight along the object's up direction (+Y). 180: all directions.
  double coneAngleDegrees;

  EmitterShape shape;
  double shapeSize;

  /// Acceleration in m/s squared (default gravity). A positive Y lets smoke rise.
  Vector3 gravity;

  /// Slows particles down: 1 loses about 63% of the speed each second.
  double drag;

  /// Size (width in meters) at birth and at death.
  double startSize, endSize;

  /// Color and see-through at points of the life.
  List<ColorStop> colors;

  /// Adds light instead of covering (fire, sparks, glow).
  bool additive;
  ParticleShape particleShape;

  /// True: particles move with the object. False: they stay where they were born.
  bool localSpace;

  /// Emit again after [duration] seconds.
  bool loop;
  double duration;
  bool playOnAwake;
  final int seed;

  final math.Random _rng;
  final int _cap;
  late Float32List _px, _py, _pz, _vx, _vy, _vz, _age, _life;
  int _n = 0;
  double _carry = 0;
  double _time = 0;
  bool _playing = false;

  void _alloc(int n) {
    _px = Float32List(n);
    _py = Float32List(n);
    _pz = Float32List(n);
    _vx = Float32List(n);
    _vy = Float32List(n);
    _vz = Float32List(n);
    _age = Float32List(n);
    _life = Float32List(n);
  }

  /// Number of particles alive.
  int get aliveCount => _n;

  bool get isPlaying => _playing;

  /// Starts emitting.
  void play() {
    _playing = true;
    _time = 0;
  }

  /// Stops emitting. Particles that are alive finish their life.
  void stop() => _playing = false;

  /// Removes all particles at once.
  void clear() {
    _n = 0;
    _carry = 0;
  }

  /// Makes [count] particles right now.
  void burst(int count) {
    for (var i = 0; i < count; i++) {
      _spawn();
    }
  }

  @override
  void awake() {
    if (playOnAwake) play();
  }

  @override
  void update(double dt) {
    if (dt <= 0) return;
    final emitterPos = transform.worldPosition;
    // age, move and remove
    final g = localSpace ? _rotate(transform.worldRotation.inverted(), gravity) : gravity;
    final dragF = drag > 0 ? math.exp(-drag * dt) : 1.0;
    var i = 0;
    while (i < _n) {
      _age[i] += dt;
      if (_age[i] >= _life[i]) {
        _n--;
        _copy(_n, i);
        continue;
      }
      _vx[i] = (_vx[i] + g.x * dt) * dragF;
      _vy[i] = (_vy[i] + g.y * dt) * dragF;
      _vz[i] = (_vz[i] + g.z * dt) * dragF;
      _px[i] += _vx[i] * dt;
      _py[i] += _vy[i] * dt;
      _pz[i] += _vz[i] * dt;
      i++;
    }
    // emit
    if (_playing) {
      _time += dt;
      if (!loop && _time > duration) {
        _playing = false;
      } else {
        if (loop && _time > duration) _time -= duration;
        _carry += emissionRate * dt;
        final whole = _carry.floor();
        _carry -= whole;
        for (var k = 0; k < whole; k++) {
          // spread the births over the frame so they do not all sit at the same spot
          final age = dt * (whole - k - 1) / whole;
          final before = _n;
          _spawn(emitterPos);
          if (_n > before) {
            final j = _n - 1;
            _px[j] += _vx[j] * age;
            _py[j] += _vy[j] * age;
            _pz[j] += _vz[j] * age;
            _age[j] = age;
          }
        }
      }
    }
  }

  void _copy(int from, int to) {
    if (from == to) return;
    _px[to] = _px[from];
    _py[to] = _py[from];
    _pz[to] = _pz[from];
    _vx[to] = _vx[from];
    _vy[to] = _vy[from];
    _vz[to] = _vz[from];
    _age[to] = _age[from];
    _life[to] = _life[from];
  }

  double _between((double, double) r) => r.$1 + (r.$2 - r.$1) * _rng.nextDouble();

  void _spawn([Vector3? emitterPos]) {
    if (_n >= _cap) return;
    // position and direction in the object's own space
    var lx = 0.0, ly = 0.0, lz = 0.0;
    switch (shape) {
      case EmitterShape.point:
        break;
      case EmitterShape.sphere:
        // uniform inside a sphere
        double x, y, z;
        do {
          x = _rng.nextDouble() * 2 - 1;
          y = _rng.nextDouble() * 2 - 1;
          z = _rng.nextDouble() * 2 - 1;
        } while (x * x + y * y + z * z > 1);
        lx = x * shapeSize;
        ly = y * shapeSize;
        lz = z * shapeSize;
      case EmitterShape.box:
        lx = (_rng.nextDouble() * 2 - 1) * shapeSize;
        ly = (_rng.nextDouble() * 2 - 1) * shapeSize;
        lz = (_rng.nextDouble() * 2 - 1) * shapeSize;
    }
    final half = coneAngleDegrees.clamp(0.0, 180.0) * math.pi / 180.0;
    // random direction in a cone around +Y (uniform on the cap of the sphere)
    final cosMax = math.cos(half);
    final cosT = 1 - _rng.nextDouble() * (1 - cosMax);
    final sinT = math.sqrt(math.max(0.0, 1 - cosT * cosT));
    final phi = _rng.nextDouble() * 2 * math.pi;
    final dirLocal = Vector3(sinT * math.cos(phi), cosT, sinT * math.sin(phi));
    final sp = _between(speed);
    final i = _n++;
    _age[i] = 0;
    _life[i] = math.max(1e-3, _between(lifetime));
    if (localSpace) {
      _px[i] = lx;
      _py[i] = ly;
      _pz[i] = lz;
      _vx[i] = dirLocal.x * sp;
      _vy[i] = dirLocal.y * sp;
      _vz[i] = dirLocal.z * sp;
    } else {
      final t = transform;
      final rot = t.worldRotation;
      final p = t.worldMatrix.transformed3(Vector3(lx, ly, lz));
      final v = _rotate(rot, dirLocal) * sp;
      _px[i] = p.x;
      _py[i] = p.y;
      _pz[i] = p.z;
      _vx[i] = v.x;
      _vy[i] = v.y;
      _vz[i] = v.z;
    }
  }

  static Vector3 _rotate(Quaternion q, Vector3 v) {
    final tx = 2.0 * (q.y * v.z - q.z * v.y);
    final ty = 2.0 * (q.z * v.x - q.x * v.z);
    final tz = 2.0 * (q.x * v.y - q.y * v.x);
    return Vector3(
      v.x + q.w * tx + (q.y * tz - q.z * ty),
      v.y + q.w * ty + (q.z * tx - q.x * tz),
      v.z + q.w * tz + (q.x * ty - q.y * tx),
    );
  }

  /// Color at moment [t] (0..1) of the life.
  Vector4 colorAt(double t) {
    final c = colors;
    if (c.isEmpty) return _white;
    if (t <= c.first.time) return c.first.color;
    for (var i = 0; i + 1 < c.length; i++) {
      final a = c[i], b = c[i + 1];
      if (t <= b.time) {
        final k = b.time == a.time ? 1.0 : (t - a.time) / (b.time - a.time);
        return Vector4(
          a.color.x + (b.color.x - a.color.x) * k,
          a.color.y + (b.color.y - a.color.y) * k,
          a.color.z + (b.color.z - a.color.z) * k,
          a.color.w + (b.color.w - a.color.w) * k,
        );
      }
    }
    return c.last.color;
  }

  /// Adds the sprites of all particles to [batch] (world space).
  void writeSprites(ParticleBatch batch) {
    final flags = (additive ? 1 : 0) | (particleShape.index << 1);
    final m = localSpace ? transform.worldMatrix : null;
    for (var i = 0; i < _n; i++) {
      final t = _age[i] / _life[i];
      final col = colorAt(t);
      if (col.w <= 0) continue;
      var x = _px[i].toDouble(), y = _py[i].toDouble(), z = _pz[i].toDouble();
      if (m != null) {
        final p = m.transformed3(Vector3(x, y, z));
        x = p.x;
        y = p.y;
        z = p.z;
      }
      batch.add(x, y, z, startSize + (endSize - startSize) * t, col.x, col.y, col.z, col.w, flags);
    }
  }

  /// Position of particle [i] in world space (for tests and gameplay).
  Vector3 positionOf(int i) {
    final p = Vector3(_px[i].toDouble(), _py[i].toDouble(), _pz[i].toDouble());
    return localSpace ? transform.worldMatrix.transformed3(p) : p;
  }

  /// Age of particle [i] as 0..1 of its life.
  double lifeFraction(int i) => _age[i] / _life[i];

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.integer('maxParticles', () => maxParticles, null, help: 'Set when the system is made'),
        InspectorField.float('emissionRate', () => emissionRate, (v) => emissionRate = v, min: 0, max: 100000),
        InspectorField.float('lifetimeMin', () => lifetime.$1, (v) => lifetime = (v, lifetime.$2 < v ? v : lifetime.$2), min: 0.01),
        InspectorField.float('lifetimeMax', () => lifetime.$2, (v) => lifetime = (lifetime.$1 > v ? v : lifetime.$1, v), min: 0.01),
        InspectorField.float('speedMin', () => speed.$1, (v) => speed = (v, speed.$2 < v ? v : speed.$2)),
        InspectorField.float('speedMax', () => speed.$2, (v) => speed = (speed.$1 > v ? v : speed.$1, v)),
        InspectorField.float('coneAngleDegrees', () => coneAngleDegrees, (v) => coneAngleDegrees = v, min: 0, max: 180),
        InspectorField.choice<EmitterShape>('shape', EmitterShape.values, () => shape, (v) => shape = v),
        InspectorField.float('shapeSize', () => shapeSize, (v) => shapeSize = v, min: 0),
        InspectorField.vector3('gravity', () => gravity, (v) => gravity = v),
        InspectorField.float('drag', () => drag, (v) => drag = v, min: 0),
        InspectorField.float('startSize', () => startSize, (v) => startSize = v, min: 0),
        InspectorField.float('endSize', () => endSize, (v) => endSize = v, min: 0),
        InspectorField.boolean('additive', () => additive, (v) => additive = v),
        InspectorField.choice<ParticleShape>('particleShape', ParticleShape.values, () => particleShape, (v) => particleShape = v),
        InspectorField.boolean('localSpace', () => localSpace, (v) => localSpace = v),
        InspectorField.boolean('loop', () => loop, (v) => loop = v),
        InspectorField.float('duration', () => duration, (v) => duration = v, min: 0.01),
        InspectorField.boolean('playOnAwake', () => playOnAwake, (v) => playOnAwake = v),
      ];
}
