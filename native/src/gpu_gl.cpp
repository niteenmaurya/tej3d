// Zero-dependency native Hardware GPU Bridge (OpenGL 3.3 Core / OpenGL ES 3.0 + Offscreen EGL FBO)
// for flutter_tej3d. Dynamically resolves GL & EGL symbols from host OS libraries at runtime
// (no GLEW, no GLAD, no GLFW). Falls back cleanly to C++17 software PBR when no GPU driver exists.
#include "gpu_gl.h"
#include "world.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#elif !defined(__EMSCRIPTEN__)
#  include <dlfcn.h>
#endif

namespace tej {

namespace {

using GLenum = unsigned int;
using GLuint = unsigned int;
using GLint = int;
using GLsizei = int;
using GLboolean = unsigned char;
using GLfloat = float;
using GLbitfield = unsigned int;
using GLchar = char;
using GLsizeiptr = ptrdiff_t;

constexpr GLenum kGlVertexShader = 0x8B31;
constexpr GLenum kGlFragmentShader = 0x8B30;
constexpr GLenum kGlCompileStatus = 0x8B81;
constexpr GLenum kGlLinkStatus = 0x8B82;
constexpr GLenum kGlArrayBuffer = 0x8892;
constexpr GLenum kGlElementArrayBuffer = 0x8893;
constexpr GLenum kGlDynamicDraw = 0x88E8;
constexpr GLenum kGlFloat = 0x1406;
constexpr GLenum kGlUnsignedInt = 0x1405;
constexpr GLenum kGlUnsignedByte = 0x1401;
constexpr GLenum kGlTriangles = 0x0004;
constexpr GLenum kGlDepthTest = 0x0B71;
constexpr GLenum kGlBlend = 0x0BE2;
constexpr GLenum kGlSrcAlpha = 0x0302;
constexpr GLenum kGlOneMinusSrcAlpha = 0x0303;
constexpr GLenum kGlRgba = 0x1908;
constexpr GLenum kGlRgba8 = 0x8058;
constexpr GLenum kGlDepthComponent24 = 0x81A6;
constexpr GLenum kGlFramebuffer = 0x8D40;
constexpr GLenum kGlRenderbuffer = 0x8D41;
constexpr GLenum kGlColorAttachment0 = 0x8CE0;
constexpr GLenum kGlDepthAttachment = 0x8D00;
constexpr GLenum kGlFramebufferComplete = 0x8CD5;
constexpr GLbitfield kGlColorBufferBit = 0x00004000;
constexpr GLbitfield kGlDepthBufferBit = 0x00000100;

struct GlProcs {
  void (*viewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
  void (*clearColor)(GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
  void (*clear)(GLbitfield) = nullptr;
  void (*enable)(GLenum) = nullptr;
  void (*disable)(GLenum) = nullptr;
  void (*blendFunc)(GLenum, GLenum) = nullptr;
  GLuint (*createShader)(GLenum) = nullptr;
  void (*shaderSource)(GLuint, GLsizei, const GLchar* const*, const GLint*) = nullptr;
  void (*compileShader)(GLuint) = nullptr;
  void (*getShaderiv)(GLuint, GLenum, GLint*) = nullptr;
  void (*deleteShader)(GLuint) = nullptr;
  GLuint (*createProgram)() = nullptr;
  void (*attachShader)(GLuint, GLuint) = nullptr;
  void (*linkProgram)(GLuint) = nullptr;
  void (*getProgramiv)(GLuint, GLenum, GLint*) = nullptr;
  void (*useProgram)(GLuint) = nullptr;
  void (*deleteProgram)(GLuint) = nullptr;
  GLint (*getUniformLocation)(GLuint, const GLchar*) = nullptr;
  void (*uniformMatrix3fv)(GLint, GLsizei, GLboolean, const GLfloat*) = nullptr;
  void (*uniformMatrix4fv)(GLint, GLsizei, GLboolean, const GLfloat*) = nullptr;
  void (*uniform3f)(GLint, GLfloat, GLfloat, GLfloat) = nullptr;
  void (*uniform4f)(GLint, GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
  void (*uniform1f)(GLint, GLfloat) = nullptr;
  void (*genVertexArrays)(GLsizei, GLuint*) = nullptr;
  void (*bindVertexArray)(GLuint) = nullptr;
  void (*deleteVertexArrays)(GLsizei, const GLuint*) = nullptr;
  void (*genBuffers)(GLsizei, GLuint*) = nullptr;
  void (*bindBuffer)(GLenum, GLuint) = nullptr;
  void (*bufferData)(GLenum, GLsizeiptr, const void*, GLenum) = nullptr;
  void (*deleteBuffers)(GLsizei, const GLuint*) = nullptr;
  void (*enableVertexAttribArray)(GLuint) = nullptr;
  void (*vertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*) = nullptr;
  void (*drawElements)(GLenum, GLsizei, GLenum, const void*) = nullptr;
  void (*readPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*) = nullptr;
  const unsigned char* (*getString)(GLenum) = nullptr;
  // Optional FBO procs for arbitrary-size offscreen rendering
  void (*genFramebuffers)(GLsizei, GLuint*) = nullptr;
  void (*bindFramebuffer)(GLenum, GLuint) = nullptr;
  void (*deleteFramebuffers)(GLsizei, const GLuint*) = nullptr;
  void (*genRenderbuffers)(GLsizei, GLuint*) = nullptr;
  void (*bindRenderbuffer)(GLenum, GLuint) = nullptr;
  void (*renderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei) = nullptr;
  void (*framebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint) = nullptr;
  void (*deleteRenderbuffers)(GLsizei, const GLuint*) = nullptr;
  GLenum (*checkFramebufferStatus)(GLenum) = nullptr;
};

static GlProcs gGl;
static std::once_flag gGlOnce;
static bool gGlOk = false;

void* loadGlSym(const char* name) {
#if defined(__EMSCRIPTEN__)
  (void)name;
  return nullptr;
#elif defined(_WIN32)
  static HMODULE mod = LoadLibraryA("opengl32.dll");
  if (!mod) return nullptr;
  using WglGetProc = void* (__stdcall*)(const char*);
  static WglGetProc wglGet = reinterpret_cast<WglGetProc>(GetProcAddress(mod, "wglGetProcAddress"));
  void* p = wglGet ? wglGet(name) : nullptr;
  if (!p) p = reinterpret_cast<void*>(GetProcAddress(mod, name));
  return p;
#else
  static void* lib = []() -> void* {
    void* h = dlopen("libGLESv2.so.2", RTLD_LAZY | RTLD_LOCAL);
    if (!h) h = dlopen("libGL.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!h) h = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    return h;
  }();
  return lib ? dlsym(lib, name) : nullptr;
#endif
}

template <typename Fn>
bool bindSym(Fn& out, const char* name) {
  void* p = loadGlSym(name);
  std::memcpy(&out, &p, sizeof(out));
  return p != nullptr;
}

bool loadAllGlProcs() {
  std::call_once(gGlOnce, []() {
    bool ok = true;
    ok &= bindSym(gGl.viewport, "glViewport");
    ok &= bindSym(gGl.clearColor, "glClearColor");
    ok &= bindSym(gGl.clear, "glClear");
    ok &= bindSym(gGl.enable, "glEnable");
    ok &= bindSym(gGl.disable, "glDisable");
    ok &= bindSym(gGl.blendFunc, "glBlendFunc");
    ok &= bindSym(gGl.createShader, "glCreateShader");
    ok &= bindSym(gGl.shaderSource, "glShaderSource");
    ok &= bindSym(gGl.compileShader, "glCompileShader");
    ok &= bindSym(gGl.getShaderiv, "glGetShaderiv");
    ok &= bindSym(gGl.deleteShader, "glDeleteShader");
    ok &= bindSym(gGl.createProgram, "glCreateProgram");
    ok &= bindSym(gGl.attachShader, "glAttachShader");
    ok &= bindSym(gGl.linkProgram, "glLinkProgram");
    ok &= bindSym(gGl.getProgramiv, "glGetProgramiv");
    ok &= bindSym(gGl.useProgram, "glUseProgram");
    ok &= bindSym(gGl.deleteProgram, "glDeleteProgram");
    ok &= bindSym(gGl.getUniformLocation, "glGetUniformLocation");
    ok &= bindSym(gGl.uniformMatrix3fv, "glUniformMatrix3fv");
    ok &= bindSym(gGl.uniformMatrix4fv, "glUniformMatrix4fv");
    ok &= bindSym(gGl.uniform3f, "glUniform3f");
    ok &= bindSym(gGl.uniform4f, "glUniform4f");
    ok &= bindSym(gGl.uniform1f, "glUniform1f");
    ok &= bindSym(gGl.genVertexArrays, "glGenVertexArrays");
    ok &= bindSym(gGl.bindVertexArray, "glBindVertexArray");
    ok &= bindSym(gGl.deleteVertexArrays, "glDeleteVertexArrays");
    ok &= bindSym(gGl.genBuffers, "glGenBuffers");
    ok &= bindSym(gGl.bindBuffer, "glBindBuffer");
    ok &= bindSym(gGl.bufferData, "glBufferData");
    ok &= bindSym(gGl.deleteBuffers, "glDeleteBuffers");
    ok &= bindSym(gGl.enableVertexAttribArray, "glEnableVertexAttribArray");
    ok &= bindSym(gGl.vertexAttribPointer, "glVertexAttribPointer");
    ok &= bindSym(gGl.drawElements, "glDrawElements");
    ok &= bindSym(gGl.readPixels, "glReadPixels");
    ok &= bindSym(gGl.getString, "glGetString");
    // Optional FBO procs
    bindSym(gGl.genFramebuffers, "glGenFramebuffers");
    bindSym(gGl.bindFramebuffer, "glBindFramebuffer");
    bindSym(gGl.deleteFramebuffers, "glDeleteFramebuffers");
    bindSym(gGl.genRenderbuffers, "glGenRenderbuffers");
    bindSym(gGl.bindRenderbuffer, "glBindRenderbuffer");
    bindSym(gGl.renderbufferStorage, "glRenderbufferStorage");
    bindSym(gGl.framebufferRenderbuffer, "glFramebufferRenderbuffer");
    bindSym(gGl.deleteRenderbuffers, "glDeleteRenderbuffers");
    bindSym(gGl.checkFramebufferStatus, "glCheckFramebufferStatus");
    gGlOk = ok;
  });
  return gGlOk;
}

#if !defined(_WIN32) && !defined(__EMSCRIPTEN__) && !defined(__APPLE__)
// Zero-dependency dynamic EGL offscreen context loader (Linux / Android).
struct EglProcs {
  void* (*getDisplay)(void*) = nullptr;
  unsigned int (*initialize)(void*, int*, int*) = nullptr;
  unsigned int (*chooseConfig)(void*, const int*, void**, int, int*) = nullptr;
  unsigned int (*bindApi)(unsigned int) = nullptr;
  void* (*createPbufferSurface)(void*, void*, const int*) = nullptr;
  void* (*createContext)(void*, void*, void*, const int*) = nullptr;
  unsigned int (*makeCurrent)(void*, void*, void*, void*) = nullptr;
  unsigned int (*destroyContext)(void*, void*) = nullptr;
  unsigned int (*destroySurface)(void*, void*) = nullptr;
  unsigned int (*terminate)(void*) = nullptr;
};
static EglProcs gEgl;
static std::once_flag gEglOnce;
static bool gEglOk = false;

bool loadEglProcs() {
  std::call_once(gEglOnce, []() {
    void* lib = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) lib = dlopen("libEGL.so", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) return;
    auto b = [&](auto& fn, const char* name) {
      void* p = dlsym(lib, name);
      std::memcpy(&fn, &p, sizeof(fn));
      return p != nullptr;
    };
    bool ok = true;
    ok &= b(gEgl.getDisplay, "eglGetDisplay");
    ok &= b(gEgl.initialize, "eglInitialize");
    ok &= b(gEgl.chooseConfig, "eglChooseConfig");
    ok &= b(gEgl.bindApi, "eglBindAPI");
    ok &= b(gEgl.createPbufferSurface, "eglCreatePbufferSurface");
    ok &= b(gEgl.createContext, "eglCreateContext");
    ok &= b(gEgl.makeCurrent, "eglMakeCurrent");
    ok &= b(gEgl.destroyContext, "eglDestroyContext");
    ok &= b(gEgl.destroySurface, "eglDestroySurface");
    ok &= b(gEgl.terminate, "eglTerminate");
    if (!ok) gEgl.getDisplay = nullptr;
    gEglOk = ok;
  });
  return gEglOk;
}

bool createOffscreenEgl(GpuGlBackend& b) {
  if (!loadEglProcs()) return false;
  void* dpy = gEgl.getDisplay(nullptr /* EGL_DEFAULT_DISPLAY */);
  if (!dpy) return false;
  int maj = 0, min = 0;
  if (!gEgl.initialize(dpy, &maj, &min)) return false;
  const int cfgAttribs[] = {
    0x3033, 0x0001, // EGL_SURFACE_TYPE, EGL_PBUFFER_BIT
    0x3040, 0x0040, // EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT
    0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // R8 G8 B8 A8
    0x3025, 24, // EGL_DEPTH_SIZE, 24
    0x3038 // EGL_NONE
  };
  void* cfg = nullptr;
  int numCfg = 0;
  if (!gEgl.chooseConfig(dpy, cfgAttribs, &cfg, 1, &numCfg) || numCfg < 1) {
    gEgl.terminate(dpy);
    return false;
  }
  gEgl.bindApi(0x30A0 /* EGL_OPENGL_ES_API */);
  const int pbufAttribs[] = { 0x3057, 16, 0x3056, 16, 0x3038 }; // WIDTH, HEIGHT, NONE
  void* surf = gEgl.createPbufferSurface(dpy, cfg, pbufAttribs);
  const int ctxAttribs[] = { 0x3098, 3, 0x3038 }; // EGL_CONTEXT_CLIENT_VERSION, 3, NONE
  void* ctx = gEgl.createContext(dpy, cfg, nullptr, ctxAttribs);
  if (!surf || !ctx || !gEgl.makeCurrent(dpy, surf, surf, ctx)) {
    if (ctx) gEgl.destroyContext(dpy, ctx);
    if (surf) gEgl.destroySurface(dpy, surf);
    gEgl.terminate(dpy);
    return false;
  }
  b.eglDisplay = dpy;
  b.eglSurface = surf;
  b.eglContext = ctx;
  b.ownsEgl = true;
  return true;
}
#endif

static const char* kVertSrc = R"GLSL(
#version 300 es
layout(location=0) in vec3 aPos;
layout(location=1) in vec3 aNorm;
layout(location=2) in vec2 aUv;
uniform mat4 uModel;
uniform mat3 uNormalMat;
uniform mat4 uVp;
out vec3 vWp;
out vec3 vN;
out vec2 vUv;
void main() {
  vec4 wp = uModel * vec4(aPos, 1.0);
  vWp = wp.xyz;
  vN = uNormalMat * aNorm;
  vUv = aUv;
  gl_Position = uVp * wp;
}
)GLSL";

static const char* kFragSrc = R"GLSL(
#version 300 es
precision highp float;
in vec3 vWp;
in vec3 vN;
in vec2 vUv;
uniform vec4 uColor;
uniform vec3 uCamPos;
uniform vec3 uSunDir;
uniform vec3 uSunColor;
uniform vec3 uSkyTop;
uniform vec3 uSkyHor;
uniform vec3 uGround;
uniform float uMetallic;
uniform float uRoughness;
uniform float uClearcoat;
uniform float uFogDensity;
uniform vec3 uFogColor;
out vec4 fragColor;
void main() {
  vec3 N = normalize(vN);
  vec3 V = normalize(uCamPos - vWp);
  vec3 L = normalize(-uSunDir);
  vec3 lv = L + V;
  vec3 H = length(lv) > 1e-5 ? normalize(lv) : N;
  float ndv = max(dot(N, V), 0.001);
  float ndl = max(dot(N, L), 0.0);
  float ndh = max(dot(N, H), 0.0);
  float r = clamp(uRoughness, 0.04, 1.0);
  float a2 = r * r * r * r;
  float den = ndh * ndh * (a2 - 1.0) + 1.0;
  float D = a2 / (3.14159265 * den * den + 1e-6);
  float fPow = pow(1.0 - max(dot(H, V), 0.0), 5.0);
  vec3 F0 = mix(vec3(0.04), uColor.rgb, uMetallic);
  vec3 F = F0 + (1.0 - F0) * fPow;
  vec3 spec = F * D * 0.25;
  vec3 kD = (1.0 - F) * (1.0 - uMetallic);
  vec3 direct = (kD * uColor.rgb / 3.14159265 + spec) * uSunColor * ndl;
  vec3 R = reflect(-V, N);
  if (uColor.a < 0.05) discard;
  vec3 env = R.y >= 0.0 ? mix(uSkyHor, uSkyTop, pow(clamp(R.y, 0.0, 1.0), 0.52)) : mix(uSkyHor * 0.5, uGround, clamp(-R.y, 0.0, 1.0));
  float sunHalo = max(dot(normalize(R), L), 0.0);
  env += uSunColor * (pow(sunHalo, 14.0) * 0.35 + pow(sunHalo, 160.0) * 1.4);
  vec3 col = mix(uGround, uSkyTop, N.y * 0.5 + 0.5) * uColor.rgb * 0.35 + F * env * (1.0 - r * 0.6) + direct;
  if (uClearcoat > 0.01) {
    float fc = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
    col = col * (1.0 - fc * uClearcoat) + env * (fc * uClearcoat);
  }
  if (uFogDensity > 1e-5) {
    float dist = length(uCamPos - vWp);
    float fog = 1.0 - exp(-dist * uFogDensity);
    col = mix(col, uFogColor, clamp(fog, 0.0, 0.92));
  }
  col = clamp((col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14), 0.0, 1.0);
  fragColor = vec4(pow(col, vec3(1.0 / 2.2)), uColor.a);
}
)GLSL";

void computeNormalMat3(const M4& xf, float out[9]) {
  auto A = [&](int r, int c) { return xf.m[c * 4 + r]; };
  float c00 = A(1, 1) * A(2, 2) - A(1, 2) * A(2, 1);
  float c01 = -(A(1, 0) * A(2, 2) - A(1, 2) * A(2, 0));
  float c02 = A(1, 0) * A(2, 1) - A(1, 1) * A(2, 0);
  float c10 = -(A(0, 1) * A(2, 2) - A(0, 2) * A(2, 1));
  float c11 = A(0, 0) * A(2, 2) - A(0, 2) * A(2, 0);
  float c12 = -(A(0, 0) * A(2, 1) - A(0, 1) * A(2, 0));
  float c20 = A(0, 1) * A(1, 2) - A(0, 2) * A(1, 1);
  float c21 = -(A(0, 0) * A(1, 2) - A(0, 2) * A(1, 0));
  float c22 = A(0, 0) * A(1, 1) - A(0, 1) * A(1, 0);
  float det = A(0, 0) * c00 + A(0, 1) * c01 + A(0, 2) * c02;
  if (std::fabs(det) > 1e-20f) {
    float id = 1.0f / det;
    // OpenGL mat3 is column-major: col c holds (c_{0,c}, c_{1,c}, c_{2,c}) * id
    out[0] = c00 * id; out[1] = c10 * id; out[2] = c20 * id;
    out[3] = c01 * id; out[4] = c11 * id; out[5] = c21 * id;
    out[6] = c02 * id; out[7] = c12 * id; out[8] = c22 * id;
  } else {
    out[0] = A(0, 0); out[1] = A(1, 0); out[2] = A(2, 0);
    out[3] = A(0, 1); out[4] = A(1, 1); out[5] = A(2, 1);
    out[6] = A(0, 2); out[7] = A(1, 2); out[8] = A(2, 2);
  }
}

bool ensureOffscreenFbo(GpuGlBackend& b, int w, int h) {
  if (!gGl.genFramebuffers || !gGl.bindFramebuffer || !gGl.genRenderbuffers ||
      !gGl.bindRenderbuffer || !gGl.renderbufferStorage ||
      !gGl.framebufferRenderbuffer || !gGl.checkFramebufferStatus) {
    return false;
  }
  if (b.fbo && b.fboW == w && b.fboH == h) {
    gGl.bindFramebuffer(kGlFramebuffer, b.fbo);
    return true;
  }
  if (!b.fbo) gGl.genFramebuffers(1, &b.fbo);
  if (!b.colorRb) gGl.genRenderbuffers(1, &b.colorRb);
  if (!b.depthRb) gGl.genRenderbuffers(1, &b.depthRb);

  gGl.bindFramebuffer(kGlFramebuffer, b.fbo);
  gGl.bindRenderbuffer(kGlRenderbuffer, b.colorRb);
  gGl.renderbufferStorage(kGlRenderbuffer, kGlRgba8, w, h);
  gGl.framebufferRenderbuffer(kGlFramebuffer, kGlColorAttachment0, kGlRenderbuffer, b.colorRb);

  gGl.bindRenderbuffer(kGlRenderbuffer, b.depthRb);
  gGl.renderbufferStorage(kGlRenderbuffer, kGlDepthComponent24, w, h);
  gGl.framebufferRenderbuffer(kGlFramebuffer, kGlDepthAttachment, kGlRenderbuffer, b.depthRb);

  if (gGl.checkFramebufferStatus(kGlFramebuffer) != kGlFramebufferComplete) {
    gGl.bindFramebuffer(kGlFramebuffer, 0);
    return false;
  }
  b.fboW = w;
  b.fboH = h;
  return true;
}

}  // namespace

bool GpuGlBackend::init() {
  if (initialized) return available;
  initialized = true;
  available = false;

  if (!loadAllGlProcs()) return false;
  if (!gGl.getString(0x1F02 /* GL_VERSION */)) {
#if !defined(_WIN32) && !defined(__EMSCRIPTEN__) && !defined(__APPLE__)
    if (!createOffscreenEgl(*this)) return false;
    if (!gGl.getString(0x1F02)) { shutdown(); return false; }
#else
    return false;
#endif
  }

  auto compile = [](GLenum type, const char* src) -> GLuint {
    GLuint s = gGl.createShader(type);
    gGl.shaderSource(s, 1, &src, nullptr);
    gGl.compileShader(s);
    GLint ok = 0;
    gGl.getShaderiv(s, kGlCompileStatus, &ok);
    if (!ok) { gGl.deleteShader(s); return 0; }
    return s;
  };

  GLuint vs = compile(kGlVertexShader, kVertSrc);
  GLuint fs = compile(kGlFragmentShader, kFragSrc);
  if (!vs || !fs) {
    if (vs) gGl.deleteShader(vs);
    if (fs) gGl.deleteShader(fs);
    shutdown();
    return false;
  }

  program = gGl.createProgram();
  gGl.attachShader(program, vs);
  gGl.attachShader(program, fs);
  gGl.linkProgram(program);
  gGl.deleteShader(vs);
  gGl.deleteShader(fs);

  GLint linked = 0;
  gGl.getProgramiv(program, kGlLinkStatus, &linked);
  if (!linked) {
    gGl.deleteProgram(program);
    program = 0;
    shutdown();
    return false;
  }

  locVp = gGl.getUniformLocation(program, "uVp");
  locModel = gGl.getUniformLocation(program, "uModel");
  locNormalMat = gGl.getUniformLocation(program, "uNormalMat");
  locCamPos = gGl.getUniformLocation(program, "uCamPos");
  locSkyTop = gGl.getUniformLocation(program, "uSkyTop");
  locSkyHor = gGl.getUniformLocation(program, "uSkyHor");
  locGround = gGl.getUniformLocation(program, "uGround");
  locFogDensity = gGl.getUniformLocation(program, "uFogDensity");
  locFogColor = gGl.getUniformLocation(program, "uFogColor");
  locSunDir = gGl.getUniformLocation(program, "uSunDir");
  locSunColor = gGl.getUniformLocation(program, "uSunColor");
  locColor = gGl.getUniformLocation(program, "uColor");
  locMetallic = gGl.getUniformLocation(program, "uMetallic");
  locRoughness = gGl.getUniformLocation(program, "uRoughness");
  locClearcoat = gGl.getUniformLocation(program, "uClearcoat");

  gGl.genVertexArrays(1, &vao);
  gGl.genBuffers(1, &vbo);
  gGl.genBuffers(1, &ebo);
  available = true;
  return true;
}

void GpuGlBackend::shutdown() {
#if !defined(_WIN32) && !defined(__EMSCRIPTEN__) && !defined(__APPLE__)
  if (ownsEgl && eglDisplay && eglSurface && eglContext && gEgl.makeCurrent) {
    gEgl.makeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
  }
#endif
  if (available) {
    if (fbo && gGl.deleteFramebuffers) gGl.deleteFramebuffers(1, &fbo);
    if (colorRb && gGl.deleteRenderbuffers) gGl.deleteRenderbuffers(1, &colorRb);
    if (depthRb && gGl.deleteRenderbuffers) gGl.deleteRenderbuffers(1, &depthRb);
    if (ebo && gGl.deleteBuffers) gGl.deleteBuffers(1, &ebo);
    if (vbo && gGl.deleteBuffers) gGl.deleteBuffers(1, &vbo);
    if (vao && gGl.deleteVertexArrays) gGl.deleteVertexArrays(1, &vao);
    if (program && gGl.deleteProgram) gGl.deleteProgram(program);
  }
#if !defined(_WIN32) && !defined(__EMSCRIPTEN__) && !defined(__APPLE__)
  if (ownsEgl && eglDisplay) {
    gEgl.makeCurrent(eglDisplay, nullptr, nullptr, nullptr);
    if (eglContext) gEgl.destroyContext(eglDisplay, eglContext);
    if (eglSurface) gEgl.destroySurface(eglDisplay, eglSurface);
    gEgl.terminate(eglDisplay);
  }
#endif
  eglDisplay = eglSurface = eglContext = nullptr;
  ownsEgl = false;
  program = vao = vbo = ebo = fbo = colorRb = depthRb = 0;
  fboW = fboH = 0;
  locVp = locModel = locNormalMat = locCamPos = locSkyTop = locSkyHor = locGround = -1;
  locFogDensity = locFogColor = locSunDir = locSunColor = locColor = locMetallic = locRoughness = locClearcoat = -1;
  available = false;
  initialized = false;
}

bool GpuGlBackend::render(const World& w, int width, int height, uint8_t* readbackRgba) {
  if (!available && !init()) return false;
#if !defined(_WIN32) && !defined(__EMSCRIPTEN__) && !defined(__APPLE__)
  if (ownsEgl && eglDisplay) {
    gEgl.makeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
  }
#endif
  const bool useFbo = ensureOffscreenFbo(*this, width, height);
  if (ownsEgl && !useFbo) return false;

  const Camera& cam = w.camera;
  M4 view = cam.useMatrices ? cam.view : lookAt(cam.pos, cam.target, cam.up);
  M4 proj = cam.useMatrices ? cam.proj : perspective(cam.fovY, (float)width / std::max(1, height), cam.nearZ, cam.farZ);
  M4 vp = proj * view;

  gGl.viewport(0, 0, width, height);
  gGl.clearColor(w.env.skyHorizon.x, w.env.skyHorizon.y, w.env.skyHorizon.z, 1.0f);
  gGl.clear(kGlColorBufferBit | kGlDepthBufferBit);
  gGl.enable(kGlDepthTest);
  gGl.enable(kGlBlend);
  gGl.blendFunc(kGlSrcAlpha, kGlOneMinusSrcAlpha);

  gGl.useProgram(program);
  gGl.uniformMatrix4fv(locVp, 1, 0, vp.m);
  gGl.uniform3f(locCamPos, cam.pos.x, cam.pos.y, cam.pos.z);
  gGl.uniform3f(locSkyTop, w.env.skyTop.x, w.env.skyTop.y, w.env.skyTop.z);
  gGl.uniform3f(locSkyHor, w.env.skyHorizon.x, w.env.skyHorizon.y, w.env.skyHorizon.z);
  gGl.uniform3f(locGround, w.env.ground.x, w.env.ground.y, w.env.ground.z);
  gGl.uniform1f(locFogDensity, w.env.fogDensity);
  gGl.uniform3f(locFogColor, w.env.fogColor.x, w.env.fogColor.y, w.env.fogColor.z);

  V3 sunDir(0.0f, -1.0f, 0.0f), sunCol(1.0f, 0.95f, 0.85f);
  for (const Light& L : w.lights) {
    if (L.alive && L.type == 0) { sunDir = L.vec; sunCol = L.color * L.intensity; break; }
  }
  gGl.uniform3f(locSunDir, sunDir.x, sunDir.y, sunDir.z);
  gGl.uniform3f(locSunColor, sunCol.x, sunCol.y, sunCol.z);

  gGl.bindVertexArray(vao);
  for (const Instance& in : w.instances) {
    if (!in.alive || !in.visible || in.shadowOnly || in.mesh < 0 || in.mesh >= (int)w.meshes.size()) continue;
    const Mesh& m = w.meshes[in.mesh];
    if (m.verts.empty() || m.idx.empty()) continue;

    float normalMat[9];
    computeNormalMat3(in.xf, normalMat);
    float effAlpha = std::clamp(in.alpha * in.color[3], 0.0f, 1.0f);

    gGl.uniformMatrix4fv(locModel, 1, 0, in.xf.m);
    gGl.uniformMatrix3fv(locNormalMat, 1, 0, normalMat);
    gGl.uniform4f(locColor, in.color[0], in.color[1], in.color[2], effAlpha);
    gGl.uniform1f(locMetallic, in.metallic);
    gGl.uniform1f(locRoughness, in.roughness);
    gGl.uniform1f(locClearcoat, in.clearcoat);

    gGl.bindBuffer(kGlArrayBuffer, vbo);
    gGl.bufferData(kGlArrayBuffer, (GLsizeiptr)(m.verts.size() * sizeof(float)), m.verts.data(), kGlDynamicDraw);
    gGl.bindBuffer(kGlElementArrayBuffer, ebo);
    gGl.bufferData(kGlElementArrayBuffer, (GLsizeiptr)(m.idx.size() * sizeof(uint32_t)), m.idx.data(), kGlDynamicDraw);

    gGl.enableVertexAttribArray(0);
    gGl.vertexAttribPointer(0, 3, kGlFloat, 0, 8 * sizeof(float), (const void*)0);
    gGl.enableVertexAttribArray(1);
    gGl.vertexAttribPointer(1, 3, kGlFloat, 0, 8 * sizeof(float), (const void*)(3 * sizeof(float)));
    gGl.enableVertexAttribArray(2);
    gGl.vertexAttribPointer(2, 2, kGlFloat, 0, 8 * sizeof(float), (const void*)(6 * sizeof(float)));

    gGl.drawElements(kGlTriangles, (GLsizei)m.idx.size(), kGlUnsignedInt, nullptr);
  }

  if (readbackRgba) {
    gGl.readPixels(0, 0, width, height, kGlRgba, kGlUnsignedByte, readbackRgba);
    // Flip rows vertically (OpenGL origin is bottom-left; Flutter/PNG origin is top-left)
    const size_t rowBytes = (size_t)width * 4;
    std::vector<uint8_t> tmp(rowBytes);
    for (int y = 0; y < height / 2; y++) {
      uint8_t* top = readbackRgba + (size_t)y * rowBytes;
      uint8_t* bot = readbackRgba + (size_t)(height - 1 - y) * rowBytes;
      std::memcpy(tmp.data(), top, rowBytes);
      std::memcpy(top, bot, rowBytes);
      std::memcpy(bot, tmp.data(), rowBytes);
    }
  }
  if (useFbo && gGl.bindFramebuffer) gGl.bindFramebuffer(kGlFramebuffer, 0);
  return true;
}

}  // namespace tej
