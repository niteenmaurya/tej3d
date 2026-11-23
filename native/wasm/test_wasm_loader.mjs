import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Tej3DWasm } from './tej3d_wasm.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const headerPath = path.resolve(__dirname, '../include/tej3d.h');
const header = fs.readFileSync(headerPath, 'utf8');

// 1. Verify C API symbol extraction matches build_wasm.sh
const fns = [...header.matchAll(/TEJ_API\s+[\w\s*]+\b(tej_[a-zA-Z0-9_]+)\s*\(/g)].map((m) => m[1]);
assert.ok(fns.length >= 100, `Expected >= 100 exported C functions, got ${fns.length}`);
assert.ok(fns.includes('tej_body_set_convex_hull'), 'Missing tej_body_set_convex_hull');
assert.ok(fns.includes('tej_character_set_crouch'), 'Missing tej_character_set_crouch');

// 2. Verify Tej3DWasm wrapper against a mock Emscripten module
const heap = new Uint8Array(1024);
let freed = false;
const mockModule = {
  HEAPU8: heap,
  _tej_version: () => 14,
  _tej_world_create: () => 42,
  _tej_world_destroy: () => {},
  _tej_world_update: () => {},
  _tej_alloc: () => 16,
  _tej_free: () => { freed = true; },
  _tej_render_software: (_w, width, height, ptr) => {
    for (let i = 0; i < width * height * 4; i++) heap[ptr + i] = 200;
  },
};

const api = await Tej3DWasm.load(async () => mockModule);
assert.equal(api.version(), 14);
const w = api.createWorld();
assert.equal(w, 42);
const rgba = api.renderSoftware(w, 4, 4);
assert.equal(rgba.length, 64);
assert.equal(rgba[0], 200);
assert.equal(freed, true);
api.destroyWorld(w);

console.log(`PASS [native/wasm/test_wasm_loader.mjs]: ${fns.length} C API exports verified + Tej3DWasm wrapper OK`);
