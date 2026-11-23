# tej3d native core

Our own C++17 core. No third party code (no bgfx, Jolt, ozz, flutter_scene).
Dart scripts call it through a plain C API (`include/tej3d.h`, `dart:ffi`).

What is inside, and what is tested (`tests/test_main.cpp`, all pass with g++ 13):

| Part | Status |
|---|---|
| Rigid bodies: sphere, box, SAT + clipping, sequential impulse solver, friction, restitution, sleeping | tested |
| Layers and masks, triggers (sensors), begin/end events, raycast | tested |
| Joints: ball, fixed, hinge (limits, motor), rope, spring, break force | tested |
| Skinned `.glb` import: bones, weights, animation clips | tested (also with damaged files) |
| Post effects: exposure, tonemap, contrast, saturation, vignette, bloom | tested |
| Character controller (capsule: walk, jump, steps, slope limit, wall sliding, ground snap) | tested |
| Sphere overlap query (`overlapSphere`) | tested |
| Shadow map for the first directional light (soft PCF edges, cast/receive per object) | tested |
| Skeleton, keyframe clips, crossfade, skinning matrices | tested |
| Static triangle mesh colliders (tracks, terrain): sphere and box contacts, ray casts, no tunneling | tested |
| PNG decoder, mip maps, bilinear textures | tested (with PNGs made by Python zlib) |
| JPEG decoder: baseline, extended sequential and progressive, restart markers, all subsamplings | tested against libjpeg (same pixels as the baseline twin of each progressive file), 1600 damaged files, ASan + UBSan |
| `.glb` model loader (Blender export): meshes, node names and transforms, colors, PNG/JPEG textures | tested with generated models (`tests/data/`) |
| Software renderer (CPU): depth buffer, per pixel light, fog, textures, skinning | tested by eye (PNG), not at phone speed |
| GPU renderer | **not written yet** |
| Capsule and compound colliders | tested (a capsule is a row of overlapping spheres) |
| Convex hull colliders (GJK + EPA) | not written yet |

Build (any C++17 compiler):

    g++ -std=c++17 -O2 -fPIC -shared -fvisibility=hidden -Isrc src/*.cpp -o libtej3d.so   # src/*.cpp includes gltf.cpp
    # or: cmake -S native -B build && cmake --build build && ctest --test-dir build

Run the tests without CMake:

    g++ -std=c++17 -O2 -Isrc -Iinclude tests/test_main.cpp src/physics.cpp src/trimesh.cpp src/png.cpp src/anim.cpp \
        src/world.cpp src/raster.cpp src/gltf.cpp src/character.cpp src/capi.cpp -o tej3d_tests && ./tej3d_tests

Android, iOS, Windows, macOS and Linux builds of the library are **not set up
or tested yet**. The code uses only the C++ standard library.

Use your own model: in Blender choose File > Export > glTF 2.0, format "glTF Binary (.glb)". Node names are kept, so you can find parts by name in Dart (`root.children`).
