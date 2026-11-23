import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'bindings.dart';

/// Loads the native core (`libtej3d`) and gives access to its functions.
///
/// Lookup order: [libraryPath], the `TEJ3D_LIB` environment variable, then the
/// default name of the platform (iOS links the core into the app).
///
/// Status: tested against the real native library (`test/native_bridge_test.dart`).
class TejNative {
  TejNative._();

  /// Set before the first use to load the library from a path.
  static String? libraryPath;

  static TejBindings? _bindings;

  static TejBindings get api => _bindings ??= TejBindings(_open());

  /// True if the library can be loaded on this platform.
  static bool get isAvailable {
    try {
      api;
      return true;
    } catch (_) {
      return false;
    }
  }

  static DynamicLibrary _open() {
    final override = libraryPath ?? Platform.environment['TEJ3D_LIB'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) return DynamicLibrary.open('libtej3d.dylib');
    if (Platform.isWindows) return DynamicLibrary.open('tej3d.dll');
    return DynamicLibrary.open('libtej3d.so'); // Android and Linux
  }
}

/// Native memory that Dart can read and write as a typed list. Call
/// [dispose] when done.
class NativeFloats {
  NativeFloats(this.length) : ptr = TejNative.api.alloc(length * 4).cast<Float>();

  final int length;
  final Pointer<Float> ptr;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  Float32List get list => ptr.asTypedList(length);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    TejNative.api.free(ptr.cast());
  }
}

class NativeInt32s {
  NativeInt32s(this.length) : ptr = TejNative.api.alloc(length * 4).cast<Int32>();

  final int length;
  final Pointer<Int32> ptr;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  Int32List get list => ptr.asTypedList(length);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    TejNative.api.free(ptr.cast());
  }
}

class NativeUint32s {
  NativeUint32s(this.length) : ptr = TejNative.api.alloc(length * 4).cast<Uint32>();

  final int length;
  final Pointer<Uint32> ptr;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  Uint32List get list => ptr.asTypedList(length);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    TejNative.api.free(ptr.cast());
  }
}

class NativeBytes {
  NativeBytes(this.length) : ptr = TejNative.api.alloc(length).cast<Uint8>();

  final int length;
  final Pointer<Uint8> ptr;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  Uint8List get list => ptr.asTypedList(length);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    TejNative.api.free(ptr.cast());
  }
}
