/// A set of layers as bits, like Unity `LayerMask`. Layer numbers are 0..31.
class LayerMask {
  const LayerMask(this.bits);

  factory LayerMask.of(Iterable<int> layers) {
    var b = 0;
    for (final l in layers) {
      b |= 1 << l;
    }
    return LayerMask(b);
  }

  static const LayerMask none = LayerMask(0);
  static const LayerMask everything = LayerMask(0xFFFFFFFF);

  final int bits;

  bool contains(int layer) => ((bits >> layer) & 1) == 1;

  LayerMask including(int layer) => LayerMask(bits | (1 << layer));

  LayerMask excluding(int layer) => LayerMask(bits & ~(1 << layer) & 0xFFFFFFFF);

  LayerMask operator |(LayerMask other) => LayerMask(bits | other.bits);

  LayerMask operator &(LayerMask other) => LayerMask(bits & other.bits);

  LayerMask operator ~() => LayerMask(~bits & 0xFFFFFFFF);

  @override
  bool operator ==(Object other) => other is LayerMask && other.bits == bits;

  @override
  int get hashCode => bits.hashCode;
}

/// Layer names and the collision matrix, like Unity's Layers settings and
/// "Layer Collision Matrix". Layers 0..7 are reserved like in Unity.
class Layers {
  Layers() {
    _names[0] = 'Default';
    _names[1] = 'TransparentFX';
    _names[2] = 'Ignore Raycast';
    _names[4] = 'Water';
    _names[5] = 'UI';
  }

  static const int count = 32;
  static const int defaultLayer = 0;

  final List<String?> _names = List<String?>.filled(count, null);
  final List<int> _collides = List<int>.filled(count, 0xFFFFFFFF);

  /// Adds a layer. Without [index] the first free layer from 8 is used.
  int define(String name, [int? index]) {
    final existing = indexOf(name);
    if (existing >= 0) return existing;
    var i = index ?? -1;
    if (i < 0) {
      for (var k = 8; k < count; k++) {
        if (_names[k] == null) {
          i = k;
          break;
        }
      }
    }
    if (i < 0 || i >= count) {
      throw StateError('No free layer for "$name".');
    }
    if (_names[i] != null) {
      throw StateError('Layer $i is already "${_names[i]}".');
    }
    _names[i] = name;
    return i;
  }

  /// -1 if the name is not defined.
  int indexOf(String name) => _names.indexOf(name);

  String? nameOf(int index) => _names[index];

  LayerMask mask(Iterable<String> names) {
    var b = 0;
    for (final n in names) {
      final i = indexOf(n);
      if (i < 0) throw ArgumentError('Unknown layer "$n".');
      b |= 1 << i;
    }
    return LayerMask(b);
  }

  bool canCollide(int a, int b) => ((_collides[a] >> b) & 1) == 1;

  /// Turns collision between two layers on or off (both directions).
  void setCollision(int a, int b, bool enabled) {
    if (enabled) {
      _collides[a] |= 1 << b;
      _collides[b] |= 1 << a;
    } else {
      _collides[a] &= ~(1 << b) & 0xFFFFFFFF;
      _collides[b] &= ~(1 << a) & 0xFFFFFFFF;
    }
  }

  /// All layers that [layer] collides with.
  LayerMask collidesWith(int layer) => LayerMask(_collides[layer]);
}

/// Finds objects by tag or layer, like `FindWithTag` in Unity.
/// Works with any object type (your own class, a scene `Node`, ...).
class ObjectIndex<T extends Object> {
  final Map<T, _Info> _info = {};

  void add(T object, {String tag = 'Untagged', int layer = 0}) {
    _info[object] = _Info(tag, layer);
  }

  bool remove(T object) => _info.remove(object) != null;

  void setTag(T object, String tag) => _info[object]?.tag = tag;

  void setLayer(T object, int layer) => _info[object]?.layer = layer;

  String? tagOf(T object) => _info[object]?.tag;

  int? layerOf(T object) => _info[object]?.layer;

  bool compareTag(T object, String tag) => _info[object]?.tag == tag;

  /// First object with the tag, or null.
  T? findWithTag(String tag) {
    for (final e in _info.entries) {
      if (e.value.tag == tag) return e.key;
    }
    return null;
  }

  List<T> findAllWithTag(String tag) => [
    for (final e in _info.entries)
      if (e.value.tag == tag) e.key,
  ];

  List<T> inMask(LayerMask mask) => [
    for (final e in _info.entries)
      if (mask.contains(e.value.layer)) e.key,
  ];

  int get length => _info.length;
}

class _Info {
  _Info(this.tag, this.layer);
  String tag;
  int layer;
}
