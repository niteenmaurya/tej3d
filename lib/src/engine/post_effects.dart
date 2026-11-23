/// How the picture is mapped from light to screen colors.
enum Tonemap {
  /// No mapping (colors as drawn).
  none,

  /// Soft shoulder: bright colors roll off.
  reinhard,

  /// Film like curve with a bit more contrast.
  aces,
}

/// Picture effects applied after the scene is drawn. Put one on a [Camera]:
///
/// ```dart
/// camera.post = const PostEffects(
///   tonemap: Tonemap.aces,
///   vignette: 0.4,
///   bloom: 0.6,
///   ssao: true,
///   antiAliasing: true,
/// );
/// ```
///
/// Done by the native (C++) renderer. The default values change nothing.
class PostEffects {
  const PostEffects({
    this.exposure = 1.0,
    this.tonemap = Tonemap.none,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.vignette = 0.0,
    this.bloom = 0.0,
    this.bloomThreshold = 0.7,
    this.ssao = false,
    this.ssaoStrength = 0.55,
    this.ssaoRadius = 4,
    this.antiAliasing = false,
  });

  /// Brightness multiplier. 1 = unchanged.
  final double exposure;
  final Tonemap tonemap;

  /// 1 = unchanged, above 1 more contrast.
  final double contrast;

  /// 0 = black and white, 1 = unchanged, above 1 more color.
  final double saturation;

  /// 0..1 darkening of the corners.
  final double vignette;

  /// Strength of the glow around bright parts. 0 = off.
  final double bloom;

  /// How bright (0..1) a part must be before it glows.
  final double bloomThreshold;

  /// Enables Screen-Space Ambient Occlusion (SSAO) contact shadows.
  final bool ssao;

  /// SSAO darkening strength (0..1).
  final double ssaoStrength;

  /// SSAO sample radius in pixels.
  final int ssaoRadius;

  /// Enables FXAA edge anti-aliasing.
  final bool antiAliasing;

  /// True if every post-pass value is neutral (does not include SSAO/AA toggles).
  bool get isNeutral =>
      exposure == 1.0 &&
      tonemap == Tonemap.none &&
      contrast == 1.0 &&
      saturation == 1.0 &&
      vignette == 0.0 &&
      bloom == 0.0;

  Map<String, Object?> toJson() => {
        'exposure': exposure,
        'tonemap': tonemap.name,
        'contrast': contrast,
        'saturation': saturation,
        'vignette': vignette,
        'bloom': bloom,
        'bloomThreshold': bloomThreshold,
        'ssao': ssao,
        'ssaoStrength': ssaoStrength,
        'ssaoRadius': ssaoRadius,
        'antiAliasing': antiAliasing,
      };

  factory PostEffects.fromJson(Map<String, Object?> j) {
    double n(String k, double d) => j[k] is num ? (j[k] as num).toDouble() : d;
    return PostEffects(
      exposure: n('exposure', 1.0),
      tonemap: j['tonemap'] is String
          ? (Tonemap.values.asNameMap()[j['tonemap'] as String] ?? Tonemap.none)
          : Tonemap.none,
      contrast: n('contrast', 1.0),
      saturation: n('saturation', 1.0),
      vignette: n('vignette', 0.0),
      bloom: n('bloom', 0.0),
      bloomThreshold: n('bloomThreshold', 0.7),
      ssao: j['ssao'] == true,
      ssaoStrength: n('ssaoStrength', 0.55),
      ssaoRadius: j['ssaoRadius'] is num ? (j['ssaoRadius'] as num).round() : 4,
      antiAliasing: j['antiAliasing'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PostEffects &&
      other.exposure == exposure &&
      other.tonemap == tonemap &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.vignette == vignette &&
      other.bloom == bloom &&
      other.bloomThreshold == bloomThreshold &&
      other.ssao == ssao &&
      other.ssaoStrength == ssaoStrength &&
      other.ssaoRadius == ssaoRadius &&
      other.antiAliasing == antiAliasing;

  @override
  int get hashCode => Object.hash(
        exposure,
        tonemap,
        contrast,
        saturation,
        vignette,
        bloom,
        bloomThreshold,
        ssao,
        ssaoStrength,
        ssaoRadius,
        antiAliasing,
      );
}
