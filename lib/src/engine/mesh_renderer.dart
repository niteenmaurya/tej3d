import '../editor/inspector.dart';
import 'game_object.dart';
import 'render/material.dart';
import 'render/mesh.dart';

/// Draws a [Mesh] with a [StandardMaterial] at the object's transform.
class MeshRenderer extends Component implements Inspectable {
  MeshRenderer(this.mesh, {StandardMaterial? material})
    : material = material ?? StandardMaterial();

  Mesh mesh;
  StandardMaterial material;

  /// Hide without disabling the object.
  bool visible = true;

  /// Native animator that bends a skinned mesh (made by `spawnModel`). -1: none.
  int animatorId = -1;

  /// Throws a shadow (when a light has `castShadows` on).
  bool castShadows = true;

  /// Shows shadows of other objects on its surface.
  bool receiveShadows = true;

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.boolean('visible', () => visible, (v) => visible = v),
        InspectorField.boolean('castShadows', () => castShadows, (v) => castShadows = v),
        InspectorField.boolean('receiveShadows', () => receiveShadows, (v) => receiveShadows = v),
        InspectorField.color4('color', () => material.color, (v) => material.color = v),
        InspectorField.color3('emissive', () => material.emissive, (v) => material.emissive = v),
        InspectorField.boolean('unlit', () => material.unlit, (v) => material.unlit = v),
        InspectorField.float('specular', () => material.specular, (v) => material.specular = v, min: 0, max: 10),
        InspectorField.float('shininess', () => material.shininess, (v) => material.shininess = v, min: 1, max: 512),
        InspectorField.choice<CullMode>('cull', CullMode.values, () => material.cull, (v) => material.cull = v),
      ];
}
