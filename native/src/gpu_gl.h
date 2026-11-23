#pragma once
#include <cstdint>

namespace tej {

struct World;

// Zero-dependency dynamic OpenGL 3.3 / OpenGL ES 3.0 hardware GPU renderer bridge.
// Loads GL/EGL symbols dynamically at runtime (no GLEW, no GLAD, no GLFW).
// Automatically creates an offscreen EGL context + FBO when a GPU driver is present,
// and falls back seamlessly to renderSoftware() on headless CPU-only environments.
struct GpuGlBackend {
  bool initialized = false;
  bool available = false;
  bool ownsEgl = false;
  void* eglDisplay = nullptr;
  void* eglSurface = nullptr;
  void* eglContext = nullptr;
  uint32_t program = 0;
  uint32_t vao = 0;
  uint32_t vbo = 0;
  uint32_t ebo = 0;
  uint32_t fbo = 0;
  uint32_t colorRb = 0;
  uint32_t depthRb = 0;
  int fboW = 0;
  int fboH = 0;

  // Cached uniform locations
  int locVp = -1;
  int locModel = -1;
  int locNormalMat = -1;
  int locCamPos = -1;
  int locSkyTop = -1;
  int locSkyHor = -1;
  int locGround = -1;
  int locFogDensity = -1;
  int locFogColor = -1;
  int locSunDir = -1;
  int locSunColor = -1;
  int locColor = -1;
  int locMetallic = -1;
  int locRoughness = -1;
  int locClearcoat = -1;

  GpuGlBackend() = default;
  ~GpuGlBackend() { shutdown(); }
  GpuGlBackend(const GpuGlBackend&) = delete;
  GpuGlBackend& operator=(const GpuGlBackend&) = delete;

  bool init();
  void shutdown();
  bool render(const World& w, int width, int height, uint8_t* readbackRgba);
};

}  // namespace tej
