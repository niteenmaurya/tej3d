import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../engine/particles.dart';

/// Built-in customizable HUD element types for [HudCanvasComponent].
enum HudWidgetType {
  healthBar,
  ammoCounter,
  minimap,
  crosshair,
  killFeed,
  zoneStatus,
  scoreBadge,
}

/// One positioned HUD widget inside [HudCanvasComponent] (normalized 0..1 screen coordinates).
class HudWidgetSpec {
  HudWidgetSpec({
    required this.id,
    required this.type,
    required this.label,
    required this.x,
    required this.y,
    this.width = 0.22,
    this.height = 0.06,
    this.visible = true,
    this.accentArgb = 0xFF4FC3F7,
  });

  final String id;
  final HudWidgetType type;
  String label;
  double x;
  double y;
  double width;
  double height;
  bool visible;
  int accentArgb;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.name,
        'label': label,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'visible': visible,
        'accentArgb': accentArgb,
      };

  factory HudWidgetSpec.fromJson(Map<String, Object?> j) => HudWidgetSpec(
        id: j['id'] as String? ?? 'hud_1',
        type: HudWidgetType.values.byName(j['type'] as String? ?? 'healthBar'),
        label: j['label'] as String? ?? 'HUD',
        x: (j['x'] as num?)?.toDouble() ?? 0.05,
        y: (j['y'] as num?)?.toDouble() ?? 0.05,
        width: (j['width'] as num?)?.toDouble() ?? 0.22,
        height: (j['height'] as num?)?.toDouble() ?? 0.06,
        visible: j['visible'] != false,
        accentArgb: (j['accentArgb'] as num?)?.toInt() ?? 0xFF4FC3F7,
      );
}

/// Drag-and-drop customizable Game HUD Canvas component (Health bar, Ammo,
/// Minimap, Crosshair, Kill Feed, Safe Zone status).
class HudCanvasComponent extends Component implements Inspectable {
  HudCanvasComponent({List<HudWidgetSpec>? widgets})
      : widgets = widgets ?? battleRoyalePreset();

  final List<HudWidgetSpec> widgets;

  static List<HudWidgetSpec> battleRoyalePreset() => [
        HudWidgetSpec(
          id: 'hp',
          type: HudWidgetType.healthBar,
          label: 'Health & Shield',
          x: 0.03,
          y: 0.86,
          width: 0.24,
          height: 0.08,
          accentArgb: 0xFF4CAF50,
        ),
        HudWidgetSpec(
          id: 'ammo',
          type: HudWidgetType.ammoCounter,
          label: 'Weapon & Ammo',
          x: 0.74,
          y: 0.86,
          width: 0.23,
          height: 0.08,
          accentArgb: 0xFFFFB74D,
        ),
        HudWidgetSpec(
          id: 'crosshair',
          type: HudWidgetType.crosshair,
          label: 'Crosshair',
          x: 0.50,
          y: 0.50,
          width: 0.04,
          height: 0.04,
          accentArgb: 0xFFFFFFFF,
        ),
        HudWidgetSpec(
          id: 'minimap',
          type: HudWidgetType.minimap,
          label: 'Radar Minimap',
          x: 0.80,
          y: 0.08,
          width: 0.17,
          height: 0.24,
          accentArgb: 0xFF29B6F6,
        ),
        HudWidgetSpec(
          id: 'zone',
          type: HudWidgetType.zoneStatus,
          label: 'Safe Zone',
          x: 0.38,
          y: 0.08,
          width: 0.24,
          height: 0.06,
          accentArgb: 0xFFCE93D8,
        ),
      ];

  HudWidgetSpec? findWidget(String id) {
    for (final w in widgets) {
      if (w.id == id) return w;
    }
    return null;
  }

  String get inspectorTitle => 'HUD Canvas (${widgets.length} widgets)';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Widgets', () => widgets.length.toDouble(), (_) {}, min: 0, max: 32),
      ];
}

/// Ready-to-use VFX particle presets for [VfxEmitterComponent].
enum VfxPreset { muzzleFlash, explosion, smoke, sparks, healAura, dustTrail }

/// High-level VFX Emitter driving [ParticleSystem] bursts for combat & vehicle effects.
class VfxEmitterComponent extends Component implements Inspectable {
  VfxEmitterComponent({
    this.preset = VfxPreset.muzzleFlash,
    this.autoPlay = false,
    this.intensity = 1.0,
  });

  VfxPreset preset;
  bool autoPlay;
  double intensity;

  int burstCount = 0;

  /// Triggers a one-shot VFX burst on the attached [ParticleSystem] (creating one if needed).
  void triggerBurst([int? count]) {
    burstCount++;
    if (!isAttached) return;
    final ps = gameObject.getComponent<ParticleSystem>() ?? gameObject.addComponent(ParticleSystem());
    switch (preset) {
      case VfxPreset.muzzleFlash:
        ps.startSize = 0.28 * intensity;
        ps.endSize = 0.04;
        ps.lifetime = (0.08, 0.16);
        ps.speed = (4.0, 7.0);
        ps.burst(count ?? 12);
      case VfxPreset.explosion:
        ps.startSize = 0.85 * intensity;
        ps.endSize = 2.2 * intensity;
        ps.lifetime = (0.5, 0.9);
        ps.speed = (6.0, 11.0);
        ps.burst(count ?? 36);
      case VfxPreset.smoke:
        ps.startSize = 0.5 * intensity;
        ps.endSize = 1.8 * intensity;
        ps.lifetime = (1.2, 2.2);
        ps.speed = (1.0, 2.4);
        ps.burst(count ?? 18);
      case VfxPreset.sparks:
        ps.startSize = 0.14 * intensity;
        ps.endSize = 0.03;
        ps.lifetime = (0.2, 0.45);
        ps.speed = (8.0, 14.0);
        ps.burst(count ?? 22);
      case VfxPreset.healAura:
        ps.startSize = 0.25 * intensity;
        ps.endSize = 0.55 * intensity;
        ps.lifetime = (0.6, 1.1);
        ps.speed = (1.5, 3.0);
        ps.burst(count ?? 16);
      case VfxPreset.dustTrail:
        ps.startSize = 0.35 * intensity;
        ps.endSize = 1.2 * intensity;
        ps.lifetime = (0.6, 1.0);
        ps.speed = (0.8, 1.8);
        ps.burst(count ?? 10);
    }
  }

  @override
  void start() {
    if (autoPlay) triggerBurst();
  }

  String get inspectorTitle => 'VFX Emitter (${preset.name})';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.boolean('Auto Play', () => autoPlay, (v) => autoPlay = v),
        InspectorField.float('Intensity', () => intensity, (v) => intensity = v, min: 0.1, max: 5.0),
      ];
}
