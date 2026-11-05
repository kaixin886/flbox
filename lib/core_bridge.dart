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
typedef _BridgeConfigNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<Utf8>,
  Int32,
  Int32,
  Pointer<Utf8>,
);
typedef _BridgeConfigDart = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Utf8>,
);
typedef _StartNative = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef _StartDart = Pointer<Utf8> Function(Pointer<Utf8>, int);
typedef _SetupNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _FwdStartNative = Pointer<Utf8> Function(Int32, Int32);
typedef _FwdStartDart = Pointer<Utf8> Function(int, int);
typedef _FwdActiveNative = Int32 Function();
typedef _FwdActiveDart = int Function();
typedef _NodeDetailNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ParseLinksNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NodeUpsertNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
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

/// FFI bridge to libflbox.so. Xray carries the proxying; sing-box
/// is wired in as the VPN tunnel's packet forwarder (0.23).
class CoreBridge {
  CoreBridge._() {
    final lib = DynamicLibrary.open('libflbox.so');
    _xrayTranslate = lib.lookupFunction<_TranslateNative, _TranslateNative>(
      'FlboxXrayTranslate',
    );
    _bridgeConfig = lib
        .lookupFunction<_BridgeConfigNative, _BridgeConfigDart>(
          'FlboxBridgeXrayConfig',
        );
    _xrayStart = lib.lookupFunction<_StartNative, _StartDart>(
      'FlboxXrayStart',
    );
    _xrayMeasureDelay = lib
        .lookupFunction<_NodeDetailNative, _NodeDetailNative>(
          'FlboxXrayMeasureDelay',
        );
    _xrayMeasureAll = lib
        .lookupFunction<_NodeDetailNative, _NodeDetailNative>(
          'FlboxXrayMeasureAll',
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
    _nodeDetail = lib.lookupFunction<_NodeDetailNative, _NodeDetailNative>(
      'FlboxNodeDetail',
    );
    _nodeUpsert = lib.lookupFunction<_NodeUpsertNative, _NodeUpsertNative>(
      'FlboxNodeUpsert',
    );
    _nodeDelete = lib.lookupFunction<_NodeDetailNative, _NodeDetailNative>(
      'FlboxNodeDelete',
    );
    _nodeShare = lib.lookupFunction<_NodeDetailNative, _NodeDetailNative>(
      'FlboxNodeShare',
    );
    _filterNodes = lib.lookupFunction<_NodeUpsertNative, _NodeUpsertNative>(
      'FlboxFilterNodes',
    );
    _parseLinks = lib.lookupFunction<_ParseLinksNative, _ParseLinksNative>(
      'FlboxParseShareLinks',
    );
    _convertImport = lib.lookupFunction<_ParseLinksNative, _ParseLinksNative>(
      'FlboxConvertImport',
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
  late final _NodeDetailNative _nodeDetail;
  late final _NodeUpsertNative _nodeUpsert;
  late final _NodeDetailNative _nodeDelete;
  late final _NodeDetailNative _nodeShare;
  late final _NodeUpsertNative _filterNodes;
  late final _ParseLinksNative _parseLinks;
  late final _ParseLinksNative _convertImport;
  late final _TranslateNative _xrayTranslate;
  late final _BridgeConfigDart _bridgeConfig;
  late final _StartDart _xrayStart;
  late final _NodeDetailNative _xrayMeasureDelay;
  late final _NodeDetailNative _xrayMeasureAll;
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

  /// Builds the sing-box configuration for eBPF mode: the
  /// same pinned single node as the daemon modes, but the
  /// Builds the bridge-mode configuration pair as one
  /// JSON envelope: {"core": Xray config with a SOCKS
  /// inbound (0.66, AsteriskNG's pairing), "bridge":
  /// bpf2socks config}. mode is the bridge policy
  /// (2 global, 0 blacklist, 1 whitelist) and uids the
  /// resolved Android uids for the package split
  /// preferences.
  String bridgeXrayConfig(
    String clashYaml,
    String selectedNode, {
    required bool ipv6,
    required int mode,
    required List<int> uids,
    required int routeMode,
    required bool logOff,
    required String directDns,
  }) {
    final a = clashYaml.toNativeUtf8();
    final b = selectedNode.toNativeUtf8();
    final c = jsonEncode(uids).toNativeUtf8();
    final d = directDns.toNativeUtf8();
    final out = _take(
      _bridgeConfig(a, b, ipv6 ? 1 : 0, mode, c, routeMode, logOff ? 1 : 0, d),
    );
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
    malloc.free(d);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'bridge config failed');
    }
    return out;
  }

  XrayProfile translateXray(
    String clashYaml, {
    required bool vpn,
    required String logPath,
    int outMode = 1,
    bool logOff = false,
  }) {
    final arg = clashYaml.toNativeUtf8();
    final mode = ((vpn ? 'vpn' : 'local') +
            (outMode == 0
                ? ':rules'
                : outMode == 2
                    ? ':direct'
                    : '') +
            (logOff ? ':logoff' : ''))
        .toNativeUtf8();
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

  /// Measures one node's real latency in a single self-contained
  /// core call (the v2rayNG design): the core trims the config
  /// to its outbound essentials, starts a throwaway instance
  /// with no inbounds, probes [url] through the instance itself
  /// and closes it, all inside the call. Returns the best of two
  /// attempts in milliseconds, or -1 when the node did not
  /// answer; the failure detail is kept as the core's last
  /// error. Never throws for a failed node.
  int xrayMeasureDelay(String configJson, String url) {
    final a = configJson.toNativeUtf8();
    final b = url.toNativeUtf8();
    final res = _take(_xrayMeasureDelay(a, b));
    malloc.free(a);
    malloc.free(b);
    return int.tryParse(res ?? '') ?? -1;
  }

  /// Measures a whole chunk of nodes in ONE core instance
  /// (the Clash shape, see the Go side): [configsJson] is a
  /// JSON array of per-node config strings; the result is a
  /// JSON array of delays in the same order, -1 per failed
  /// node. Returns an empty string when the combined instance
  /// itself could not be built or started, which is the
  /// caller's cue to fall back to per-node measurement.
  String xrayMeasureAll(String configsJson, String url) {
    final a = configsJson.toNativeUtf8();
    final b = url.toNativeUtf8();
    final res = _take(_xrayMeasureAll(a, b));
    malloc.free(a);
    malloc.free(b);
    return res ?? '';
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
  void vpnForwardStart(int tunFd, {bool ipv6 = false}) {
    final err = _take(_fwdStart(tunFd, ipv6 ? 1 : 0));
    if (err != null) throw CoreException(err);
  }

  void vpnForwardStop() {
    final err = _take(_fwdStop());
    if (err != null) throw CoreException(err);
  }

  bool vpnForwardActive() => _fwdActive() != 0;

  /// The named node's raw fields from a profile's YAML, for the
  /// node editor form.
  Map<String, dynamic> nodeDetail(String yaml, String name) {
    final a = yaml.toNativeUtf8();
    final b = name.toNativeUtf8();
    final out = _take(_nodeDetail(a, b));
    malloc.free(a);
    malloc.free(b);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'node detail failed');
    }
    return jsonDecode(out) as Map<String, dynamic>;
  }

  /// Renders the node called [name] in [yaml] as its protocol
  /// share URI (vless://, hysteria2://, ...) for handing to
  /// another client.
  String nodeShareLink(String yaml, String name) {
    final a = yaml.toNativeUtf8();
    final c = name.toNativeUtf8();
    final out = _take(_nodeShare(a, c));
    malloc.free(a);
    malloc.free(c);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'node share failed');
    }
    return out;
  }

  /// Splices [entry] (typed JSON values) into the profile YAML:
  /// replaces the node named [originalName] (or the same-named
  /// node), else appends. Returns the rewritten YAML.
  String nodeUpsert(
    String yaml,
    Map<String, dynamic> entry,
    String originalName,
  ) {
    final a = yaml.toNativeUtf8();
    final b = jsonEncode(entry).toNativeUtf8();
    final c = originalName.toNativeUtf8();
    final out = _take(_nodeUpsert(a, b, c));
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'node upsert failed');
    }
    return out;
  }

  /// Applies keep/drop name regexes to a profile's node list
  /// (subscription update filters). Returns the rewritten YAML.
  String filterNodes(String yaml, String keep, String drop) {
    final a = yaml.toNativeUtf8();
    final b = keep.toNativeUtf8();
    final c = drop.toNativeUtf8();
    final out = _take(_filterNodes(a, b, c));
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'node filter failed');
    }
    return out;
  }

  /// Parses share links (vless/vmess/trojan/ss/hysteria2/
  /// wireguard, one per line, or a base64 blob of them) into
  /// editor-shaped node entries.
  /// Sniffs an imported file's format (Clash YAML passthrough,
  /// share-link lists, Xray JSON, sing-box JSON) and returns the
  /// normalised Clash YAML plus a kind tag.
  Map<String, dynamic> convertImport(String text) {
    final a = text.toNativeUtf8();
    final out = _take(_convertImport(a));
    malloc.free(a);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'import conversion failed');
    }
    return jsonDecode(out) as Map<String, dynamic>;
  }

  Map<String, dynamic> parseShareLinks(String text) {
    final a = text.toNativeUtf8();
    final out = _take(_parseLinks(a));
    malloc.free(a);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'share link parse failed');
    }
    return jsonDecode(out) as Map<String, dynamic>;
  }

  String nodeDelete(String yaml, String name) {
    final a = yaml.toNativeUtf8();
    final b = name.toNativeUtf8();
    final out = _take(_nodeDelete(a, b));
    malloc.free(a);
    malloc.free(b);
    if (out == null) {
      throw CoreException(_lastErrorText() ?? 'node delete failed');
    }
    return out;
  }

  /// Cumulative proxy traffic counters as JSON ({"up":n,"down":n}).
  String xrayTraffic() => _take(_xrayTraffic()) ?? '{"up":0,"down":0}';
}

/// Reads a picked profile file as text.
Future<String> readProfileFile(File file) => file.readAsString();
