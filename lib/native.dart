/// Access to the C++ core (physics, models, CPU PBR renderer) through
/// `dart:ffi`. Not available on the web.
///
/// Works in both Flutter apps AND headless Dart VM / CI scripts (without
/// `dart:ui`): use [NativeSceneSync] for headless rendering to RGBA/PNG/AVI.
library;

export 'src/native/bindings.dart' show TejBindings, TejBodyDesc;
export 'src/native/native_lib.dart'
    show NativeBytes, NativeFloats, NativeInt32s, NativeUint32s, TejNative;
export 'src/native/native_model.dart' show meshFromPart, spawnModel;
export 'src/native/native_character.dart' show NativeCharacterController;
export 'src/native/native_joint.dart' show NativeJoint, NativeJointType, NativeJoints;
export 'src/native/native_physics.dart'
    show
        NativeDebugDraw,
        NativeMeshCollider,
        NativePhysics,
        NativeRigidBody,
        NativeShape;
export 'src/native/native_render_backend_stub.dart'
    if (dart.library.ui) 'src/native/native_render_backend.dart'
    show NativeRenderBackend;
export 'src/native/native_scene_sync.dart' show NativeSceneSync;
export 'src/native/native_vehicle.dart' show NativeVehicleBody;
export 'src/native/native_world.dart'
    show
        NativeBodyDesc,
        NativeChildShape,
        NativeCharacterState,
        NativeContactEvent,
        NativeModel,
        NativeModelClip,
        NativeModelPart,
        NativeRayHit,
        NativeWorld;
