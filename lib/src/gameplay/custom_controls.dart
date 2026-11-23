/// Developer-customizable Control Buttons & Physics Action Mapping system.
/// Developers can create, position, color, bind keyboard keys, and assign
/// physics/gameplay actions (Throttle, Steer, Brake/Drift, Nitro Boost, Jump,
/// Custom 3D Physics Impulse, or Custom Script Events) visually in the Editor
/// or in Dart code — synced automatically to Scene JSON & exported games.
library;

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';
import 'unity_components.dart';

enum ControlActionType {
  throttleForward('Gas / Forward'),
  throttleReverse('Brake / Reverse'),
  steerLeft('Steer Left'),
  steerRight('Steer Right'),
  handbrakeDrift('Handbrake / Drift'),
  nitroBoost('Nitro Boost (Physics)'),
  moveForward('Move Forward'),
  moveBackward('Move Back'),
  moveLeft('Move Left'),
  moveRight('Move Right'),
  jump('Jump'),
  physicsImpulse('Custom Physics Force'),
  customEvent('Custom Script Event');

  const ControlActionType(this.label);
  final String label;
}

/// One developer-defined on-screen + keyboard control button.
class CustomControlButton {
  CustomControlButton({
    required this.id,
    required this.label,
    required this.action,
    this.normX = 0.82,
    this.normY = 0.80,
    this.width = 68.0,
    this.height = 46.0,
    this.colorHex = 0xFF1976D2,
    this.keyBinding = '',
    this.power = 12.0,
    Vector3? impulseVector,
    this.customEventName = '',
  }) : impulseVector = impulseVector ?? Vector3(0, 8, 0);

  String id;
  String label;
  ControlActionType action;

  /// Normalized screen placement (0.0 = left/top, 1.0 = right/bottom).
  double normX;
  double normY;
  double width;
  double height;
  int colorHex;

  /// Optional desktop keyboard key name (e.g. 'W', 'A', 'S', 'D', 'Space', 'Shift').
  String keyBinding;

  /// Magnitude for Nitro Boost / Brake / Force actions.
  double power;

  /// 3D force/impulse vector when [action] is [ControlActionType.physicsImpulse].
  Vector3 impulseVector;

  /// Event name fired when [action] is [ControlActionType.customEvent].
  String customEventName;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'action': action.name,
    'normX': normX,
    'normY': normY,
    'width': width,
    'height': height,
    'colorHex': colorHex,
    'keyBinding': keyBinding,
    'power': power,
    'impulseVector': [impulseVector.x, impulseVector.y, impulseVector.z],
    'customEventName': customEventName,
  };

  factory CustomControlButton.fromJson(Map<String, Object?> m) {
    final actName = (m['action'] as String?) ?? 'customEvent';
    final act = ControlActionType.values.firstWhere(
      (e) => e.name == actName,
      orElse: () => ControlActionType.customEvent,
    );
    final iv = (m['impulseVector'] as List?) ?? const [0.0, 8.0, 0.0];
    return CustomControlButton(
      id: (m['id'] as String?) ?? 'btn_1',
      label: (m['label'] as String?) ?? 'BTN',
      action: act,
      normX: (m['normX'] as num?)?.toDouble() ?? 0.8,
      normY: (m['normY'] as num?)?.toDouble() ?? 0.8,
      width: (m['width'] as num?)?.toDouble() ?? 68.0,
      height: (m['height'] as num?)?.toDouble() ?? 46.0,
      colorHex: (m['colorHex'] as num?)?.toInt() ?? 0xFF1976D2,
      keyBinding: (m['keyBinding'] as String?) ?? '',
      power: (m['power'] as num?)?.toDouble() ?? 12.0,
      impulseVector: Vector3(
        (iv[0] as num).toDouble(),
        (iv[1] as num).toDouble(),
        (iv[2] as num).toDouble(),
      ),
      customEventName: (m['customEventName'] as String?) ?? '',
    );
  }
}

/// Component holding the developer's custom control layout & physics bindings.
/// Serializes cleanly with `SceneIO` and drives `CarController3D`,
/// `PlayerController3D`, `SimpleRigidbody`, or custom developer callbacks.
class CustomControlLayoutComponent extends Component implements Inspectable {
  CustomControlLayoutComponent({
    List<CustomControlButton>? buttons,
    this.onCustomEvent,
  }) : buttons = buttons ?? carRacingPreset();

  final List<CustomControlButton> buttons;
  void Function(String eventName, CustomControlButton button)? onCustomEvent;

  static List<CustomControlButton> carRacingPreset() => [
    CustomControlButton(
      id: 'steer_left',
      label: '◀',
      action: ControlActionType.steerLeft,
      normX: 0.06,
      normY: 0.82,
      width: 64,
      height: 54,
      colorHex: 0xFF263238,
      keyBinding: 'A',
    ),
    CustomControlButton(
      id: 'steer_right',
      label: '▶',
      action: ControlActionType.steerRight,
      normX: 0.14,
      normY: 0.82,
      width: 64,
      height: 54,
      colorHex: 0xFF263238,
      keyBinding: 'D',
    ),
    CustomControlButton(
      id: 'drift',
      label: 'DRIFT',
      action: ControlActionType.handbrakeDrift,
      normX: 0.72,
      normY: 0.84,
      width: 72,
      height: 46,
      colorHex: 0xFFEF6C00,
      keyBinding: 'Space',
      power: 16.0,
    ),
    CustomControlButton(
      id: 'brake',
      label: 'BRAKE',
      action: ControlActionType.throttleReverse,
      normX: 0.80,
      normY: 0.84,
      width: 72,
      height: 46,
      colorHex: 0xFFC62828,
      keyBinding: 'S',
    ),
    CustomControlButton(
      id: 'gas',
      label: 'GAS',
      action: ControlActionType.throttleForward,
      normX: 0.89,
      normY: 0.80,
      width: 78,
      height: 62,
      colorHex: 0xFF2E7D32,
      keyBinding: 'W',
    ),
    CustomControlButton(
      id: 'nitro',
      label: 'NITRO',
      action: ControlActionType.nitroBoost,
      normX: 0.89,
      normY: 0.66,
      width: 78,
      height: 46,
      colorHex: 0xFF0277BD,
      keyBinding: 'Shift',
      power: 18.0,
    ),
  ];

  static List<CustomControlButton> platformerPreset() => [
    CustomControlButton(id: 'left', label: 'A', action: ControlActionType.moveLeft, normX: 0.05, normY: 0.82, width: 52, height: 48, colorHex: 0xFF263238, keyBinding: 'A'),
    CustomControlButton(id: 'right', label: 'D', action: ControlActionType.moveRight, normX: 0.14, normY: 0.82, width: 52, height: 48, colorHex: 0xFF263238, keyBinding: 'D'),
    CustomControlButton(id: 'up', label: 'W', action: ControlActionType.moveForward, normX: 0.095, normY: 0.71, width: 52, height: 48, colorHex: 0xFF263238, keyBinding: 'W'),
    CustomControlButton(id: 'down', label: 'S', action: ControlActionType.moveBackward, normX: 0.095, normY: 0.82, width: 52, height: 48, colorHex: 0xFF263238, keyBinding: 'S'),
    CustomControlButton(id: 'jump', label: 'JUMP', action: ControlActionType.jump, normX: 0.86, normY: 0.80, width: 82, height: 54, colorHex: 0xFF1976D2, keyBinding: 'Space'),
  ];

  /// Applies currently held and newly pressed custom button IDs directly to
  /// this GameObject's physics/vehicle/player components.
  void applyActiveControls(
    Set<String> heldIds,
    Set<String> justPressedIds,
    double dt,
  ) {
    final car = gameObject.getComponent<CarController3D>();
    final player = gameObject.getComponent<PlayerController3D>();
    final rb = gameObject.getComponent<SimpleRigidbody>();

    var throttle = 0.0;
    var steer = 0.0;
    var moveX = 0.0;
    var moveZ = 0.0;

    for (final btn in buttons) {
      final isHeld = heldIds.contains(btn.id);
      final isJust = justPressedIds.contains(btn.id);
      if (!isHeld && !isJust) continue;

      switch (btn.action) {
        case ControlActionType.throttleForward:
          throttle += 1.0;
          break;
        case ControlActionType.throttleReverse:
          throttle -= 1.0;
          break;
        case ControlActionType.steerLeft:
          steer -= 1.0;
          break;
        case ControlActionType.steerRight:
          steer += 1.0;
          break;
        case ControlActionType.handbrakeDrift:
          if (car != null) {
            car.speed *= (1.0 - (dt * 2.5)).clamp(0.0, 1.0);
            car.steerRate = 4.2; // sharper drift turn
          }
          break;
        case ControlActionType.nitroBoost:
          if (car != null) {
            car.speed = (car.speed + btn.power * dt).clamp(-car.maxSpeed, car.maxSpeed * 1.45);
          }
          break;
        case ControlActionType.moveForward:
          moveZ -= 1.0;
          break;
        case ControlActionType.moveBackward:
          moveZ += 1.0;
          break;
        case ControlActionType.moveLeft:
          moveX -= 1.0;
          break;
        case ControlActionType.moveRight:
          moveX += 1.0;
          break;
        case ControlActionType.jump:
          if (isJust && player != null) {
            player.jumpQueued = true;
          }
          break;
        case ControlActionType.physicsImpulse:
          if (isJust && rb != null) {
            rb.addImpulse(btn.impulseVector);
          }
          break;
        case ControlActionType.customEvent:
          if (isJust) {
            onCustomEvent?.call(
              btn.customEventName.isEmpty ? btn.label : btn.customEventName,
              btn,
            );
          }
          break;
      }
    }

    if (car != null) {
      car.throttle = throttle.clamp(-1.0, 1.0);
      car.steerInput = steer.clamp(-1.0, 1.0);
    }
    if (player != null) {
      player.inputX = moveX.clamp(-1.0, 1.0);
      player.inputZ = moveZ.clamp(-1.0, 1.0);
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.integer('buttonCount', () => buttons.length, null),
  ];
}
