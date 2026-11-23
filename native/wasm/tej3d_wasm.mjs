/**
 * Browser/Node JavaScript wrapper around the Emscripten-compiled tej3d WASM module.
 * Zero third-party dependencies.
 */
export class Tej3DWasm {
  constructor(module) {
    this.m = module;
  }

  /**
   * Instantiates from an Emscripten factory function (default export of tej3d.mjs).
   */
  static async load(createModuleFactory, options = {}) {
    const mod = await createModuleFactory(options);
    return new Tej3DWasm(mod);
  }

  version() {
    return this.m._tej_version();
  }

  createWorld() {
    return this.m._tej_world_create();
  }

  destroyWorld(worldPtr) {
    this.m._tej_world_destroy(worldPtr);
  }

  updateWorld(worldPtr, dt) {
    this.m._tej_world_update(worldPtr, dt);
  }

  /**
   * Renders one RGBA frame into a Uint8Array of length width * height * 4.
   */
  renderSoftware(worldPtr, width, height) {
    const bytes = width * height * 4;
    const ptr = this.m._tej_alloc(bytes);
    try {
      this.m._tej_render_software(worldPtr, width, height, ptr);
      return new Uint8Array(this.m.HEAPU8.subarray(ptr, ptr + bytes));
    } finally {
      this.m._tej_free(ptr);
    }
  }
}
