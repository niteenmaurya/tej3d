import '../../math/vec.dart';

/// Which side of a triangle is not drawn.
enum CullMode { back, front, none }

/// Surface look: color, PBR metallic/roughness, clearcoat, alpha, textures and light response.
class StandardMaterial {
  StandardMaterial({
    Vector4? color,
    Vector3? emissive,
    this.unlit = false,
    this.specular = 0.0,
    this.shininess = 32.0,
    this.cull = CullMode.back,
    this.metallic = 0.0,
    this.roughness = 0.5,
    this.ao = 1.0,
    this.clearcoat = 0.0,
    this.clearcoatRoughness = 0.06,
    this.alpha = 1.0,
    this.textureId = -1,
    this.normalTextureId = -1,
    this.mrTextureId = -1,
  }) : color = color ?? Vector4(0.8, 0.8, 0.8, 1.0),
       emissive = emissive ?? Vector3.zero();

  /// Base color, rgba 0..1.
  Vector4 color;

  /// Color added on top, not affected by light (lamps, screens).
  Vector3 emissive;

  /// If true, the color is shown as it is (no lighting).
  bool unlit;

  /// Strength of the shiny highlight, 0 for none.
  double specular;

  double shininess;

  CullMode cull;

  /// PBR metallic factor (0 = dielectric, 1 = bare metal).
  double metallic;

  /// PBR roughness factor (0.04 = mirror smooth, 1 = chalk matte).
  double roughness;

  /// Ambient occlusion multiplier (0..1).
  double ao;

  /// Clearcoat lacquer layer strength (0 = off, 1 = car paint gloss).
  double clearcoat;

  /// Clearcoat layer roughness (0.02..0.3).
  double clearcoatRoughness;

  /// Surface opacity (1 = opaque, < 1 = physical Fresnel alpha blend).
  double alpha;

  /// Optional native diffuse/albedo texture id (-1 = none).
  int textureId;

  /// Optional native tangent-space normal map texture id (-1 = none).
  int normalTextureId;

  /// Optional native packed AO/Roughness/Metallic texture id (-1 = none).
  int mrTextureId;
}
