/// tej3d: a 3D game engine for Flutter.
///
/// Own scene graph, components, animation, input, camera and renderer.
/// No dependency on flutter_scene.
library;

// Own vectors, matrices and quaternions (no third party package)
export 'src/math/vec.dart';

// AI
export 'src/ai/behavior_tree.dart'
    show
        Blackboard,
        BtAction,
        BtCondition,
        BtInverter,
        BtNode,
        BtRepeat,
        BtSelector,
        BtSequence,
        BtStatus,
        BtWait;
export 'src/ai/steering.dart' show Steering;
// Animation
export 'src/anim/animation_curve.dart'
    show AnimationCurve, CurveKey, WrapMode;
export 'src/anim/ik.dart' show Fabrik, Ik, IkResult, TwoBoneIk;
export 'src/anim/animator.dart'
    show
        AnimState,
        AnimTransition,
        AnimationClip,
        AnimationEvent,
        Animator,
        AnimatorLayer,
        AnimatorParams,
        BlendChild,
        BlendChild2D,
        BlendTree1D,
        BlendTree2D,
        ClipMotion,
        Cond,
        CondOp,
        Motion,
        Pose;
export 'src/anim/timeline.dart'
    show applyEase, DoubleTrack, Ease, Keyframe, Vector3Track;
export 'src/anim/tween.dart' show Easing, EaseFn, Tween, TweenRunner;
// Camera
export 'src/camera/camera_brain.dart'
    show CameraBrain, CameraShake, CameraState, VirtualCamera;
export 'src/camera/chase_camera.dart' show ChaseCamera;
// Core
export 'src/core/asset_cache.dart' show AssetCache;
export 'src/core/coroutine.dart'
    show
        Coroutine,
        CoroutineRunner,
        Wait,
        WaitForCoroutine,
        WaitForSeconds,
        WaitFrames,
        WaitUntil,
        WaitWhile;
export 'src/core/event_bus.dart' show EventBus;
export 'src/core/fixed_stepper.dart' show FixedStepper;
export 'src/core/game_state.dart' show GameStateMachine;
export 'src/core/layers.dart' show LayerMask, Layers, ObjectIndex;
export 'src/core/object_pool.dart' show ObjectPool;
export 'src/core/profiler.dart' show FrameProfiler;
export 'src/core/spatial_hash.dart' show SpatialHash;
export 'src/core/timers.dart' show GameTimer;
// Engine: scene, objects, rendering
export 'src/engine/camera.dart' show Camera;
export 'src/engine/game_object.dart' show Component, GameObject, Scene;
export 'src/engine/light.dart' show Light, LightType;
export 'src/engine/mesh_renderer.dart' show MeshRenderer;
export 'src/engine/render/material.dart' show CullMode, StandardMaterial;
export 'src/engine/render/mesh.dart' show Mesh;
export 'src/engine/render/primitives.dart' show Primitives;
export 'src/engine/render/render_backend.dart' show RenderBackend;
export 'src/engine/render/render_frame.dart'
    show DrawItem, LightData, RenderFrame, RenderStats;
export 'src/engine/render/software_backend.dart' show SoftwareRenderBackend;
export 'src/engine/render/software_rasterizer.dart'
    show RasterResult, SoftwareRasterizer;
export 'src/engine/transform.dart' show Transform;
// Game
export 'src/game/active_overlays.dart' show ActiveOverlays;
export 'src/game/tej3d_game.dart' show Tej3DGame;
export 'src/game/tej3d_game_widget.dart'
    show Tej3DGameWidget, Tej3DOverlayBuilder;
export 'src/i18n/localizer.dart' show Localizer;
// Input
export 'src/input/input_actions.dart'
    show
        AxisCompositeBinding,
        Binding,
        ControlBinding,
        InputAction,
        InputActionMap,
        RawInput;
export 'src/input/input_state.dart' show KeyboardState;
export 'src/input/keyboard_source.dart' show KeyboardSource;
// Math
export 'src/math/mathf.dart'
    show Mathf, PerlinNoise, Rng, SmoothDamp, SmoothDamp3;
export 'src/nav/grid_path.dart' show Cell, GridPath;
export 'src/save/save_data.dart' show MemorySaveStorage, SaveData, SaveStorage;
export 'src/audio/audio_backend.dart'
    show AudioBackend, AudioClip, RecordedVoice, RecordingAudioBackend;
export 'src/audio/audio_system.dart'
    show AudioListener, AudioRolloff, AudioSource, AudioSystem;
export 'src/ai/nav_agent.dart' show NavAgent;
export 'src/ai/navmesh.dart' show NavMesh, NavSource;
export 'src/engine/debug_draw.dart' show DebugColors, DebugDraw;
export 'src/engine/particles.dart' show ColorStop, EmitterShape, ParticleBatch, ParticleShape, ParticleSystem;
export 'src/engine/post_effects.dart' show PostEffects, Tonemap;
export 'src/input/gamepad_source.dart'
    show GamepadProvider, GamepadSnapshot, GamepadSource, ManualGamepadProvider;
export 'src/world/terrain.dart' show Terrain, TerrainChunk;
export 'src/net/net_core.dart'
    show
        LoopbackNetwork,
        NetClient,
        NetConditions,
        NetHandler,
        NetHost,
        NetNode,
        NetPeer,
        NetRpcError,
        NetRpcHandler,
        NetTransport,
        SnapshotBuffer;
export 'src/net/net_replication.dart' show NetIdentity, NetPrefab, NetReplicator;
export 'src/editor/inspector.dart' show FieldType, Inspectable, Inspector, InspectorField;
export 'src/editor/editor_bridge.dart' show EditorBridge;
export 'src/serialization/component_registry.dart'
    show ComponentFromJson, ComponentRegistry, ComponentToJson;
export 'src/serialization/prefab.dart' show Prefab, UnknownComponents;
export 'src/serialization/scene_io.dart' show SceneIO;
export 'src/serialization/scene_manager.dart' show SceneBuilder, SceneManager;
export 'src/ui/minimap.dart' show Minimap, MinimapMarker, MinimapProjection;
// Mesh building
export 'src/world/mesh_tools.dart' show MeshArrays, MeshTools;

// New in 0.14.0 (all web-safe: no dart:ffi, no dart:io)
export 'src/ai/navmesh_builder.dart'
    show
        NavMeshBuildConfig,
        NavMeshBuildResult,
        NavMeshBuilder,
        NavObstacle,
        OffMeshLink;
export 'src/anim/ik.dart' show IkConstraint, SkinnedIkSolver;
export 'src/anim/morph.dart' show MorphController, MorphTarget;
export 'src/anim/retarget.dart'
    show
        AnimationRetargeter,
        BoneMap,
        BoneTransform,
        RootMotionDelta,
        RootMotionExtractor,
        SkeletonPose;
export 'src/engine/render/gpu_frame.dart'
    show
        GpuDrawCall,
        GpuFrameBuilder,
        GpuFramePacket,
        GpuFrameUniforms,
        GpuMeshBuffer,
        GpuVertexLayout;
export 'src/engine/render/gpu_backend.dart'
    show GpuDriver, GpuRenderBackend, RecordingGpuDriver;
export 'src/net/net_web.dart'
    show BrowserWebSocket, MockBrowserWebSocket, WebNetTransport;

// New in 0.15.0 (Unity-grade production systems, all web-safe)
export 'src/ai/crowd.dart' show CrowdAgent, CrowdManager;
export 'src/anim/cutscene.dart'
    show
        CameraCutClip,
        CameraCutTrack,
        CutsceneCue,
        CutsceneDirector,
        CutsceneTrack,
        EventTrack,
        VectorKeyframe,
        VectorTrack;
export 'src/anim/ragdoll.dart' show RagdollBuilder, RagdollLimbDesc;
export 'src/audio/audio_mixer.dart'
    show AudioBus, AudioMixer, MusicCrossfader, ReverbZone;
export 'src/engine/environment.dart' show ReflectionProbe, Skybox;
export 'src/engine/lod_group.dart'
    show InstancedMeshRenderer, LODGroup, LODLevel, MeshInstance;
export 'src/engine/trail_renderer.dart' show SpriteSheetConfig, TrailRenderer;
export 'src/net/net_prediction.dart'
    show DeltaEncoder, InputCommand, LagCompensator, PredictedMover;
export 'src/ui/text_3d.dart' show BitmapFont, TextMesh3D;
export 'src/world/terrain_extras.dart'
    show FoliageInstance, TerrainFoliage, TerrainSplatMap;

export 'src/physics/raycast_vehicle.dart';

export 'src/mesh/spline_mesh.dart';

export 'src/mesh/procedural_world.dart';

export 'src/gameplay/unity_components.dart';
export 'src/game/quick_game.dart';

export 'src/audio/voice_audio_engine.dart';

export 'src/gameplay/custom_controls.dart';
export 'src/anim/anim_state_machine.dart'
    show AnimStateNode, AnimStateTransition, AnimationStateMachine, BoneSocketComponent;
export 'src/gameplay/hud_canvas.dart'
    show HudCanvasComponent, HudWidgetSpec, HudWidgetType, VfxEmitterComponent, VfxPreset;
export 'src/gameplay/shooter_br_kit.dart'
    show
        BotAiState,
        EnemyBotAiComponent,
        HealthDamageComponent,
        LootSpawnerComponent,
        LootType,
        SafeZoneComponent,
        WeaponComponent,
        WeaponShotResult;
export 'src/gameplay/visual_script.dart'
    show VisualAction, VisualRule, VisualScriptComponent, VisualTrigger;
export 'src/net/multiplayer_room.dart'
    show MultiplayerRoomServer, MultiplayerSyncComponent, RoomPlayerState;
export 'src/world/terrain_sculpt.dart' show EditableTerrainComponent, TerrainLayer;
