/// World-space 3D text mesh generator (zero third-party font packages) for
/// in-game signs, floating damage numbers, and 3D HUD labels.
library;

import 'dart:typed_data';

import '../engine/render/mesh.dart';
import '../world/mesh_tools.dart';

/// Compact built-in 3x5 bitmap font for uppercase ASCII, digits, and basic
/// punctuation so 3D text works out of the box on every platform.
class BitmapFont {
  const BitmapFont._();

  static const Map<String, List<String>> _glyphs = {
    'A': ['010', '101', '111', '101', '101'],
    'B': ['110', '101', '110', '101', '110'],
    'C': ['011', '100', '100', '100', '011'],
    'D': ['110', '101', '101', '101', '110'],
    'E': ['111', '100', '110', '100', '111'],
    'F': ['111', '100', '110', '100', '100'],
    'G': ['011', '100', '101', '101', '011'],
    'H': ['101', '101', '111', '101', '101'],
    'I': ['111', '010', '010', '010', '111'],
    'J': ['001', '001', '001', '101', '010'],
    'K': ['101', '101', '110', '101', '101'],
    'L': ['100', '100', '100', '100', '111'],
    'M': ['101', '111', '111', '101', '101'],
    'N': ['110', '101', '101', '101', '101'],
    'O': ['010', '101', '101', '101', '010'],
    'P': ['110', '101', '110', '100', '100'],
    'Q': ['010', '101', '101', '011', '001'],
    'R': ['110', '101', '110', '101', '101'],
    'S': ['011', '100', '010', '001', '110'],
    'T': ['111', '010', '010', '010', '010'],
    'U': ['101', '101', '101', '101', '111'],
    'V': ['101', '101', '101', '101', '010'],
    'W': ['101', '101', '111', '111', '101'],
    'X': ['101', '101', '010', '101', '101'],
    'Y': ['101', '101', '010', '010', '010'],
    'Z': ['111', '001', '010', '100', '111'],
    '0': ['111', '101', '101', '101', '111'],
    '1': ['010', '110', '010', '010', '111'],
    '2': ['110', '001', '010', '100', '111'],
    '3': ['110', '001', '010', '001', '110'],
    '4': ['101', '101', '111', '001', '001'],
    '5': ['111', '100', '110', '001', '110'],
    '6': ['011', '100', '111', '101', '111'],
    '7': ['111', '001', '010', '010', '010'],
    '8': ['111', '101', '111', '101', '111'],
    '9': ['111', '101', '111', '001', '110'],
    '+': ['000', '010', '111', '010', '000'],
    '-': ['000', '000', '111', '000', '000'],
    '!': ['010', '010', '010', '000', '010'],
    '.': ['000', '000', '000', '000', '010'],
    ':': ['000', '010', '000', '010', '000'],
    ' ': ['000', '000', '000', '000', '000'],
  };

  static List<String> glyph(String ch) => _glyphs[ch.toUpperCase()] ?? _glyphs[' ']!;
}

/// Generates a 3D quad [Mesh] for any string so text renders in the 3D scene
/// with both the software and GPU renderers.
class TextMesh3D {
  const TextMesh3D._();

  static Mesh build(
    String text, {
    double pixelSize = 0.08,
    bool centered = true,
  }) {
    final pos = <double>[];
    final norm = <double>[];
    final idx = <int>[];

    final charStep = 4 * pixelSize;
    final totalW = text.isEmpty ? 0.0 : (text.length * charStep - pixelSize);
    final totalH = 5 * pixelSize;
    final offsetX = centered ? -totalW * 0.5 : 0.0;
    final offsetY = centered ? -totalH * 0.5 : 0.0;

    for (var ci = 0; ci < text.length; ci++) {
      final rows = BitmapFont.glyph(text[ci]);
      final gx = offsetX + ci * charStep;
      for (var r = 0; r < 5; r++) {
        for (var c = 0; c < 3; c++) {
          if (rows[r][c] != '1') continue;
          final x0 = gx + c * pixelSize;
          final x1 = x0 + pixelSize;
          final y1 = offsetY + (5 - r) * pixelSize;
          final y0 = y1 - pixelSize;
          final base = pos.length ~/ 3;
          pos.addAll([
            x0, y0, 0.0,
            x1, y0, 0.0,
            x1, y1, 0.0,
            x0, y1, 0.0,
          ]);
          for (var k = 0; k < 4; k++) {
            norm.addAll([0.0, 0.0, 1.0]);
          }
          idx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
        }
      }
    }

    return Mesh(
      MeshArrays(Float32List.fromList(pos), Float32List.fromList(norm), Uint32List.fromList(idx)),
      name: 'text:$text',
    );
  }
}
