/// `dart:ffi` 的公共小工具：C 内存分配与 UTF-8 往返。
///
/// 独立成文件的理由：`tflite_inference_engine.dart` 里有一份同功能的私有实现（`_Alloc` /
/// `_CString`）。本文件是新增代码用的共享版本，**没有**去改动声学模型那一份 ——
/// 那是一个已经过设备实测、且被 1000+ 断言覆盖的链路，改它换不来任何收益。
///
/// 平台注意：Android 上 `malloc`/`free` 走 `libc`（`DynamicLibrary.process()` 即可解析），
/// Windows 上要显式打开 `ucrtbase.dll` 或 `msvcrt.dll`。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// C 运行时分配器。
abstract final class NativeAlloc {
  static DynamicLibrary? _crt;
  static Pointer<NativeFunction<_MallocNative>>? _malloc;
  static Pointer<NativeFunction<_FreeNative>>? _free;

  static void _ensure() {
    if (_malloc != null) return;
    DynamicLibrary lib;
    if (Platform.isWindows) {
      try {
        lib = DynamicLibrary.open('ucrtbase.dll');
      } catch (_) {
        lib = DynamicLibrary.open('msvcrt.dll');
      }
    } else {
      lib = DynamicLibrary.process();
    }
    _crt = lib;
    _malloc = lib.lookup<NativeFunction<_MallocNative>>('malloc');
    _free = lib.lookup<NativeFunction<_FreeNative>>('free');
  }

  /// 分配 `bytes` 字节。失败抛 [StateError]（宿主内存耗尽属于不可恢复状态）。
  static Pointer<T> alloc<T extends NativeType>(int bytes, {bool zero = false}) {
    _ensure();
    if (bytes <= 0) {
      throw ArgumentError.value(bytes, 'bytes', '必须为正数');
    }
    final p = _malloc!.asFunction<_MallocDart>()(bytes);
    if (p == nullptr) {
      throw StateError('native allocation of $bytes bytes failed');
    }
    if (zero) {
      p.cast<Uint8>().asTypedList(bytes).fillRange(0, bytes, 0);
    }
    return p.cast<T>();
  }

  static void free(Pointer<NativeType> p) {
    if (p == nullptr) return;
    _ensure();
    _free!.asFunction<_FreeDart>()(p.cast<Void>());
  }
}

/// UTF-8 ↔ NUL 结尾 C 字符串。
abstract final class CString {
  /// 把 Dart 字符串编码成 NUL 结尾的原生缓冲。调用方负责 [free]。
  static Pointer<Char> toNative(String s) {
    final bytes = utf8.encode(s);
    final buf = NativeAlloc.alloc<Uint8>(bytes.length + 1, zero: true);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    buf[bytes.length] = 0;
    return buf.cast<Char>();
  }

  /// 读取 NUL 结尾的 C 字符串。`maxBytes` 是**防呆上限**，不是截断长度：
  /// 一个没有 NUL 结尾的坏指针不应该让进程一直读到越界。
  static String fromNative(Pointer<Char> p, {int maxBytes = 4096}) {
    if (p == nullptr) return '';
    final bytes = p.cast<Uint8>();
    final out = <int>[];
    for (var i = 0; i < maxBytes; i++) {
      final b = bytes[i];
      if (b == 0) break;
      out.add(b);
    }
    // allowMalformed：C 侧理论上已按字符边界截断，但解码不该因为一个坏字节而抛异常
    // —— 这里读到的只是"模型说了什么"，不是可信数据。
    return utf8.decode(out, allowMalformed: true);
  }

  static void free(Pointer<Char> p) => NativeAlloc.free(p);
}
