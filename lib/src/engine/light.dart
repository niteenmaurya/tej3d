import '../math/vec.dart';

import '../editor/inspector.dart';
import 'game_object.dart';

enum LightType { directional, point }

/// A light. A directional light shines along its object's forward (-Z),
/// like the sun. A point light shines from its position in all directions.
class Light extends Component implements Inspectable {
  Light({
    this.type = LightType.directional,
    Vector3? color,
    this.intensity = 1.0,
    this.range = 20.0,
    this.castShadows = false,
    this.shadowDistance = 30.0,
    this.shadowStrength = 1.0,
    this.shadowMapSize = 1024,
  }) : color = color ?? Vector3(1.0, 1.0, 1.0);

  LightType type;

  /// rgb 0..1.
  Vector3 color;
  double intensity;

  /// Point light only: distance where light is about a quarter strong.
  double range;

  /// Directional light only: objects throw shadows in this light. Only the
  /// first directional light that has this on casts shadows. Shadows are
  /// drawn by the native (C++) renderer; the plain Dart renderer ignores them.
  bool castShadows;

  /// How far from the camera shadows are drawn, in meters. A longer
  /// distance makes shadows less sharp for the same [shadowMapSize].
  double shadowDistance;

  /// 0 = no shadow, 1 = fully dark.
  double shadowStrength;

  /// Shadow texture size in texels (256 to 4096). Bigger is sharper and slower.
  int shadowMapSize;

  /// Sun light pointing along [direction] (world).
  factory Light.sun(Vector3 direction, {double intensity = 1.0, Vector3? color}) {
    final l = Light(color: color, intensity: intensity);
    l._pendingDirection = direction.normalized();
    return l;
  }

  Vector3? _pendingDirection;

  @override
  void awake() {
    final d = _pendingDirection;
    if (d != null) {
      transform.lookAt(transform.worldPosition + d);
      _pendingDirection = null;
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.choice<LightType>('type', LightType.values, () => type, (v) => type = v),
        InspectorField.color3('color', () => color, (v) => color = v),
        InspectorField.float('intensity', () => intensity, (v) => intensity = v, min: 0, max: 100),
        InspectorField.float('range', () => range, (v) => range = v, min: 0.01, help: 'Point light only'),
        InspectorField.boolean('castShadows', () => castShadows, (v) => castShadows = v, help: 'Directional light only'),
        InspectorField.float('shadowDistance', () => shadowDistance, (v) => shadowDistance = v, min: 0.1),
        InspectorField.float('shadowStrength', () => shadowStrength, (v) => shadowStrength = v, min: 0, max: 1),
        InspectorField.integer('shadowMapSize', () => shadowMapSize, (v) => shadowMapSize = v, min: 256, max: 4096),
      ];
}
