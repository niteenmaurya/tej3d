#!/bin/sh
# Builds the native library for this computer into native/build/.
# Needs a C++17 compiler (g++ or clang++). For Android, iOS and Windows use
# their own toolchains with the same source files (see README.md).
set -e
cd "$(dirname "$0")"
mkdir -p build
EXTRA_LIBS=""
case "$(uname -s)" in
  Darwin) OUT=libtej3d.dylib ;;
  MINGW*|MSYS*|CYGWIN*) OUT=tej3d.dll ;;
  *) OUT=libtej3d.so; EXTRA_LIBS="-ldl" ;;
esac
${CXX:-c++} -std=c++17 -O2 -fPIC -shared -fvisibility=hidden -Iinclude -Isrc src/*.cpp -o "build/$OUT" $EXTRA_LIBS
echo "built native/build/$OUT"
echo "use it with:  TEJ3D_LIB=$(pwd)/build/$OUT flutter run"
