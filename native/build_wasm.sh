#!/usr/bin/env sh
# Builds the tej3d C++17 core to WebAssembly (ES module) using Emscripten (em++).
# Requires Emscripten SDK (emsdk) on PATH.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/build_wasm"
mkdir -p "$OUT_DIR"

# Collect every exported C API symbol from include/tej3d.h
EXPORTS="$(python3 -c '
import re, sys
h = open(sys.argv[1]).read()
fns = re.findall(r"TEJ_API\s+[\w\s\*]+\b(tej_[a-zA-Z0-9_]+)\s*\(", h)
print("[" + ",".join(f"\"_{f}\"" for f in fns) + "]")
' "$SCRIPT_DIR/include/tej3d.h")"

em++ -std=c++17 -O3 -fno-exceptions -fno-rtti \
  -I"$SCRIPT_DIR/include" -I"$SCRIPT_DIR/src" \
  "$SCRIPT_DIR"/src/*.cpp \
  -s WASM=1 \
  -s MODULARIZE=1 \
  -s EXPORT_ES6=1 \
  -s ENVIRONMENT=web,worker \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s EXPORTED_FUNCTIONS="$EXPORTS" \
  -s EXPORTED_RUNTIME_METHODS='["HEAPU8","HEAPF32","HEAP32","HEAPU32"]' \
  -o "$OUT_DIR/tej3d.mjs"

echo "Built $OUT_DIR/tej3d.mjs and $OUT_DIR/tej3d.wasm"
