import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NoArg = Pointer<Utf8> Function();
typedef _TranslateNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _TranslateAllNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _StartNative = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef _StartDart = Pointer<Utf8> Function(Pointer<Utf8>, int);
typedef _SetupNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _FwdStartNative = Pointer<Utf8> Function(Int32);
typedef _FwdStartDart = Pointer<Utf8> Function(int);
typedef _FwdActiveNative = Int32 Function();
typedef _FwdActiveDart = int Function();
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

/// One config holding every node, for parallel latency tests: each
/// node name maps to the local port that exits through it.
class XrayAllTest {
  const XrayAllTest({required this.config, required this.ports});

  final String config;
  final Map<String, int> ports;
}

/// FFI bridge to libflbox.so. Xray carries the proxying; sing-box
/// is wired in as the VPN tunnel's packet forwarder (0.23).
class CoreBridge {
  CoreBridge._() {
    final lib = DynamicLibrary.open('libflbox.so');
    _xrayVersion = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayVersion');
    _xrayTranslate = lib.lookupFunction<_TranslateNative, _TranslateNative>(
      'FlboxXrayTranslate',
    );
    _xrayTranslateAll = lib
        .lookupFunction<_TranslateAllNative, _TranslateAllNative>(
          'FlboxXrayTranslateAll',
        );
    _xrayStart = lib.lookupFunction<_StartNative, _StartDart>(
      'FlboxXrayStart',
    );
    _xrayStop = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayStop');
    _xrayStatus = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayStatus');
    _xrayTraffic = lib.lookupFunction<_NoArg, _NoArg>('FlboxXrayTraffic');
    _setup = lib.lookupFunction<_SetupNative, _SetupNative>('FlboxSetup');
    _fwdStart = lib.lookupFunction<_FwdStartNative, _FwdStartDart>(
      'FlboxVpnForwardStart',
    );
    _fwdStop = lib.lookupFunction<_NoArg, _NoArg>('FlboxVpnForwardStop');
    _fwdActive = lib.lookupFunction<_FwdActiveNative, _FwdActiveDart>(
      'FlboxVpnForwardActive',
    );
    _lastError = lib.lookupFunction<_NoArg, _NoArg>('FlboxLastError');
    _free = lib.lookupFunction<_FreeNative, void Function(Pointer<Utf8>)>(
      'FlboxFree',
    );
  }

  static CoreBridge? _instance;

  factory CoreBridge() => _instance ??= CoreBridge._();

  late final _SetupNative _setup;
  late final _FwdStartDart _fwdStart;
  late final _NoArg _fwdStop;
  late final _FwdActiveDart _fwdActive;
  late final _NoArg _xrayVersion;
  late final _TranslateNative _xrayTranslate;
  late final _TranslateAllNative _xrayTranslateAll;
  late final _StartDart _xrayStart;
  late final _NoArg _xrayStop;
  late final _NoArg _xrayStatus;
  late final _NoArg _xrayTraffic;
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

  XrayProfile translateXray(
    String clashYaml, {
    required bool vpn,
    required String logPath,
    bool rules = false,
  }) {
    final arg = clashYaml.toNativeUtf8();
    final mode =
        ((vpn ? 'vpn' : 'local') + (rules ? ':rules' : '')).toNativeUtf8();
    final log = logPath.toNativeUtf8();
    final out = _take(_xrayTranslate(arg, mode, log));
    malloc.free(arg);
    malloc.free(mode);
    malloc.free(log);
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

  XrayAllTest translateAllXray(String clashYaml, {required String logPath}) {
    final arg = clashYaml.toNativeUtf8();
    final log = logPath.toNativeUtf8();
    final out = _take(_xrayTranslateAll(arg, log));
    malloc.free(arg);
    malloc.free(log);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'translate-all failed');
    }
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    return XrayAllTest(
      config: decoded['config'] as String,
      ports: <String, int>{
        for (final e in (decoded['ports'] as Map<String, dynamic>).entries)
          e.key: e.value as int,
      },
    );
  }

  /// Throws CoreException on failure. Starting replaces any running
  /// instance, which doubles as node switching.
  void xrayStart(String configJson, int tunFd) {
    final arg = configJson.toNativeUtf8();
    final err = _take(_xrayStart(arg, tunFd));
    malloc.free(arg);
    if (err != null) throw CoreException(err);
  }

  void xrayStop() {
    final err = _take(_xrayStop());
    if (err != null) throw CoreException(err);
  }

  String xrayStatus() => _take(_xrayStatus()) ?? '(no status)';

  /// One-time libbox setup (paths must exist).
  void sbSetup(String basePath, String workingPath, String tempPath) {
    final a = basePath.toNativeUtf8();
    final b = workingPath.toNativeUtf8();
    final c = tempPath.toNativeUtf8();
    final err = _take(_setup(a, b, c));
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
    if (err != null) throw CoreException(err);
  }

  /// Starts the sing-box TUN forwarder on the VpnService's fd: it
  /// owns the packet path and feeds the Xray mixed inbound.
  void vpnForwardStart(int tunFd) {
    final err = _take(_fwdStart(tunFd));
    if (err != null) throw CoreException(err);
  }

  void vpnForwardStop() {
    final err = _take(_fwdStop());
    if (err != null) throw CoreException(err);
  }

  bool vpnForwardActive() => _fwdActive() != 0;

  /// Cumulative proxy traffic counters as JSON ({"up":n,"down":n}).
  String xrayTraffic() => _take(_xrayTraffic()) ?? '{"up":0,"down":0}';
}

/// Reads a picked profile file as text.
Future<String> readProfileFile(File file) => file.readAsString();
