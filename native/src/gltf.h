// Loads a binary glTF (.glb), the format Blender exports.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include "world.h"

namespace tej {

// Reads meshes, node transforms and base colors from a .glb and creates one
// instance per mesh primitive. The pieces are listed in world.modelParts.
// Returns the number of parts, or -1 and sets world.modelError.
//
// Supported: nodes with matrix or translation/rotation/scale, triangle
// meshes (positions, normals, uv0, indices of 8/16/32 bit), baseColorFactor,
// doubleSided. Not supported yet: textures inside the file, skins, animation,
// sparse accessors, morph targets, .gltf with separate files.
int loadGlb(World& w, const uint8_t* data, size_t size);

}  // namespace tej
