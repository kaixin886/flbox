import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NoArg = Pointer<Utf8> Function();
typedef _OneArg = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);

class CoreException implements Exception {
  CoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class XrayNode {
  const XrayNode({required this.name, required this.type});

  final String name;
  final String type;
}

class SkippedNode {
  const SkippedNode({required this.name, required this.type, required this.reason});

  final String name;
  final String type;
  final String reason;
}

class XrayProfile {
  const XrayProfile({
    required this.nodes,
    required this.skipped,
    required this.configs,
  });

  final List<XrayNode> nodes;
  final List<SkippedNode> skipped;
  final Map<String, String> configs;
}

/// FFI bridge to libflbox.so. Xray trial surface only; the sing-box
/// exports stay unused until that engine is wired up.
class CoreBridge {
  CoreBridge._() {
    final lib = DynamicLibrary.open('libflbox.so');
    _xrayVersion = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayVersion');
    _xrayTranslate =
        lib.lookupFunction<_OneArg, _OneArg>('FlboxXrayTranslate');
    _xrayStart = lib.lookupFunction<_OneArg, _OneArg>('FlboxXrayStart');
    _xrayStop = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayStop');
    _xrayStatus = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayStatus');
    _lastError = lib.lookupFunction<_NoArg, _NoArg>('FlboxLastError');
    _free = lib.lookupFunction<_FreeNative, void Function(Pointer<Utf8>)>(
      'FlboxFree',
    );
  }

  static CoreBridge? _instance;

  factory CoreBridge() => _instance ??= CoreBridge._();

  late final _NoArg _xrayVersion;
  late final _OneArg _xrayTranslate;
  late final _OneArg _xrayStart;
  late final _NoArg _xrayStop;
  late final _NoArg _xrayStatus;
  late final _NoArg _lastError;
  late final void Function(Pointer<Utf8>) _free;

  String? _take(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return null;
    final value = ptr.toDartString();
    _free(ptr);
    return value;
  }

  String? _lastErrorText() => _take(_lastError());

  String xrayVersion() => _take(_xrayVersion()) ?? 'Xray (unknown)';

  XrayProfile translateXray(String clashYaml) {
    final arg = clashYaml.toNativeUtf8();
    final out = _take(_xrayTranslate(arg));
    malloc.free(arg);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'translate failed');
    }
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    final nodes = <XrayNode>[
      for (final n in decoded['nodes'] as List<dynamic>)
        XrayNode(
          name: (n as Map<String, dynamic>)['name'] as String,
          type: n['type'] as String,
        ),
    ];
    final skipped = <SkippedNode>[
      for (final n in (decoded['skipped'] as List<dynamic>? ?? []))
        SkippedNode(
          name: (n as Map<String, dynamic>)['name'] as String,
          type: n['type'] as String,
          reason: n['reason'] as String? ?? '',
        ),
    ];
    final configs = <String, String>{
      for (final e
          in (decoded['configs'] as Map<String, dynamic>).entries)
        e.key: e.value as String,
    };
    return XrayProfile(nodes: nodes, skipped: skipped, configs: configs);
  }

  /// Throws CoreException on failure. Starting replaces any running
  /// instance, which doubles as node switching.
  void xrayStart(String configJson) {
    final arg = configJson.toNativeUtf8();
    final err = _take(_xrayStart(arg));
    malloc.free(arg);
    if (err != null) throw CoreException(err);
  }

  void xrayStop() {
    final err = _take(_xrayStop());
    if (err != null) throw CoreException(err);
  }

  String xrayStatus() => _take(_xrayStatus()) ?? '(no status)';
}

/// Reads a picked profile file as text.
Future<String> readProfileFile(File file) => file.readAsString();
