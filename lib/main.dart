import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'core_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // True background subscription updates (netproxy-style): an
  // hourly WorkManager check refreshes due subscriptions even
  // when the app is closed. Best-effort by design — the in-app
  // due-check (startup + timer) covers the rest, and scheduling
  // failures must never block startup.
  try {
    Workmanager().initialize(flboxBgDispatcher);
    Workmanager().registerPeriodicTask(
      'flbox-sub-auto-update',
      'subAutoUpdate',
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  } catch (_) {}
  runApp(const FlboxApp());
}

/// WorkManager entry point (runs in a background isolate). It can
/// only touch files and preferences; the UI picks the changes up
/// through the bg_subs_changed flag on next launch/resume.
@pragma('vm:entry-point')
void flboxBgDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await _bgRefreshDueSubs();
    } catch (_) {}
    return true;
  });
}

Future<void> _bgRefreshDueSubs() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('subs_v2');
  if (raw == null) return;
  final subs = [
    for (final e in jsonDecode(raw) as List)
      SubProfile.fromJson(e as Map<String, dynamic>),
  ];
  final docs = await getApplicationDocumentsDirectory();
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  var changed = false;
  final updatedNames = <String>[];
  for (final sub in subs) {
    if (!sub.enabled || !sub.autoUpdate || sub.url == null || sub.updateViaProxy) {
      continue;
    }
    if (nowMs - sub.updatedAtMs <= sub.autoIntervalHours * 3600000) {
      continue;
    }
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    try {
      client.userAgent = sub.ua;
      final request = await client
          .getUrl(Uri.parse(sub.url!))
          .timeout(const Duration(seconds: 20));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) continue;
      var text = await response.transform(utf8.decoder).join();
      final subInfo = formatSubInfoText(
        response.headers.value('subscription-userinfo'),
      );
      // Updates may arrive in any importable format (link lists,
      // vendor JSON), not just Clash YAML: normalise first, like
      // the foreground path does.
      text = CoreBridge().convertImport(text)['yaml'] as String;
      if (sub.keepRegex.isNotEmpty || sub.dropRegex.isNotEmpty) {
        text = CoreBridge().filterNodes(text, sub.keepRegex, sub.dropRegex);
      }
      final profile = CoreBridge().translateXray(
        text,
        vpn: true,
        logPath: '',
        outMode: 1,
      );
      if (profile.nodes.isEmpty) continue;
      await File('${docs.path}/sub_${sub.id}.yaml').writeAsString(text);
      sub.nodeCount = profile.nodes.length;
      if (subInfo != null) sub.subInfo = subInfo;
      sub.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      changed = true;
      updatedNames.add(sub.name);
    } catch (_) {
      continue;
    } finally {
      client.close(force: true);
    }
  }
  if (changed) {
    await prefs.setString(
      'subs_v2',
      jsonEncode([for (final s in subs) s.toJson()]),
    );
    await prefs.setString('bg_updated_names', jsonEncode(updatedNames));
    await prefs.setBool('bg_subs_changed', true);
  }
}

/// Formats a subscription-userinfo header value for display.
/// Top-level so the background updater can use it too.
String? formatSubInfoText(String? raw) {
  if (raw == null) return null;
  final kv = <String, String>{};
  for (final part in raw.split(';')) {
    final eq = part.indexOf('=');
    if (eq > 0) {
      kv[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
  }
  final up = double.tryParse(kv['upload'] ?? '');
  final down = double.tryParse(kv['download'] ?? '');
  final total = double.tryParse(kv['total'] ?? '');
  if (up == null || down == null || total == null || total <= 0) {
    return null;
  }
  String gb(double bytes) => (bytes / 1073741824)
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'\.?0+$'), '');
  var out = '已用 ${gb(up + down)} / 共 ${gb(total)} GB';
  final expire = int.tryParse(kv['expire'] ?? '');
  if (expire != null && expire > 0) {
    final d = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    out += ' · 到期 ${d.year}-$mm-$dd';
  }
  return out;
}

// Visual baseline (see DESIGN.md): one background color, one accent color,
// generous whitespace, system font, stock Material widgets. Decoration is
// reserved for the floating glass navigation bar.
const _accent = Color(0xFF3478F6);

/// Airport subscriptions carry pseudo "nodes" that only display
/// account info (remaining traffic, expiry, reset countdown). They
/// are excluded from latency tests and from auto-pick.
final RegExp _infoNodePattern = RegExp(
  r'剩余|流量|到期|重置|套餐|官网|公告|订阅|客服|expire|traffic|reset|remaining',
  caseSensitive: false,
);
bool isInfoNode(String name) => _infoNodePattern.hasMatch(name);
const _lightBackground = Color(0xFFF2F2F6);
const _darkBackground = Color(0xFF101012);

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final background = dark ? _darkBackground : _lightBackground;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: _accent,
    onPrimary: Colors.white,
    secondary: _accent,
    onSecondary: Colors.white,
    secondaryContainer:
        dark ? const Color(0xFF2B4A7A) : const Color(0xFFD9E6FD),
    onSecondaryContainer: dark ? const Color(0xFFD9E6FD) : const Color(0xFF0B53CE),
    surface: background,
    onSurface: dark ? const Color(0xFFF2F2F4) : const Color(0xFF1B1B1E),
    error: const Color(0xFFD93025),
    onError: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: scheme.onSurface,
    ),
    navigationBarTheme: NavigationBarThemeData(
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: _accent, size: 24);
        }
        return IconThemeData(
          color: scheme.onSurface.withValues(alpha: 0.55),
          size: 24,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color:
              selected ? _accent : scheme.onSurface.withValues(alpha: 0.55),
        );
      }),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: 0.08),
      thickness: 1,
      space: 1,
    ),
  );
}

class FlboxApp extends StatelessWidget {
  const FlboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlBox',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}

class _Destination {
  const _Destination(this.icon, this.label);

  final IconData icon;
  final String label;
}

const _destinations = [
  _Destination(Icons.space_dashboard_outlined, '仪表盘'),
  _Destination(Icons.hub_outlined, '代理'),
  _Destination(Icons.description_outlined, '配置'),
  _Destination(Icons.handyman_outlined, '工具'),
];

// Navigation bar appearance, switchable in Settings. The sliding glass
// bar is the default.
enum NavStyle {
  glass('液态玻璃'),
  slidingGlass('液态玻璃（滑动）');

  const NavStyle(this.label);

  final String label;
}

/// One saved subscription / local profile. Several can coexist; one
/// is active at a time and feeds the core.
const _defaultUa = 'ClashMeta/1.0';

class SubProfile {
  SubProfile({
    required this.id,
    required this.name,
    this.url,
    this.subInfo,
    this.nodeCount = 0,
    required this.updatedAtMs,
    this.autoUpdate = false,
    this.autoIntervalHours = 24,
    this.updateViaProxy = false,
    this.keepRegex = '',
    this.dropRegex = '',
    this.enabled = true,
    this.ua = _defaultUa,
  });

  final String id;
  String name;
  String? url;
  String? subInfo;
  int nodeCount;
  int updatedAtMs;
  bool autoUpdate;
  int autoIntervalHours;
  bool updateViaProxy;
  String keepRegex;
  String dropRegex;
  bool enabled;
  String ua;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'subInfo': subInfo,
        'nodeCount': nodeCount,
        'updatedAtMs': updatedAtMs,
        'autoUpdate': autoUpdate,
        'autoIntervalHours': autoIntervalHours,
        'updateViaProxy': updateViaProxy,
        'keepRegex': keepRegex,
        'dropRegex': dropRegex,
        'enabled': enabled,
        'ua': ua,
      };

  /// [autoUpdateSeed] migrates profiles saved before the per-sub
  /// flag existed: they inherit the old global auto-update switch.
  factory SubProfile.fromJson(
    Map<String, dynamic> j, {
    bool autoUpdateSeed = false,
  }) =>
      SubProfile(
        id: j['id'] as String,
        name: j['name'] as String? ?? '订阅',
        url: j['url'] as String?,
        subInfo: j['subInfo'] as String?,
        nodeCount: (j['nodeCount'] as num?)?.toInt() ?? 0,
        updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
        autoUpdate: (j['autoUpdate'] as bool?) ?? autoUpdateSeed,
        autoIntervalHours: (j['autoIntervalHours'] as num?)?.toInt() ?? 24,
        updateViaProxy: (j['updateViaProxy'] as bool?) ?? false,
        keepRegex: j['keepRegex'] as String? ?? '',
        dropRegex: j['dropRegex'] as String? ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        ua: j['ua'] as String? ?? _defaultUa,
      );
}

/// One traffic poll sample. Carried in a ValueNotifier so the 2 s
/// poll rebuilds only the dashboard's traffic region instead of the
/// whole shell (all four pages) on every tick.
/// A start failure with a user-readable detail for the
/// Asterisk-style error dialog (which attaches the daemon
/// log tail itself in the root modes).
class _StartFailure implements Exception {
  _StartFailure(this.detail);

  final String detail;
}

class _Traffic {
  const _Traffic({this.up = 0, this.down = 0, this.speedUp = 0, this.speedDown = 0});

  final int up;
  final int down;
  final double speedUp;
  final double speedDown;
}

/// One point of the dashboard's live-rate history.
class _RateSample {
  const _RateSample(this.up, this.down);

  final double up;
  final double down;
}

/// Latency color bands, tight enough that the color carries
/// information on this user's routes (most nodes sit at 50-250ms,
/// so the old 300/800 bands painted nearly everything green).
Color _delayColor(int? ms) {
  if (ms == null) return Colors.redAccent;
  if (ms < 120) return const Color(0xFF34A853);
  if (ms < 280) return Colors.orange;
  return Colors.redAccent;
}

/// Worker-isolate entry points for the speed test. These are
/// top-level on purpose: Isolate.run rejects a closure whose
/// captured context holds an unsendable object, and a closure
/// created inside a large state method can inherit that method's
/// whole context - in 0.40 the speed test's closures dragged the
/// state object (and a Timer inside it) along and every test
/// failed with "object is unsendable" before doing any work. A
/// top-level function's closure can only capture its own
/// parameters, which are plain sendable values. (The small
/// in-class helpers _translate and _restartCoreInPlace get away
/// with in-class closures because their methods hold nothing
/// else; do not copy that pattern into a big method.)
Future<int> _xrayMeasureInIsolate(String config, String url) =>
    Isolate.run(() => CoreBridge().xrayMeasureDelay(config, url));

Future<String> _xrayMeasureAllInIsolate(String configsJson, String url) =>
    Isolate.run(() => CoreBridge().xrayMeasureAll(configsJson, url));

/// Entrypoint for the speed test process. The Kotlin
/// FlboxTestService runs in its own ":tasks" process (the
/// v2rayNG split) and starts a second Flutter engine aimed at
/// this function; the job arrives over the host channel and
/// each result is streamed back the same way, so a native
/// abort mid-run kills only that process while the UI keeps
/// every result already posted. Never invoke this from the UI
/// process.
@pragma('vm:entry-point')
Future<void> testMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const host = MethodChannel('flbox/testhost');
  try {
    final jobStr = await host.invokeMethod<String>('getJob');
    if (jobStr == null) {
      await host.invokeMethod<void>('done');
      return;
    }
    final job = jsonDecode(jobStr) as Map<String, dynamic>;
    final url =
        job['url'] as String? ?? 'http://www.gstatic.com/generate_204';
    final items = <Map<String, dynamic>>[
      for (final e in job['items'] as List) (e as Map).cast<String, dynamic>(),
    ];
    // Combined measurement first: one core instance holds
    // the whole chunk's outbounds and each node is probed
    // through its own (the Clash shape - per-node instance
    // churn is what degraded every earlier build's back
    // half). An empty answer means the combined instance
    // could not be built or started, and the chunk falls
    // back to per-node measurement below.
    var combinedDone = false;
    try {
      final out = await _xrayMeasureAllInIsolate(
        jsonEncode([for (final item in items) item['config'] as String]),
        url,
      ).timeout(const Duration(seconds: 60), onTimeout: () => '');
      if (out.isNotEmpty) {
        final arr = jsonDecode(out) as List;
        if (arr.length == items.length) {
          for (var i = 0; i < items.length; i++) {
            try {
              await host.invokeMethod<void>(
                'postResult',
                jsonEncode({
                  'name': items[i]['name'],
                  'ms': (arr[i] as num).toInt(),
                }),
              );
            } catch (_) {}
          }
          combinedDone = true;
        }
      }
    } catch (_) {}
    if (!combinedDone) {
      var next = 0;
      Future<void> worker() async {
        while (next < items.length) {
        final item = items[next++];
        int ms;
        try {
          // A single measure is bounded down in the core (a
          // 12-second probe behind a serialized, millisecond
          // lifecycle), so 30 seconds without a return means
          // the call wedged below Dart. Post a timeout for the
          // node and move on: the stuck isolate is abandoned
          // (its late completion is ignored) instead of
          // silently ending the whole run at that node - the
          // 0.47-0.49 runs all stopped dead at 23 results
          // because one wedged call starved every worker
          // behind it.
          ms = await _xrayMeasureInIsolate(item['config'] as String, url)
              .timeout(const Duration(seconds: 30), onTimeout: () => -1);
        } catch (_) {
          ms = -1;
        }
        try {
          await host.invokeMethod<void>(
            'postResult',
            jsonEncode({'name': item['name'], 'ms': ms}),
          );
        } catch (_) {}
      }
    }

      await Future.wait([for (var i = 0; i < 8; i++) worker()]);
    }
  } catch (_) {}
  try {
    await host.invokeMethod<void>('done');
  } catch (_) {}
}

/// App-wide toast: a floating pill that clears the
/// glass nav bar. The stock SnackBar is a full-width
/// black slab that sat glued to the bar and lingered
/// for four seconds - it kept spoiling the layout.
void _showToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 13.5),
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF232428).withValues(alpha: 0.92),
      elevation: 6,
      margin: const EdgeInsets.fromLTRB(56, 0, 56, 96),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final _pageController = PageController();
  bool _pageAnimating = false;
  int _index = 0;
  NavStyle _navStyle = NavStyle.slidingGlass;
  XrayProfile? _profile;
  String? _profileName;
  String? _selectedNode;
  bool _running = false;
  bool _busy = false;
  int _tunFd = 0;
  String _logPath = '';
  String? _profileYaml;
  Map<String, int?> _delays = {};
  bool _testing = false;
  Completer<int>? _tunReady;
  List<SubProfile> _subs = [];
  String? _activeSubId;
  int _outMode = 1;

  /// Outbound mode names for logs: 0 rules, 1 global, 2 direct.
  String get _outModeName => const ['rules', 'global', 'direct'][_outMode];
  bool _geoReady = false;
  Set<String> _favNodes = {};
  bool _notifyOnStart = true;
  /// The manual IPv6 switch: in VPN mode it decides
  /// whether the tunnel takes over IPv6; in eBPF mode it
  /// decides whether the bridge captures IPv6. Applies at
  /// the next start.
  bool _ipv6Enabled = false;

  /// AS-style separate disabler for eBPF mode: with the
  /// IPv6 switch off, on means the daemon disables IPv6
  /// system-wide during the session (the guard); off
  /// means IPv6 stays native-direct, AS's default.
  bool _ipv6Disabler = true;
  bool _logEnabled = true;

  /// The running VPN session's IPv6 state, captured from
  /// the switch at start and persisted: a resync that
  /// restarts the forwarder on a surviving tunnel rebuilds
  /// it the way the tunnel was built, even if the switch
  /// moved mid-session or the process restarted.
  bool _vpnIpv6 = false;
  bool _rootBootStart = false;
  String _runMode = 'vpn';

  /// The root mode runs the external daemon (0.68: eBPF
  /// only; Root TUN was removed - the bridge data plane
  /// replaced it on every axis that mattered).
  bool get _daemonMode => _runMode == 'ebpf';
  bool _notifySubUpdate = true;
  int _subAutoIntervalHours = 24;
  Set<String> _bypassPkgs = {};
  bool _splitEnabled = false;
  bool _splitAllow = false;
  bool _netBlocked = false;
  bool _batteryIgnored = false;
  final _traffic = ValueNotifier<_Traffic>(const _Traffic());
  final _rateHistory = ValueNotifier<List<_RateSample>>(const []);
  DateTime? _startedAt;
  Timer? _pollTimer;
  Timer? _subTimer;
  DateTime? _lastCoreRestart;

  static const _vpnChannel = MethodChannel('flbox/vpn');

  @override
  void initState() {
    super.initState();
    _vpnChannel.setMethodCallHandler((call) async {
      if (call.method == 'onTunReady') {
        final fd = call.arguments as int;
        if (_tunReady != null && !_tunReady!.isCompleted) {
          _tunReady!.complete(fd);
        }
      } else if (call.method == 'onNetworkChanged') {
        _onNetworkChanged();
      }
      // No onTaskRemoved handling: swiping FlBox out of recents
      // leaves the VPN session running (v2rayNG-style); the
      // service is a foreground service with stopWithTask off,
      // and _resyncCoreState adopts the live session when the
      // app is reopened.
      return null;
    });
    WidgetsBinding.instance.addObserver(this);
    _restore();
    _checkNetwork();
    _askNotifications();
    _subTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      _runDueSubscriptionUpdates();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkBgSubUpdates();
      unawaited(_resyncCoreState());
    }
  }

  Future<void> _askNotifications() async {
    try {
      await _vpnChannel.invokeMethod('requestNotifications');
    } catch (_) {}
  }

  /// Detects the system-level per-app network block (a REJECT_ALL uid
  /// policy: DNS stops resolving and every connection is silently
  /// dropped while listeners still bind). When detected, the dashboard
  /// shows a banner that deep-links to the system switch instead of
  /// letting the user chase phantom core bugs.
  Future<void> _checkNetwork() async {
    try {
      final result = await InternetAddress.lookup('www.gstatic.com')
          .timeout(const Duration(seconds: 4));
      if (mounted) setState(() => _netBlocked = result.isEmpty);
    } catch (_) {
      if (mounted) setState(() => _netBlocked = true);
    }
  }

  Future<void> _openNetSettings() async {
    try {
      await _vpnChannel.invokeMethod('appSettings');
    } catch (_) {}
  }

  SubProfile? get _activeSub {
    for (final s in _subs) {
      if (s.id == _activeSubId) return s;
    }
    return null;
  }

  File _subFile(Directory docs, String id) =>
      File('${docs.path}/sub_$id.yaml');

  Future<void> _persistSubs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'subs_v2',
      jsonEncode([for (final s in _subs) s.toJson()]),
    );
    if (_activeSubId != null) {
      await prefs.setString('active_sub', _activeSubId!);
    } else {
      await prefs.remove('active_sub');
    }
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    // Outbound mode (0.68): 0 rules, 1 global, 2 direct.
    // Migrates the old rules_mode bool on first read.
    final savedOutMode = prefs.getInt('outbound_mode');
    if (savedOutMode != null && savedOutMode >= 0 && savedOutMode <= 2) {
      _outMode = savedOutMode;
    } else {
      _outMode = (prefs.getBool('rules_mode') ?? false) ? 0 : 1;
    }
    _notifyOnStart = prefs.getBool('notify_on_start') ?? true;
    _notifySubUpdate = prefs.getBool('notify_sub_update') ?? true;
    _ipv6Enabled = prefs.getBool('ipv6_enabled') ?? false;
    _ipv6Disabler = prefs.getBool('ipv6_disabler') ?? true;
    _logEnabled = prefs.getBool('log_enabled') ?? true;
    _vpnIpv6 = prefs.getBool('vpn_ipv6_effective') ?? false;
    _rootBootStart = prefs.getBool('root_boot_start') ?? false;
    _runMode = prefs.getString('run_mode') ?? 'vpn';
    // 0.68 removed Root TUN; a stored selection lands on VPN.
    if (_runMode == 'root_tun') _runMode = 'vpn';
    _subAutoIntervalHours = prefs.getInt('sub_auto_interval_hours') ?? 24;
    final legacySubAuto = prefs.getBool('sub_auto_update') ?? false;
    final favRaw = prefs.getString('fav_nodes');
    if (favRaw != null) {
      try {
        _favNodes = (jsonDecode(favRaw) as List).cast<String>().toSet();
      } catch (_) {}
    }
    final bypassRaw = prefs.getString('bypass_pkgs');
    if (bypassRaw != null) {
      try {
        _bypassPkgs = (jsonDecode(bypassRaw) as List).cast<String>().toSet();
      } catch (_) {}
    }
    _splitEnabled = prefs.getBool('bypass_enabled') ?? false;
    _splitAllow = prefs.getBool('bypass_allow') ?? false;
    final saved = prefs.getInt('nav_style');
    if (saved != null && saved >= 0 && saved < NavStyle.values.length) {
      setState(() => _navStyle = NavStyle.values[saved]);
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      _logPath = '${docs.path}/xray-error.log';
      _geoReady = await File('${docs.path}/geoip.dat').exists() &&
          await File('${docs.path}/geosite.dat').exists();
      final subsRaw = prefs.getString('subs_v2');
      if (subsRaw != null) {
        final list = jsonDecode(subsRaw) as List<dynamic>;
        _subs = [
          for (final e in list)
            SubProfile.fromJson(
              e as Map<String, dynamic>,
              autoUpdateSeed: legacySubAuto,
            ),
        ];
        _activeSubId = prefs.getString('active_sub');
        // Bake the autoUpdate migration into storage.
        await _persistSubs();
      } else {
        // Migration from the single-profile layout (<= 0.10): the one
        // saved profile.yaml becomes the first subscription entry.
        final legacy = File('${docs.path}/profile.yaml');
        if (await legacy.exists()) {
          final sub = SubProfile(
            id: 'legacy',
            name: prefs.getString('profile_name') ?? '已保存的配置',
            url: prefs.getString('profile_url'),
            updatedAtMs: (await legacy.lastModified()).millisecondsSinceEpoch,
          );
          await _subFile(docs, sub.id)
              .writeAsString(await legacy.readAsString());
          _subs = [sub];
          _activeSubId = sub.id;
          await _persistSubs();
        }
      }
      final active = _activeSub;
      if (active != null) {
        final file = _subFile(docs, active.id);
        if (await file.exists()) {
          final yaml = await file.readAsString();
          _profileYaml = yaml;
          final profile = await _translate(yaml);
          final stored = prefs.getString('selected_node');
          setState(() {
            _profile = profile;
            _profileName = active.name;
            _selectedNode =
                profile.nodes.any((n) => n.name == stored)
                    ? stored
                    : profile.nodes.first.name;
          });
        }
      }
    } catch (_) {
      // A stale or corrupt saved profile must not block startup.
    }
    if (_outMode == 0 && !_geoReady) {
      await _ensureGeoData();
    }
    // Per-subscription auto-update: each subscription carries its
    // own opt-in and interval (netproxy-style). Runs at startup,
    // on a 30-minute timer while the app lives, and hourly in the
    // background via WorkManager.
    await _checkBgSubUpdates();
    await _runDueSubscriptionUpdates();
    await _resyncCoreState();
    // No app-side autostart remains (0.68.1, user call):
    // the auto-connect and boot-restore switches were
    // removed, so opening the app never starts a session
    // by itself. The root boot script, when installed,
    // starts the daemon at boot and the resync above
    // adopts it; VPN sessions start from the button.
  }

  bool _sbReady = false;

  /// libbox needs a one-time Setup with its directories before the
  /// VPN forwarder can start.
  Future<void> _ensureSbSetup() async {
    if (_sbReady) return;
    final docs = await getApplicationDocumentsDirectory();
    final base = Directory('${docs.path}/sb');
    final work = Directory('${base.path}/work');
    final temp = Directory('${base.path}/tmp');
    for (final d in [base, work, temp]) {
      await d.create(recursive: true);
    }
    CoreBridge().sbSetup(base.path, work.path, temp.path);
    _sbReady = true;
  }

  /// Keeps the error log bounded: past ~2MB only the last ~256KB
  /// survive. Runs before a core start, when the previous instance
  /// is stopped and nothing holds the file open.
  Future<void> _rotateLogIfHuge() async {
    try {
      if (_logPath.isEmpty) return;
      final file = File(_logPath);
      if (!await file.exists()) return;
      final size = await file.length();
      const limit = 2 * 1024 * 1024;
      if (size <= limit) return;
      final raf = await file.open();
      const keep = 256 * 1024;
      await raf.setPosition(size - keep);
      final bytes = await raf.read(keep);
      await raf.close();
      var text = utf8.decode(bytes, allowMalformed: true);
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(nl + 1);
      final tmp = File('$_logPath.tmp');
      await tmp.writeAsString('[flbox] log rotated, kept the last 256KB\n$text');
      await tmp.rename(_logPath);
    } catch (_) {}
  }

  /// Appends a lifecycle line to the core log file, so the log page
  /// can show why a session was adopted, cleaned up, or restarted.
  /// Writes queue on a future chain instead of hitting the disk
  /// synchronously: the bulk speed test logs two lines per node,
  /// and 40+ sync appends on the UI isolate visibly hitched it.
  Future<void> _eventWriteChain = Future<void>.value();

  void _logEvent(String msg) {
    if (_logPath.isEmpty) return;
    final line = '${DateTime.now().toIso8601String()} [flbox] $msg\n';
    final path = _logPath;
    _eventWriteChain = _eventWriteChain.then((_) async {
      try {
        await File(path).writeAsString(line, mode: FileMode.append);
      } catch (_) {}
    });
  }

  /// Reconciles Dart's session state with reality at startup
  /// and on resume. The VPN service's companion flags describe
  /// the tunnel as the system holds it: "active" flips off the
  /// moment a stop begins, long before the service is actually
  /// gone, so the pair (service alive, tun fd still set) is the
  /// ground truth for "a tunnel exists". Three reconciliations
  /// follow: adopt a fully live session; REVIVE a live tunnel
  /// whose core died (restart core + forwarder on the same fd
  /// instead of dropping the tunnel the system still shows);
  /// and clear husks - a service or a core left without the
  /// other half, which is what made the panel read "not
  /// started" over a still-present system VPN after a
  /// swipe-away on ROMs that keep the service process.
  Future<void> _resyncCoreState() async {
    if (_busy || _running) return;
    if (_daemonMode) {
      // The root daemon lives outside the app process; its
      // status file is the ground truth. A live daemon is
      // adopted as-is - nothing else needs reconciling.
      final status = await _readRootStatus();
      if (status.startsWith('running')) {
        _logEvent('resync: adopted live root daemon session');
        _adoptSession();
      }
      return;
    }
    try {
      final coreRunning =
          CoreBridge().xrayStatus().contains('running=true');
      final serviceAlive =
          await _vpnChannel.invokeMethod<bool>('vpnServiceAlive') ??
              false;
      final fd = await _vpnChannel.invokeMethod<int>('tunFd') ?? -1;
      final vpnActive =
          await _vpnChannel.invokeMethod<bool>('vpnActive') ?? false;
      final tunnelLive = serviceAlive && fd > 0;
      if (tunnelLive && coreRunning) {
        _tunFd = fd;
        if (!CoreBridge().vpnForwardActive()) {
          // Core and tunnel survived but the packet forwarder did
          // not: restart it on the same fd instead of adopting a
          // session whose tunnel black-holes everything.
          try {
            await _ensureSbSetup();
            CoreBridge().vpnForwardStart(_tunFd, ipv6: _vpnIpv6);
            _logEvent('resync: restarted the vpn forwarder');
          } catch (e) {
            _logEvent('resync: vpn forwarder restart failed: $e');
            await _teardownResyncLeftovers();
            _toast('已清理失效的 VPN 会话');
            return;
          }
        }
        _logEvent('resync: adopted live VPN session');
        _adoptSession();
      } else if (tunnelLive) {
        // The tunnel outlived the core: revive the data path on
        // the same fd so panel and system agree again.
        final config = _profile?.configs[_selectedNode];
        if (config == null) {
          await _teardownResyncLeftovers();
          return;
        }
        try {
          _tunFd = fd;
          await _rotateLogIfHuge();
          CoreBridge().xrayStart(config, 0);
          await _ensureSbSetup();
          CoreBridge().vpnForwardStart(_tunFd, ipv6: _vpnIpv6);
          _logEvent('resync: revived core on the surviving tunnel');
          _adoptSession();
          unawaited(_primeStatus());
        } catch (e) {
          _logEvent('resync: revive failed: $e');
          await _teardownResyncLeftovers();
          _toast('已清理失效的 VPN 会话');
        }
      } else if (coreRunning) {
        _logEvent('resync: core without tunnel, stopping core');
        try {
          CoreBridge().vpnForwardStop();
        } catch (_) {}
        try {
          CoreBridge().xrayStop();
        } catch (_) {}
      } else if (vpnActive || serviceAlive) {
        // A husk: the service is still around (its notification
        // and the system VPN entry linger) but holds no tunnel.
        _logEvent('resync: clearing tunnel-less VPN service husk');
        try {
          CoreBridge().vpnForwardStop();
        } catch (_) {}
        await _vpnChannel.invokeMethod('stopVpn');
      }
    } catch (_) {}
  }

  void _adoptSession() {
    setState(() {
      _running = true;
      _startedAt = DateTime.now();
    });
    _startPolling();
  }

  Future<void> _teardownResyncLeftovers() async {
    try {
      CoreBridge().vpnForwardStop();
    } catch (_) {}
    try {
      CoreBridge().xrayStop();
    } catch (_) {}
    try {
      await _vpnChannel.invokeMethod('stopVpn');
    } catch (_) {}
    _tunFd = 0;
  }

  /// The default network changed under a running core (Wi-Fi to
  /// mobile and back): its outbound sockets rot silently and pages
  /// load a little, then stall. Restart the core in place on the
  /// same tunnel, which is what a manual stop/start did, but
  /// automatically. Debounced: network flaps settle first.
  Future<void> _onNetworkChanged() async {
    // A running speed test no longer owns the main instance
    // (it uses transient side instances), so it must not block
    // the network-change restart of the live session.
    if (!_running || _busy) return;
    // The root daemon is a full sing-box: it watches interface
    // changes itself, no in-place restart needed.
    if (_daemonMode) return;
    final last = _lastCoreRestart;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 15)) {
      return;
    }
    _lastCoreRestart = DateTime.now();
    final config = _profile?.configs[_selectedNode];
    if (config == null) return;
    _logEvent('network changed: restarting core in place');
    try {
      CoreBridge().xrayStop();
      await _restartCoreInPlace(config);
      _startedAt = DateTime.now();
    } catch (e) {
      _logEvent('network-change restart failed: $e');
    }
  }

  /// Prepares the routing rule databases (geoip.dat / geosite.dat)
  /// in the documents directory, where the core's asset lookup
  /// points. The databases ship inside the APK (downloaded at build
  /// time by a Gradle task) and are copied out of the bundled assets
  /// locally — no runtime download. A network download remains only
  /// as a fallback for a build whose assets are missing. Already
  /// present counts as success; the caller reports failures.
  Future<bool> _ensureGeoData({bool force = false}) async {
    final docs = await getApplicationDocumentsDirectory();
    final files = {
      'geoip.dat': File('${docs.path}/geoip.dat'),
      'geosite.dat': File('${docs.path}/geosite.dat'),
    };
    if (!force &&
        await files['geoip.dat']!.exists() &&
        await files['geosite.dat']!.exists()) {
      _geoReady = true;
      return true;
    }
    try {
      final ok = await _vpnChannel.invokeMethod<bool>(
        'extractGeoData',
        {'force': force, 'dir': docs.path},
      );
      // Trust the extraction only once the files are verifiably
      // where the core looks for them; a silent misplacement
      // falls through to the download path instead of a dead
      // rules-mode start.
      if (ok == true &&
          await files['geoip.dat']!.exists() &&
          await files['geosite.dat']!.exists() &&
          await files['geosite.dat']!.length() > 1000000) {
        _geoReady = true;
        return true;
      }
    } catch (_) {
      // Bundled copy unavailable; fall through to the network path.
    }
    _toast('正在下载分流规则库（约 25 MB）…');
    final sources = {
      'geoip.dat': [
        'https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat',
        'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat',
      ],
      'geosite.dat': [
        'https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
        'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat',
      ],
    };
    final client = HttpClient();
    try {
      for (final entry in files.entries) {
        var ok = false;
        for (final url in sources[entry.key]!) {
          try {
            final req = await client
                .getUrl(Uri.parse(url))
                .timeout(const Duration(seconds: 30));
            final resp =
                await req.close().timeout(const Duration(seconds: 60));
            if (resp.statusCode != 200) continue;
            final sink = entry.value.openWrite();
            await resp.pipe(sink);
            ok = await entry.value.length() > 1000000;
            if (ok) break;
          } catch (_) {
            // Try the next mirror.
          }
        }
        if (!ok) {
          _geoReady = false;
          return false;
        }
      }
      _geoReady = true;
      return true;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _setOutMode(int mode) async {
    if (_busy || mode == _outMode) return;
    if (mode == 0 && !await _ensureGeoData()) {
      _toast('规则库准备失败，检查网络后重试');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('outbound_mode', mode);
    setState(() => _outMode = mode);
    final yaml = _profileYaml;
    if (yaml != null && _activeSub != null) {
      try {
        await _activateYaml(yaml, name: _activeSub!.name);
      } catch (e) {
        _toast('切换路由模式失败：$e');
        return;
      }
    }
    if (_running) {
      // Restart the core in place on the same tunnel with the new
      // routing preset; the VPN itself never goes down. In root
      // mode _restartForMode relaunches the daemon with freshly
      // generated configs instead - same effect, bigger hammer.
      final config = _profile?.configs[_selectedNode];
      if (config != null) {
        try {
          await _restartForMode(config);
          _logEvent('core restarted for mode switch (mode=$_outModeName)');
          _startedAt = DateTime.now();
        } on CoreException catch (e) {
          setState(() {
            _running = false;
            _tunFd = 0;
          });
          _toast('切换后重启失败：${e.message}');
          return;
        }
      }
    }
    _toast(switch (mode) {
      0 => '已切换到规则模式（v2ray 绕过大陆）',
      2 => '已切换到直连模式（全部流量不走代理）',
      _ => '已切换到全局模式',
    });
  }

  /// Exports every subscription (metadata + stored YAML) and the
  /// user-facing settings as one JSON file the user picks a home
  /// for; falls back to the clipboard when the platform cannot
  /// save files.
  Future<void> _exportBackup() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final subsJson = <Map<String, dynamic>>[];
      for (final sub in _subs) {
        var content = '';
        final f = _subFile(docs, sub.id);
        if (await f.exists()) content = await f.readAsString();
        subsJson.add({'meta': sub.toJson(), 'content': content});
      }
      final backup = <String, dynamic>{
        'app': 'flbox',
        'kind': 'backup',
        'version': 1,
        'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
        'subs': subsJson,
        'activeSub': _activeSubId,
        'prefs': {
          'outbound_mode': _outMode,
          'notify_on_start': _notifyOnStart,
          'notify_sub_update': _notifySubUpdate,
          'root_boot_start': _rootBootStart,
          'ipv6_enabled': _ipv6Enabled,
          'ipv6_disabler': _ipv6Disabler,
          'log_enabled': _logEnabled,
          'run_mode': _runMode,
          'sub_auto_interval_hours': _subAutoIntervalHours,
          'nav_style': _navStyle.index,
          'fav_nodes': _favNodes.toList(),
          'bypass_pkgs': _bypassPkgs.toList(),
          'bypass_enabled': _splitEnabled,
          'bypass_allow': _splitAllow,
        },
      };
      final text = jsonEncode(backup);
      String? saved;
      try {
        saved = await FilePicker.platform.saveFile(
          dialogTitle: '保存 FlBox 备份',
          fileName: 'flbox-backup.json',
          bytes: Uint8List.fromList(utf8.encode(text)),
        );
      } catch (_) {
        saved = null;
      }
      if (saved != null) {
        _toast('备份已导出');
      } else {
        await Clipboard.setData(ClipboardData(text: text));
        _toast('未能保存为文件，备份已复制到剪贴板');
      }
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  /// Restores a backup made by _exportBackup: subscriptions and
  /// settings are replaced wholesale, then the active
  /// subscription is reloaded like on a cold start.
  Future<void> _importBackup() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null) {
        _toast('读不到所选文件');
        return;
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['app'] != 'flbox' ||
          decoded['kind'] != 'backup') {
        _toast('这不是 FlBox 的备份文件');
        return;
      }
      if (_running) await _stopCore();
      final docs = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      final newSubs = <SubProfile>[];
      final rawSubs = decoded['subs'];
      if (rawSubs is List) {
        for (final e in rawSubs) {
          if (e is! Map<String, dynamic>) continue;
          final meta = e['meta'];
          if (meta is! Map<String, dynamic>) continue;
          final sub = SubProfile.fromJson(meta);
          await _subFile(docs, sub.id)
              .writeAsString((e['content'] as String?) ?? '');
          newSubs.add(sub);
        }
      }
      var outMode = _outMode;
      var notifyOnStart = _notifyOnStart;
      var notifySubUpdate = _notifySubUpdate;
      var rootBootStart = _rootBootStart;
      var ipv6Enabled = _ipv6Enabled;
      var ipv6Disabler = _ipv6Disabler;
      var logEnabled = _logEnabled;
      var intervalHours = _subAutoIntervalHours;
      var navStyle = _navStyle;
      var favNodes = _favNodes;
      var bypassPkgs = _bypassPkgs;
      var bypassEnabled = _splitEnabled;
      var bypassAllow = _splitAllow;
      var runMode = _runMode;
      final bp = decoded['prefs'];
      if (bp is Map<String, dynamic>) {
        bool bb(String k, bool cur) => bp[k] is bool ? bp[k] as bool : cur;
        if (bp['outbound_mode'] is int) {
          outMode = bp['outbound_mode'] as int;
          if (outMode < 0 || outMode > 2) outMode = 1;
        } else if (bp['rules_mode'] is bool) {
          outMode = (bp['rules_mode'] as bool) ? 0 : 1;
        }
        notifyOnStart = bb('notify_on_start', notifyOnStart);
        notifySubUpdate = bb('notify_sub_update', notifySubUpdate);
        rootBootStart = bb('root_boot_start', rootBootStart);
        ipv6Enabled = bb('ipv6_enabled', ipv6Enabled);
        ipv6Disabler = bb('ipv6_disabler', ipv6Disabler);
        logEnabled = bb('log_enabled', logEnabled);
        if (bp['run_mode'] is String) runMode = bp['run_mode'] as String;
        if (runMode == 'root_tun') runMode = 'vpn';
        bypassEnabled = bb('bypass_enabled', bypassEnabled);
        bypassAllow = bb('bypass_allow', bypassAllow);
        if (bp['sub_auto_interval_hours'] is int) {
          intervalHours = bp['sub_auto_interval_hours'] as int;
        }
        if (bp['nav_style'] is int) {
          final i = bp['nav_style'] as int;
          if (i >= 0 && i < NavStyle.values.length) {
            navStyle = NavStyle.values[i];
          }
        }
        if (bp['fav_nodes'] is List) {
          favNodes = (bp['fav_nodes'] as List).cast<String>().toSet();
        }
        if (bp['bypass_pkgs'] is List) {
          bypassPkgs = (bp['bypass_pkgs'] as List).cast<String>().toSet();
        }
      }
      var activeId = decoded['activeSub'] as String?;
      if (activeId != null && !newSubs.any((x) => x.id == activeId)) {
        activeId = null;
      }
      setState(() {
        _subs = newSubs;
        _activeSubId = activeId;
        _outMode = outMode;
        _notifyOnStart = notifyOnStart;
        _notifySubUpdate = notifySubUpdate;
        _rootBootStart = rootBootStart;
        _ipv6Enabled = ipv6Enabled;
        _ipv6Disabler = ipv6Disabler;
        _logEnabled = logEnabled;
        _runMode = runMode;
        _subAutoIntervalHours = intervalHours;
        _navStyle = navStyle;
        _favNodes = favNodes;
        _bypassPkgs = bypassPkgs;
        _splitEnabled = bypassEnabled;
        _splitAllow = bypassAllow;
      });
      await prefs.setInt('outbound_mode', outMode);
      await prefs.setBool('notify_on_start', notifyOnStart);
      await prefs.setBool('notify_sub_update', notifySubUpdate);
      await prefs.setBool('root_boot_start', rootBootStart);
      await prefs.setBool('ipv6_enabled', ipv6Enabled);
      await prefs.setBool('ipv6_disabler', ipv6Disabler);
      await prefs.setBool('log_enabled', logEnabled);
      await prefs.setString('run_mode', runMode);
      await prefs.setInt('sub_auto_interval_hours', intervalHours);
      await prefs.setInt('nav_style', navStyle.index);
      await prefs.setString('fav_nodes', jsonEncode(favNodes.toList()));
      await prefs.setString(
          'bypass_pkgs', jsonEncode(bypassPkgs.toList()));
      await prefs.setBool('bypass_enabled', bypassEnabled);
      await prefs.setBool('bypass_allow', bypassAllow);
      await _persistSubs();
      final active = _activeSub;
      if (active != null) {
        final f = _subFile(docs, active.id);
        if (await f.exists()) {
          await _activateYaml(await f.readAsString(), name: active.name);
        }
      } else {
        setState(() {
          _profile = null;
          _profileYaml = null;
        });
      }
      _toast('备份已恢复：${newSubs.length} 份订阅');
    } catch (e) {
      _toast('恢复失败：$e');
    }
  }

  Future<void> _setNotifyOnStart(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notify_on_start', value);
    setState(() => _notifyOnStart = value);
  }

  Future<void> _setNotifySubUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notify_sub_update', value);
    setState(() => _notifySubUpdate = value);
  }

  Future<void> _setSubAutoInterval(int hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sub_auto_interval_hours', hours);
    setState(() => _subAutoIntervalHours = hours);
  }

  /// Subscription editor (the netproxy-style form): name, link,
  /// per-subscription auto-update period, update route, and the
  /// node name filters applied on every refresh.
  /// Profiles-page header action (0.69): refresh every
  /// enabled subscription that has a URL, in order.
  Future<void> _updateAllSubs() async {
    final targets = _subs
        .where((s) => s.enabled && (s.url?.isNotEmpty ?? false))
        .toList();
    if (targets.isEmpty) {
      _toast('没有可更新的订阅');
      return;
    }
    for (final sub in targets) {
      try {
        await _fetchSubscription(sub.url!, updateSub: sub, quiet: true);
      } catch (_) {}
    }
    _toast('已刷新全部订阅（${targets.length} 个）');
  }

  /// Geo rule-set refresh, shared by the settings tile
  /// and the tools page entry.
  Future<void> _updateGeoData() async {
    final ok = await _ensureGeoData(force: true);
    _toast(ok ? '规则库已刷新（内置版本）' : '规则库刷新失败');
  }

  /// The manual IPv6 switch: persisted at once, applied
  /// at the next VPN start (the tunnel's shape is fixed
  /// when the VpnService builds it). eBPF mode never
  /// consults it.
  Future<void> _setIpv6Enabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ipv6_enabled', v);
    if (mounted) setState(() => _ipv6Enabled = v);
    _toast(v ? 'IPv6 已开启，下次启动时生效' : 'IPv6 已关闭，下次启动时生效');
  }

  Future<void> _setIpv6Disabler(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ipv6_disabler', v);
    if (mounted) setState(() => _ipv6Disabler = v);
    _toast(v ? '系统级禁用 IPv6 已开启，下次启动 eBPF 时生效' : '系统级禁用 IPv6 已关闭，下次启动 eBPF 时 v6 走原生直连');
  }

  /// Root-mode boot autostart (0.68, AsteriskNG's design):
  /// enabling publishes the daemon configs for the current
  /// node and installs a Magisk service.d script that starts
  /// flboxd at boot with them - no app process involved, so
  /// the proxy is up before the user ever opens FlBox. The
  /// app adopts the boot-started daemon through the usual
  /// status-file resync. Disabling removes the script.
  /// Core log switch: persisted at once, applied the
  /// next time a core config is generated (a session
  /// start or a subscription switch). Off sets the Xray
  /// log level to none in both cores - the daemon core's
  /// info log is its biggest steady disk writer.
  Future<void> _setLogEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('log_enabled', v);
    setState(() => _logEnabled = v);
  }

  Future<void> _setRootBootStart(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!value) {
      await _applyRootBootScript(false);
      await prefs.setBool('root_boot_start', false);
      if (mounted) setState(() => _rootBootStart = false);
      _logEvent('root boot start disabled (service.d script removed)');
      return;
    }
    if (_runMode != 'ebpf') return;
    if (_selectedNode == null || _profileYaml == null) {
      _toast('先到「代理」页选一个节点');
      if (mounted) setState(() => _rootBootStart = false);
      return;
    }
    final check = await _vpnChannel.invokeMethod<String>('rootCheck');
    if (check != 'ok') {
      _toast(check == 'nodaemon'
          ? '此安装包未包含 root 守护进程'
          : '未取得 root 授权，无法安装开机脚本');
      if (mounted) setState(() => _rootBootStart = false);
      return;
    }
    try {
      await _writeRootDaemonConfigs();
    } catch (e) {
      _toast('生成开机启动配置失败：$e');
      if (mounted) setState(() => _rootBootStart = false);
      return;
    }
    if (!await _applyRootBootScript(true)) {
      _toast('开机脚本安装失败');
      if (mounted) setState(() => _rootBootStart = false);
      return;
    }
    await prefs.setBool('root_boot_start', true);
    if (mounted) setState(() => _rootBootStart = true);
    _logEvent('root boot start enabled (Magisk service.d script installed)');
    _toast('已开启：重启后 Root 模式自动启动');
  }

  Future<bool> _applyRootBootScript(bool enabled) async {
    final docs = await getApplicationDocumentsDirectory();
    try {
      final ok = await _vpnChannel.invokeMethod<bool>('bootStartSet', {
        'enabled': enabled,
        'config': '${docs.path}/root-config.json',
        'status': '${docs.path}/root-status.txt',
        'log': '${docs.path}/root-daemon.log',
        'prevLog': '${docs.path}/root-daemon.prev.log',
        'bridge': '${docs.path}/root-bridge.json',
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Republishes the daemon configs when the boot script is
  /// installed but the daemon is stopped, so a node switch is
  /// what the next boot starts with. While running, the
  /// restart path already regenerates them.
  Future<void> _republishRootConfigsIfNeeded() async {
    if (!_rootBootStart || _runMode != 'ebpf' || _running) return;
    try {
      await _writeRootDaemonConfigs();
    } catch (_) {}
  }

  /// AsteriskNG-style group enable switch: a disabled group
  /// leaves the proxy tabs and is skipped by auto-update.
  /// Disabling the group in use stops the connection first
  /// and moves the active slot to the next enabled group.
  Future<void> _setSubEnabled(SubProfile sub, bool enabled) async {
    if (sub.enabled == enabled) return;
    setState(() => sub.enabled = enabled);
    if (!enabled && sub.id == _activeSubId) {
      if (_running) await _stopCore();
      final rest = _subs
          .where((x) => x.enabled && x.id != sub.id)
          .toList();
      if (rest.isNotEmpty) {
        await _switchSub(rest.first);
      } else {
        setState(() {
          _activeSubId = null;
          _profile = null;
          _profileName = '';
          _selectedNode = null;
        });
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('active_sub');
      }
    }
    await _persistSubs();
  }

  Future<void> _openSubEditor(SubProfile sub) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SubEditPage(sub: sub),
    );
    if (result == null) return;
    setState(() {
      sub.name = result['name'] as String;
      final url = result['url'] as String?;
      if (sub.url != null) sub.url = url;
      sub.autoUpdate = result['autoUpdate'] as bool;
      sub.autoIntervalHours = result['interval'] as int;
      sub.updateViaProxy = result['viaProxy'] as bool;
      sub.keepRegex = result['keep'] as String;
      sub.dropRegex = result['drop'] as String;
      sub.ua = result['ua'] as String;
      if (sub.id == _activeSubId) _profileName = sub.name;
    });
    await _persistSubs();
    _toast('订阅设置已保存');
  }

  Future<void> _toggleFav(String name) async {
    setState(() {
      if (!_favNodes.remove(name)) _favNodes.add(name);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fav_nodes', jsonEncode(_favNodes.toList()));
  }

  void _toast(String message) => _showToast(context, message);

  /// Translation on a worker isolate: building every node's
  /// config and LoadConfig-validating each outbound takes the
  /// better part of a second for a big subscription, which
  /// froze the UI whenever a group was switched (worst while
  /// running). Field values are snapshotted first - an isolate
  /// closure may only capture sendable values, never `this`.
  Future<XrayProfile> _translate(String text) {
    final logPath = _logPath;
    final outMode = _outMode;
    final logOff = !_logEnabled;
    return Isolate.run(
      () => CoreBridge().translateXray(
        text,
        vpn: true,
        logPath: logPath,
        outMode: outMode,
        logOff: logOff,
      ),
    );
  }

  /// In-place core restart on a worker isolate, for the same
  /// reason: xrayStart blocks while the old instance drains.
  Future<void> _restartCoreInPlace(String config) {
    return Isolate.run(() => CoreBridge().xrayStart(config, 0));
  }

  /// Translates [text] and makes it the live profile (used whenever a
  /// subscription becomes active). The node selection survives when
  /// the new profile has a node with the same name.
  Future<void> _activateYaml(String text, {required String name}) async {
    final docs = await getApplicationDocumentsDirectory();
    _logPath = '${docs.path}/xray-error.log';
    final profile = await _translate(text);
    _profileYaml = text;
    final prefs = await SharedPreferences.getInstance();
    final selected =
        profile.nodes.any((n) => n.name == _selectedNode)
            ? _selectedNode!
            : profile.nodes.first.name;
    await prefs.setString('selected_node', selected);
    setState(() {
      _profile = profile;
      _profileName = name;
      _selectedNode = selected;
      _delays = {};
    });
    unawaited(_republishRootConfigsIfNeeded());
  }

  /// Adds a new subscription entry from imported text and
  /// activates it. The text may be Clash YAML, a share-link list,
  /// or an Xray / sing-box JSON config: the core sniffs and
  /// normalises it to Clash YAML first.
  Future<void> _addSubFromYaml(
    String text, {
    required String name,
    String? url,
    String? subInfo,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    _logPath = '${docs.path}/xray-error.log';
    final converted = CoreBridge().convertImport(text);
    text = converted['yaml'] as String;
    final kind = converted['kind'] as String;
    final profile = await _translate(text);
    final sub = SubProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      url: url,
      subInfo: subInfo,
      autoIntervalHours: _subAutoIntervalHours,
      nodeCount: profile.nodes.length,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _subFile(docs, sub.id).writeAsString(text);
    _subs = [..._subs, sub];
    _activeSubId = sub.id;
    await _persistSubs();
    await _activateYaml(text, name: name);
    _toast(
      '已导入 ${profile.nodes.length} 个可用节点'
      '${kind == 'yaml' ? '' : '（已从 $kind 转换）'}',
    );
  }

  Future<void> _switchSub(SubProfile sub) async {
    if (sub.id == _activeSubId) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final text = await _subFile(docs, sub.id).readAsString();
      _activeSubId = sub.id;
      await _persistSubs();
      await _activateYaml(text, name: sub.name);
      if (_running) {
        // Switch the exit in place on the same tunnel (like the
        // rule/global switch): only the core restarts, the VPN
        // never goes down.
        final config = _profile?.configs[_selectedNode];
        if (config != null) {
          try {
            await _restartForMode(config);
            _logEvent(
              'core restarted for subscription switch (${sub.name})',
            );
            _startedAt = DateTime.now();
            _pushVpnStatus();
            unawaited(_primeStatus());
          } catch (e) {
            await _stopCore();
            _toast('切换后重启失败，已停止：$e');
            return;
          }
        }
      }
      _toast('已切换到 ${sub.name}');
    } catch (e) {
      _toast('切换失败：$e');
    }
  }

  Future<void> _deleteSub(SubProfile sub) async {
    if (_running && sub.id == _activeSubId) {
      _toast('先停止再删除正在用的订阅');
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    try {
      await _subFile(docs, sub.id).delete();
    } catch (_) {}
    final wasActive = sub.id == _activeSubId;
    _subs = [for (final s in _subs) if (s.id != sub.id) s];
    if (!wasActive) {
      await _persistSubs();
      setState(() {});
      _toast('已删除 ${sub.name}');
      return;
    }
    _activeSubId = _subs.isEmpty ? null : _subs.first.id;
    await _persistSubs();
    try {
      if (_activeSub != null) {
        final text = await _subFile(docs, _activeSub!.id).readAsString();
        await _activateYaml(text, name: _activeSub!.name);
      } else {
        setState(() {
          _profile = null;
          _profileName = null;
          _profileYaml = null;
          _selectedNode = null;
          _delays = {};
        });
      }
    } catch (_) {
      setState(() {
        _profile = null;
        _profileName = null;
        _profileYaml = null;
        _selectedNode = null;
        _delays = {};
      });
    }
    _toast('已删除 ${sub.name}');
  }

  /// Node editor entry point. Editing targets the active
  /// subscription's own file (a subscription refresh replaces it,
  /// like every other client); adding creates the node in the
  /// local "手动节点" profile instead, which no update overwrites.
  Future<void> _openNodeEditor([String? editName]) async {
    if (_running) {
      _toast('先停止再编辑节点');
      return;
    }
    final isNew = editName == null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      SubProfile? targetSub;
      var targetYaml = '';
      if (isNew) {
        for (final s in _subs) {
          if (s.id == 'manual') targetSub = s;
        }
        if (targetSub != null) {
          final f = _subFile(docs, targetSub.id);
          if (await f.exists()) targetYaml = await f.readAsString();
        }
      } else {
        targetSub = _activeSub;
        if (targetSub == null) return;
        targetYaml = _profileYaml ?? '';
      }
      var detail = <String, dynamic>{};
      if (!isNew) {
        detail = CoreBridge().nodeDetail(targetYaml, editName);
      }
      var siblingNames = <String>{};
      if (targetYaml.isNotEmpty) {
        try {
          final p = await _translate(targetYaml);
          siblingNames = {for (final n in p.nodes) n.name};
        } catch (_) {}
      }
      if (!mounted) return;
      final result = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(
          builder: (_) => _NodeEditPage(
            isNew: isNew,
            detail: detail,
            siblingNames: siblingNames,
            fromSubscription: !isNew && targetSub?.url != null,
            onShare: isNew
                ? null
                : () {
                    try {
                      final link = CoreBridge()
                          .nodeShareLink(targetYaml, editName);
                      unawaited(
                        Clipboard.setData(ClipboardData(text: link)),
                      );
                      _toast('分享链接已复制到剪贴板');
                    } on CoreException catch (e) {
                      _toast('分享失败：${e.message}');
                    }
                  },
          ),
        ),
      );
      if (result == null) return;
      final String newYaml;
      if (result['delete'] == true) {
        newYaml = CoreBridge().nodeDelete(targetYaml, editName!);
      } else {
        newYaml = CoreBridge().nodeUpsert(
          targetYaml,
          result['entry'] as Map<String, dynamic>,
          isNew ? '' : editName,
        );
      }
      final profile = await _translate(newYaml);
      var sub = targetSub;
      if (sub == null) {
        sub = SubProfile(
          id: 'manual',
          name: '手动节点',
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        _subs = [..._subs, sub];
      }
      await _subFile(docs, sub.id).writeAsString(newYaml);
      sub.nodeCount = profile.nodes.length;
      sub.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _persistSubs();
      if (profile.nodes.isEmpty) {
        if (sub.id == _activeSubId) {
          setState(() {
            _profile = null;
            _profileName = null;
            _profileYaml = null;
            _selectedNode = null;
            _delays = {};
          });
        }
        _toast('已删除，该配置已无可用节点');
        return;
      }
      if (!isNew && result['entry'] != null && _selectedNode == editName) {
        _selectedNode =
            (result['entry'] as Map<String, dynamic>)['name'] as String?;
      }
      _activeSubId = sub.id;
      await _persistSubs();
      await _activateYaml(newYaml, name: sub.name);
      _toast(result['delete'] == true ? '已删除节点' : '已保存节点');
    } on CoreException catch (e) {
      _toast('保存失败：${e.message}');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _importProfile() async {
    // FileType.any, with the guard moved to AFTER the pick: an
    // extension whitelist at picker level greys out .yaml files
    // on the user's ROM (Android maps extensions to MIME types
    // for the picker intent, and yaml has no standard mapping,
    // so his config.yaml sat unselectable while .json worked -
    // device-verified 2026-11-04). Instead the picker opens
    // wide and this gate rejects anything that is not a config
    // file on the spot; ConvertImport then validates content,
    // so a wrong file can be tapped but never imported.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
    if (picked == null || picked.files.single.path == null) return;
    final lowerName = picked.files.single.name.toLowerCase();
    if (!lowerName.endsWith('.yaml') &&
        !lowerName.endsWith('.yml') &&
        !lowerName.endsWith('.json') &&
        !lowerName.endsWith('.txt')) {
      _toast('只支持导入 yaml / json / txt 配置文件');
      return;
    }
    final file = File(picked.files.single.path!);
    try {
      final text = await file.readAsString();
      await _addSubFromYaml(text, name: picked.files.single.name);
    } on CoreException catch (e) {
      _toast('导入失败：${e.message}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// Pastes/imports share links (vless://, hy2://, …): parsed in
  /// the core, then spliced into the local "手动节点" profile like
  /// hand-added nodes, so subscription updates never touch them.
  Future<void> _importFromLink() async {
    if (_running) {
      _toast('先停止再导入节点');
      return;
    }
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入单节点链接'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'vless://… / hysteria2://…（可多行，或整段 base64）',
            ),
            keyboardType: TextInputType.multiline,
            minLines: 3,
            maxLines: 6,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) controller.text = data!.text!;
            },
            child: const Text('粘贴'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    try {
      final parsed = CoreBridge().parseShareLinks(text);
      final entries = (parsed['entries'] as List).cast<Map<String, dynamic>>();
      if (entries.isEmpty) {
        _toast('没有可导入的链接');
        return;
      }
      final docs = await getApplicationDocumentsDirectory();
      SubProfile? manual;
      for (final s in _subs) {
        if (s.id == 'manual') manual = s;
      }
      var yaml = '';
      if (manual != null) {
        final f = _subFile(docs, manual.id);
        if (await f.exists()) yaml = await f.readAsString();
      }
      for (final entry in entries) {
        yaml = CoreBridge().nodeUpsert(yaml, entry, '');
      }
      final profile = await _translate(yaml);
      var sub = manual;
      if (sub == null) {
        sub = SubProfile(
          id: 'manual',
          name: '手动节点',
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        _subs = [..._subs, sub];
      }
      await _subFile(docs, sub.id).writeAsString(yaml);
      sub.nodeCount = profile.nodes.length;
      sub.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      await _persistSubs();
      _activeSubId = sub.id;
      await _persistSubs();
      await _activateYaml(yaml, name: sub.name);
      final skipped = (parsed['skipped'] as num?)?.toInt() ?? 0;
      _toast(
        '已导入 ${entries.length} 个节点到「手动节点」'
        '${skipped > 0 ? '，跳过 $skipped 条无法解析的' : ''}',
      );
    } on CoreException catch (e) {
      _toast('导入失败：${e.message}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<String?> _askUrl() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('订阅链接'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://…',
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('拉取'),
          ),
        ],
      ),
    );
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Formats a subscription-userinfo header (bytes / epoch seconds)
  /// into a short human line, or null when unusable.
  String? _formatSubInfo(String? raw) => formatSubInfoText(raw);

  /// Silent due-check used by startup, the in-app timer and (in
  /// its own isolate) the WorkManager task: refreshes every opted-in
  /// subscription whose own interval has elapsed. Via-proxy subs
  /// are skipped while the core is down.
  Future<void> _runDueSubscriptionUpdates() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final sub in _subs) {
      if (!sub.enabled || !sub.autoUpdate || sub.url == null) continue;
      if (sub.updateViaProxy && !_running) continue;
      if (nowMs - sub.updatedAtMs > sub.autoIntervalHours * 3600000) {
        await _fetchSubscription(sub.url!, updateSub: sub, quiet: true);
      }
    }
  }

  /// Picks up subscription files the WorkManager task refreshed:
  /// reloads the saved metadata and, when the active subscription
  /// changed under us and the core is stopped, re-activates it.
  Future<void> _checkBgSubUpdates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('bg_subs_changed') != true) return;
      await prefs.remove('bg_subs_changed');
      final bgNamesRaw = prefs.getString('bg_updated_names');
      await prefs.remove('bg_updated_names');
      final raw = prefs.getString('subs_v2');
      if (raw == null) return;
      final list = jsonDecode(raw) as List<dynamic>;
      final fresh = [
        for (final e in list)
          SubProfile.fromJson(e as Map<String, dynamic>),
      ];
      final activeBefore = _activeSub;
      setState(() => _subs = fresh);
      if (activeBefore != null && !_running) {
        final docs = await getApplicationDocumentsDirectory();
        final f = _subFile(docs, activeBefore.id);
        if (await f.exists()) {
          final yaml = await f.readAsString();
          if (yaml != _profileYaml) {
            await _activateYaml(yaml, name: activeBefore.name);
            _logEvent(
              'subscription refreshed in background: ${activeBefore.name}',
            );
          }
        }
      }
      if (bgNamesRaw != null && _notifySubUpdate) {
        try {
          final names = (jsonDecode(bgNamesRaw) as List).cast<String>();
          if (names.isNotEmpty) {
            unawaited(_notify('订阅已自动更新', names.join('、')));
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Fetches a subscription URL. With [updateSub] it refreshes that
  /// entry in place; without, it adds a new entry.
  Future<void> _fetchSubscription(
    String url, {
    SubProfile? updateSub,
    bool quiet = false,
  }) async {
    final client = HttpClient();
    // Subscription traffic goes direct by default: an update must
    // still succeed when every node is dead — that is usually when
    // it is needed most. (The app is also excluded from its own
    // VPN tunnel, so this fetch is direct end to end.) A
    // subscription can opt into updating through the running core
    // instead (some providers rate-limit direct datacenter exits
    // less than home IPs, or the reverse).
    client.findProxy = updateSub?.updateViaProxy == true
        ? (_) => 'PROXY 127.0.0.1:7890'
        : (_) => 'DIRECT';
    try {
      client.userAgent = updateSub?.ua ?? _defaultUa;
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
      if (response.statusCode != 200) {
        if (!quiet) _toast('拉取失败：HTTP ${response.statusCode}');
        return;
      }
      final subInfo =
          _formatSubInfo(response.headers.value('subscription-userinfo'));
      var text = await response.transform(utf8.decoder).join();
      if (updateSub != null) {
        // A subscription added from a JSON/link import stores the
        // converted YAML; its updates arrive in the original
        // format, so normalise again before filtering/translating.
        text = CoreBridge().convertImport(text)['yaml'] as String;
      }
      if (updateSub != null &&
          (updateSub.keepRegex.isNotEmpty || updateSub.dropRegex.isNotEmpty)) {
        text = CoreBridge().filterNodes(
          text,
          updateSub.keepRegex,
          updateSub.dropRegex,
        );
      }
      if (updateSub != null) {
        final docs = await getApplicationDocumentsDirectory();
        _logPath = '${docs.path}/xray-error.log';
        final profile = await _translate(text);
        await _subFile(docs, updateSub.id).writeAsString(text);
        updateSub
          ..subInfo = subInfo ?? updateSub.subInfo
          ..nodeCount = profile.nodes.length
          ..updatedAtMs = DateTime.now().millisecondsSinceEpoch;
        await _persistSubs();
        if (updateSub.id == _activeSubId) {
          await _activateYaml(text, name: updateSub.name);
        } else {
          setState(() {});
        }
        if (quiet) {
          _logEvent(
            'auto-update: ${updateSub.name} refreshed '
            '(${profile.nodes.length} nodes)',
          );
          _notifySubAutoUpdated(updateSub.name);
        } else {
          _toast('订阅已更新：${profile.nodes.length} 个节点');
        }
      } else {
        final host = Uri.parse(url).host;
        await _addSubFromYaml(
          text,
          name: host.isEmpty ? '订阅配置' : host,
          url: url,
          subInfo: subInfo,
        );
      }
    } on CoreException catch (e) {
      if (!quiet) _toast('订阅内容不可用：${e.message}');
    } catch (e) {
      if (!quiet) _toast('拉取失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _importFromUrl() async {
    final url = await _askUrl();
    if (url != null) await _fetchSubscription(url);
  }

  Future<void> _setBypassSettings(
    bool enabled,
    bool allow,
    Set<String> pkgs,
  ) async {
    setState(() {
      _splitEnabled = enabled;
      _splitAllow = allow;
      _bypassPkgs = pkgs;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bypass_enabled', enabled);
    await prefs.setBool('bypass_allow', allow);
    await prefs.setString('bypass_pkgs', jsonEncode(pkgs.toList()));
    _toast('分应用设置已保存，下次启动 VPN 时生效');
  }

  void _startPolling() {
    _pollTimer?.cancel();
    var lastUp = 0;
    var lastDown = 0;
    var speedUp = 0.0;
    var speedDown = 0.0;
    var lastTick = DateTime.now();
    _traffic.value = const _Traffic();
    _rateHistory.value = const [];
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_running) return;
      try {
        // VPN mode reads the in-process core's counters;
        // root mode reads the traffic file the daemon's
        // core publishes beside its config (0.68) - the
        // counters cannot cross processes any other way.
        final Map<String, dynamic> decoded;
        if (_daemonMode) {
          final file = await _readRootTraffic();
          if (file == null) return;
          decoded = file;
        } else {
          decoded =
              jsonDecode(CoreBridge().xrayTraffic()) as Map<String, dynamic>;
        }
        final up = (decoded['up'] as num).toInt();
        final down = (decoded['down'] as num).toInt();
        final now = DateTime.now();
        final dt = now.difference(lastTick).inMilliseconds / 1000.0;
        // Counters restart from zero on an in-place core
        // restart (node/subscription/mode switch, bulk speed
        // test): a backwards counter is a NEW core instance -
        // zero rates this tick and drop the old instance's
        // samples, which are not this connection's traffic.
        final counterReset = up < lastUp || down < lastDown;
        if (counterReset) {
          speedUp = 0;
          speedDown = 0;
        } else if (dt > 0) {
          speedUp = (up - lastUp) / dt;
          speedDown = (down - lastDown) / dt;
        }
        lastUp = up;
        lastDown = down;
        lastTick = now;
        _traffic.value = _Traffic(
          up: up,
          down: down,
          speedUp: speedUp,
          speedDown: speedDown,
        );
        if (counterReset) {
          _rateHistory.value = const [];
        } else {
          final hist = [
            ..._rateHistory.value,
            _RateSample(speedUp, speedDown),
          ];
          if (hist.length > 45) hist.removeRange(0, hist.length - 45);
          _rateHistory.value = hist;
        }
        _pushVpnStatus();
      } catch (_) {
        // A failed poll just skips a beat; the next one retries.
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _startedAt = null;
    _traffic.value = const _Traffic();
    _rateHistory.value = const [];
    _lastStatusText = null;
  }

  /// Full session teardown, run from the main toggle (and from
  /// resync when it clears a dead session's leftovers): packet
  /// forwarder and core first, then the host (the VPN tunnel or
  /// the local foreground service). The VPN stop is verified
  /// against the service's own state - a stop that only landed
  /// in Dart leaves a black-holing tunnel behind, which reads
  /// as "the VPN won't turn off".
  /// The root daemon's status file: "running" plus a pid
  /// line, "error: ..." or "stopped", written by the daemon
  /// itself (see cmd/flboxd). Empty when no daemon ever ran.
  Future<String> _readRootStatus() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/root-status.txt');
      if (!await f.exists()) return '';
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  /// The daemon core's cumulative proxy counters,
  /// published by flboxd every two seconds (root mode's
  /// substitute for the in-process traffic call).
  Future<Map<String, dynamic>?> _readRootTraffic() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/root-traffic.json');
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<int> _rootDaemonPid() async {
    final lines = (await _readRootStatus()).split('\n');
    return lines.length > 1 ? int.tryParse(lines[1].trim()) ?? 0 : 0;
  }

  /// Generates the daemon configs (core + bridge) for the
  /// current selection and writes them to the control files.
  /// Shared by the manual start path and the boot-autostart
  /// publisher: the service.d boot script starts flboxd with
  /// exactly these files, so they must always describe the
  /// node the user last picked. IPv6 is hard-off in root
  /// mode (0.68): the bridge's IPv6 UDP path is best-effort
  /// by design (its recovery layer salvages packets by port
  /// alone). The IPv6 switch governs the bridge too: on
  /// lets it try to capture v6 through the node (root
  /// data planes handle v6 poorly - an experiment, off
  /// by default); off keeps the daemon's sysctl v6
  /// guard on.
  Future<({String config, String bridge})> _writeRootDaemonConfigs() async {
    final node = _selectedNode;
    final yaml = _profileYaml;
    if (node == null || yaml == null) {
      throw '先到「代理」页选一个节点';
    }
    // The split preferences become the bridge policy:
    // whitelist when only listed apps proxy, blacklist when
    // listed apps bypass, global otherwise. Packages resolve
    // to uids on the Kotlin side (PackageManager lives
    // there); the bridge programs match on uid.
    final mode = !_splitEnabled ? 2 : (_splitAllow ? 1 : 0);
    final routeMode = _outMode;
    var uids = <int>[];
    if (_splitEnabled && _bypassPkgs.isNotEmpty) {
      final res = await _vpnChannel.invokeMethod<List<Object?>>(
        'packageUids',
        _bypassPkgs.toList(),
      );
      uids = res?.whereType<int>().toList() ?? <int>[];
    }
    final logOff = !_logEnabled;
    final ipv6 = _ipv6Enabled;
    final envelope = await Isolate.run(
      () => CoreBridge().bridgeXrayConfig(
        yaml,
        node,
        ipv6: ipv6,
        mode: mode,
        uids: uids,
        routeMode: routeMode,
        logOff: logOff,
      ),
    );
    final decoded = jsonDecode(envelope) as Map<String, dynamic>;
    final docs = await getApplicationDocumentsDirectory();
    final cfgFile = File('${docs.path}/root-config.json');
    await cfgFile.writeAsString(decoded['core'] as String);
    final bridgeFile = File('${docs.path}/root-bridge.json');
    // AS keeps the two concerns apart: the bridge only
    // hears enableIpv6, while the system-wide disable is
    // a separate switch the daemon reads from this same
    // file (the bridge's key-lookup parser ignores it).
    final bridgeCfg =
        jsonDecode(decoded['bridge'] as String) as Map<String, dynamic>;
    bridgeCfg['disableSystemIpv6'] = _ipv6Disabler;
    await bridgeFile.writeAsString(jsonEncode(bridgeCfg));
    return (config: cfgFile.path, bridge: bridgeFile.path);
  }

  /// (Re)writes the daemon configs and launches the daemon
  /// through su, then waits for its status file to report.
  /// Throws a plain message string on failure.
  Future<void> _launchRootDaemon() async {
    final paths = await _writeRootDaemonConfigs();
    final docs = await getApplicationDocumentsDirectory();
    final statusFile = File('${docs.path}/root-status.txt');
    if (await statusFile.exists()) await statusFile.delete();
    // One log file per daemon session (0.66): the previous
    // session rotates to root-daemon.prev.log instead of
    // being appended to or wiped at a size threshold, so
    // the log page opens on exactly this session and the
    // last failure stays one tap away. The banner still
    // heads the file - other readers find sessions by it.
    final daemonLog = File('${docs.path}/root-daemon.log');
    try {
      final prevLog = File('${docs.path}/root-daemon.prev.log');
      if (await prevLog.exists()) await prevLog.delete();
      if (await daemonLog.exists()) await daemonLog.rename(prevLog.path);
      await daemonLog.writeAsString(
        '===== flboxd session ${DateTime.now().toIso8601String()} '
        'mode=ebpf node=$_selectedNode ipv6=false =====\n',
      );
    } catch (_) {}
    final ok =
        await _vpnChannel.invokeMethod<bool>('rootStart', {
          'config': paths.config,
          'status': statusFile.path,
          'log': '${docs.path}/root-daemon.log',
          'bridge': paths.bridge,
        }) ??
        false;
    if (!ok) throw '守护进程拉起失败';
    // The bridge supervisor starts a core AND the bridge
    // (with a capability probe first), so it gets a longer
    // budget than a plain daemon would need.
    for (var i = 0; i < 80; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final s = await _readRootStatus();
      if (s.startsWith('running')) return;
      if (s.startsWith('error:')) throw s.substring(6).trim();
    }
    throw '守护进程启动超时';
  }

  String? _deviceInfoCache;

  Future<String> _deviceInfo() async {
    final cached = _deviceInfoCache;
    if (cached != null) return cached;
    var info = '';
    try {
      info = await _vpnChannel.invokeMethod<String>('deviceInfo') ?? '';
    } catch (_) {}
    _deviceInfoCache = info;
    return info;
  }

  /// The last chunk of the daemon log, for the error
  /// dialog's startup-log section.
  Future<String> _daemonLogTail() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/root-daemon.log');
      if (!await f.exists()) return '';
      final raf = await f.open();
      try {
        final len = await raf.length();
        final start = len > 6000 ? len - 6000 : 0;
        await raf.setPosition(start);
        final bytes = await raf.read(len - start);
        var text = utf8.decode(bytes, allowMalformed: true);
        if (start > 0) {
          final nl = text.indexOf('\n');
          if (nl >= 0) text = text.substring(nl + 1);
        }
        return text.trim();
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  /// Asterisk-style start failure report: mode, time, the
  /// error detail, the device block and the startup log,
  /// with a one-tap full copy - instead of a toast that
  /// says "failed" and leaves nothing to diagnose from.
  Future<void> _showStartError(Object error) async {
    if (!mounted) return;
    final detail = error is _StartFailure ? error.detail : '$error';
    var logText = '';
    if (_daemonMode) {
      final tail = await _daemonLogTail();
      if (tail.isNotEmpty) logText = tail;
    }
    final device = await _deviceInfo();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final timeText =
        '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final modeText = switch (_runMode) {
      'ebpf' => 'Root eBPF',
      _ => 'VPN 模式',
    };
    final full = StringBuffer()
      ..writeln('代理启动失败')
      ..writeln('模式：$modeText')
      ..writeln('时间：$timeText')
      ..writeln()
      ..writeln('错误详情')
      ..writeln(detail);
    if (device.isNotEmpty) {
      full
        ..writeln()
        ..writeln('设备与系统')
        ..writeln(device);
    }
    if (logText.isNotEmpty) {
      full
        ..writeln()
        ..writeln('启动日志')
        ..writeln(logText);
    }
    if (!mounted) return;
    Widget section(String title, String body, {bool mono = false}) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(
              body,
              style: mono
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ],
        ),
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('代理启动失败'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText('模式：$modeText'),
              SelectableText('时间：$timeText'),
              section('错误详情', detail),
              if (device.isNotEmpty) section('设备与系统', device, mono: true),
              if (logText.isNotEmpty) section('启动日志', logText, mono: true),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: full.toString()));
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('复制日志'),
          ),
        ],
      ),
    );
  }

  Future<void> _startRootDaemon() async {
    if (_selectedNode == null || _profileYaml == null) {
      _toast('先到「代理」页选一个节点');
      return;
    }
    setState(() => _busy = true);
    try {
      final check = await _vpnChannel.invokeMethod<String>('rootCheck');
      if (check == 'nodaemon') {
        throw _StartFailure('此安装包未包含 root 守护进程');
      }
      if (check != 'ok') {
        throw _StartFailure('未取得 root 授权（su 不可用或被拒绝）');
      }
      final hasBridge =
          await _vpnChannel.invokeMethod<bool>('bridgeCheck') ?? false;
      if (!hasBridge) {
        throw _StartFailure('此安装包未包含 eBPF 桥组件（bpf2socks）');
      }
      await _launchRootDaemon();
      _logEvent('$_runMode started (node=$_selectedNode)');
      _startedAt = DateTime.now();
      setState(() => _running = true);
      _startPolling();
    } catch (e) {
      await _showStartError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopRootDaemon() async {
    // Bridge mode needs no steering teardown: signalling
    // the supervisor ends the bridge, which restores the
    // original cgroup programs as it exits.
    try {
      final pid = await _rootDaemonPid();
      if (pid > 0) {
        await _vpnChannel.invokeMethod('rootStop', pid);
        for (var i = 0; i < 12; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final s = await _readRootStatus();
          if (s.startsWith('stopped') || s.isEmpty) break;
        }
      }
      _logEvent('$_runMode stopped');
    } catch (_) {}
    _stopPolling();
    if (mounted) setState(() => _running = false);
  }

  /// Node/subscription/rules changes while running land here:
  /// the VPN path restarts the core in place; root mode
  /// regenerates the daemon config and bounces the daemon.
  Future<void> _restartForMode(String config) async {
    if (_daemonMode) {
      final pid = await _rootDaemonPid();
      if (pid > 0) {
        try {
          await _vpnChannel.invokeMethod('rootStop', pid);
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      try {
        await _launchRootDaemon();
      } catch (e) {
        throw CoreException('$e');
      }
      _logEvent('$_runMode restarted (node=$_selectedNode)');
    } else {
      await _restartCoreInPlace(config);
    }
  }

  Future<void> _setRunMode(String mode) async {
    if (mode == _runMode) return;
    if (_running) {
      _toast('先停止当前连接再切换运行模式');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (mode != 'ebpf' && _rootBootStart) {
      // The boot script only makes sense for the root
      // mode; leaving it installed would resurrect a
      // daemon in a mode the user no longer runs. The
      // preference itself survives the switch (the
      // user asked for that): only the script is
      // uninstalled, and coming back reinstalls it.
      await _applyRootBootScript(false);
      _logEvent('root boot script uninstalled for mode switch (preference kept)');
    }
    await prefs.setString('run_mode', mode);
    setState(() => _runMode = mode);
    if (mode == 'ebpf' && _rootBootStart) {
      if (await _tryInstallRootBootScript()) {
        _logEvent('root boot script reinstalled on return to eBPF mode');
      }
    }
  }

  /// Quietly republishes the daemon configs and
  /// installs the boot script. Used when the run mode
  /// returns to eBPF with the preference still on; the
  /// explicit settings toggle keeps its loud failure
  /// toasts in _setRootBootStart.
  Future<bool> _tryInstallRootBootScript() async {
    if (_selectedNode == null || _profileYaml == null) return false;
    final check = await _vpnChannel.invokeMethod<String>('rootCheck');
    if (check != 'ok') return false;
    try {
      await _writeRootDaemonConfigs();
    } catch (_) {
      return false;
    }
    return _applyRootBootScript(true);
  }

  Future<void> _stopCore() async {
    if (_daemonMode) {
      await _stopRootDaemon();
      return;
    }
    try {
      CoreBridge().vpnForwardStop();
    } catch (_) {}
    try {
      CoreBridge().xrayStop();
    } catch (_) {}
    try {
      await _vpnChannel.invokeMethod('stopVpn');
    } catch (_) {}
    _tunFd = 0;
      // "Down" means the service is actually destroyed, not
      // merely flagged inactive: a VpnService the system still
      // holds a VPN binding on stays alive (and its key icon
      // stays in the status bar) even after stopVpn() ran.
      var down = false;
      for (var i = 0; i < 8 && !down; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        try {
          final alive =
              await _vpnChannel.invokeMethod<bool>('vpnServiceAlive') ??
                  false;
          down = !alive;
        } catch (_) {
          down = true;
        }
      }
    if (down) {
      _logEvent('core stopped (vpn service down)');
    } else {
      _logEvent('stop: vpn service still alive, retrying stop');
      try {
        await _vpnChannel.invokeMethod('stopVpn');
      } catch (_) {}
    }
    _stopPolling();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _toggleCore() async {
    if (_busy) return;
    if (_running) {
      await _stopCore();
      return;
    }
    if (_daemonMode) {
      await _startRootDaemon();
      return;
    }
    final config = _profile?.configs[_selectedNode];
    if (config == null) {
      _toast('先到「代理」页选一个节点');
      return;
    }
    setState(() => _busy = true);
    try {
      final prep = await _vpnChannel.invokeMethod<String>('prepare');
      if (prep != 'granted') {
        throw _StartFailure('未授予 VPN 权限');
      }
      // A tunnel left over from a previous engine or process
      // (its stop never landed) would make the service's start a
      // no-op and hang the fd wait below forever. Clear it first.
      final stale =
          await _vpnChannel.invokeMethod<bool>('vpnActive') ?? false;
      if (stale) {
        _logEvent('start: clearing stale VPN tunnel first');
        await _vpnChannel.invokeMethod('stopVpn');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await _rotateLogIfHuge();
      CoreBridge().xrayStart(config, 0);
      // IPv6 follows the manual switch: the VpnService
      // builder and the forwarder both take the value up
      // front, and the session records it.
      final v6 = _ipv6Enabled;
      _tunReady = Completer<int>();
      await _vpnChannel.invokeMethod('startVpn', {
        'bypass': _bypassPkgs.toList(),
        'ipv6': v6,
        'splitOn': _splitEnabled,
        'splitAllow': _splitAllow,
      });
      final fd = await _tunReady!.future.timeout(const Duration(seconds: 15));
      _tunFd = fd;
      // The packet path: sing-box owns the tunnel fd and forwards
      // every flow into the mixed inbound Xray just opened.
      await _ensureSbSetup();
      CoreBridge().vpnForwardStart(fd, ipv6: v6);
      _vpnIpv6 = v6;
      unawaited(SharedPreferences.getInstance()
          .then((p) => p.setBool('vpn_ipv6_effective', v6)));
      _logEvent('vpn forwarder started (sing-box tun -> 127.0.0.1:7890)');
      _logEvent('ipv6 manual: ${v6 ? 'on' : 'off'}');
      _logEvent('core started (mode=$_outModeName, node=$_selectedNode)');
      _startedAt = DateTime.now();
      setState(() => _running = true);
      _startPolling();
      unawaited(_primeStatus());
    } catch (e) {
      try {
        CoreBridge().vpnForwardStop();
      } catch (_) {}
      try {
        CoreBridge().xrayStop();
      } catch (_) {}
      try {
        await _vpnChannel.invokeMethod('stopVpn');
      } catch (_) {}
      _tunFd = 0;
      await _showStartError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Posts a status notification through the platform side
  /// (the flbox_status channel in MainActivity).
  Future<void> _notify(String title, String text) async {
    try {
      await _vpnChannel.invokeMethod('notifyStatus', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  /// Probes the freshly started node's latency through the
  /// running core, backfills the node's card delay, and seeds
  /// the resident notification's status line.
  Future<void> _primeStatus() async {
    final node = _selectedNode;
    if (node == null) return;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!_running) return;
      final latency = await _probePort(7890);
      if (latency != null && mounted) {
        setState(() => _delays[node] = latency);
      }
      _pushVpnStatus();
    } catch (_) {}
  }

  String? _lastStatusText;

  /// Pushes the live status line (node, latency, up/down
  /// rates) into the VPN service's resident foreground
  /// notification - the one notification that cannot be
  /// swiped or cleared away while the session runs. Gated by
  /// the Settings toggle (the start-notification switch, kept
  /// under the same pref key); when off, the service keeps
  /// its plain default text.
  void _pushVpnStatus() {
    if (_daemonMode || !_notifyOnStart || !_running) return;
    final node = _selectedNode;
    if (node == null) return;
    final delay = _delays[node];
    final t = _traffic.value;
    final text = StringBuffer(node);
    if (delay != null) text.write(' · 延迟 $delay ms');
    text.write(' · ↓ ${_fmtSpeed(t.speedDown)} ↑ ${_fmtSpeed(t.speedUp)}');
    final s = text.toString();
    if (s == _lastStatusText) return;
    _lastStatusText = s;
    _vpnChannel.invokeMethod('updateVpnStatus', {
      'title': 'FlBox VPN 运行中',
      'text': s,
    }).catchError((_) => null);
  }

  void _notifySubAutoUpdated(String name) {
    if (!_notifySubUpdate) return;
    unawaited(_notify('订阅已自动更新', name));
  }

  Future<int?> _probePort(int port) async {
    HttpClient? client;
    try {
      final sw = Stopwatch()..start();
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
      final req = await client
          .getUrl(Uri.parse('http://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      await resp.drain<void>();
      sw.stop();
      return (resp.statusCode == 204 || resp.statusCode == 200)
          ? sw.elapsedMilliseconds
          : null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Parallel latency test, v2rayNG's design (0.45): each node
  /// is measured by ONE self-contained core call that trims the
  /// node's config to its outbound essentials, starts a
  /// throwaway instance with no inbounds, probes through the
  /// instance itself and closes it - see xrayMeasureDelay in
  /// the core. Eight workers run these calls concurrently. The
  /// main instance - and with it any live VPN session - is
  /// never touched: nothing needs restoring afterwards, the
  /// session keeps carrying traffic while the test flies, and
  /// the user is NOT locked out of other operations meanwhile.
  ///
  /// History: the test began as ONE combined instance holding
  /// every outbound at once (TranslateAll), which flash-crashed
  /// the app on the user's phone (0.39-0.41). The 0.42 fallback
  /// swapped the main instance node by node - correct, but the
  /// better part of a minute for a big profile, and it had to
  /// refuse toggles and node switches for the duration; the
  /// user sent that back as too slow. The 0.43/0.44 design kept
  /// per-node throwaway instances in a registry across separate
  /// start/probe/stop calls: 0.43 serialized the starts behind
  /// a registry lock and loaded the rule-mode geo data in every
  /// instance (slow), and 0.44's truly parallel starts on
  /// listening instances died partway through the list on the
  /// phone (32 of 47 starts logged inside two seconds, then
  /// the process was gone). The core-side test-instance entry
  /// points remain as a fallback but have no caller now.
  /// 0.45's first cut of this measure design still died (at 23
  /// completions) and 0.46 - which serialized the instance
  /// lifecycle and kept only the probes parallel - died at 25,
  /// so in-process scheduling was never the deciding variable.
  /// The remaining structural difference with v2rayNG was the
  /// process itself: its CoreTestService runs in a separate
  /// ":tasks" process, so a native abort there costs a test
  /// run, not the app. Since 0.47 the default path is the
  /// same split: the job goes to the FlboxTestService process
  /// (see testMain) and results stream back through a results
  /// file this method polls. Every build through 0.50 still
  /// stopped at exactly 23 completions - inside the test
  /// process, which is exactly where that failure belongs -
  /// so since 0.51 the list is measured in chunks of six,
  /// each chunk in a fresh test process with a bounded blast
  /// radius (see _testAllViaService). The in-process workers
  /// below remain as a fallback for when the service cannot
  /// be started at all.
  ///
  /// Nodes are logged before the run and each result is logged
  /// as it lands, so the log page still shows exactly how far
  /// a run got.
  Future<void> _testAll() async {
    if (_testing || _profile == null) return;
    final entries = <MapEntry<String, String>>[
      for (final n in _profile!.nodes)
        if (!isInfoNode(n.name) && _profile!.configs[n.name] != null)
          MapEntry(n.name, _profile!.configs[n.name]!),
    ];
    if (entries.isEmpty) return;
    setState(() {
      _testing = true;
      _delays = {};
    });
    for (final entry in entries) {
      _logEvent('speed test: ${entry.key}');
    }
    try {
      final isolated = await _testAllViaService(entries);
      if (!isolated) {
        _logEvent('speed test: test service unavailable, in-process');
        await _measureAllInProcess(entries);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Ships the job to the test process and polls its results
  /// file (through the platform channel) until every node has
  /// a result. Six builds (0.45-0.50) all stopped at exactly
  /// 23 results on this subscription, in every process shape
  /// tried, with the missing results scattered - the signature
  /// of one node's instance wedging the shared machinery
  /// while its neighbours were in flight, not of a counting
  /// or channel bug (the close-out-of-lock theory of 0.50 was
  /// falsified by its own run: closes no longer gate results,
  /// yet the count froze at 23 again). Rather than hunt the
  /// poison node through more theories, the blast radius is
  /// now bounded by construction: the list is measured in
  /// chunks of six, each chunk in a fresh test process. A
  /// chunk that wedges is force-killed at the stall, its
  /// unreported nodes are recorded as timeouts, and the run
  /// moves on - the tail of the list, which no earlier build
  /// ever reached, finally gets measured, and the chunk
  /// boundary lines in the log narrow any poison node down
  /// to six names. Returns false only when the first chunk
  /// could not be started at all, so the caller can fall back
  /// to measuring in-process.
  Future<bool> _testAllViaService(
    List<MapEntry<String, String>> entries,
  ) async {
    const chunkSize = 6;
    var anyLaunched = false;
    for (var start = 0; start < entries.length; start += chunkSize) {
      final end = start + chunkSize > entries.length
          ? entries.length
          : start + chunkSize;
      final chunk = entries.sublist(start, end);
      _logEvent(
        'speed test: chunk ${start ~/ chunkSize + 1} '
        '(${chunk.length} nodes)',
      );
      var started = false;
      try {
        // Every chunk gets a fresh test process: killing the
        // previous one is a no-op when it exited on its own.
        await _vpnChannel.invokeMethod('killTestProcess');
        // Give a dying process a moment to actually exit, so
        // the start is not handed to an instance that is still
        // being torn down (the 0.48 relaunch was lost exactly
        // that way). When the platform hides the process from
        // the scan this exits at once, and the service's
        // rebuild-on-start covers that case.
        for (var i = 0; i < 15; i++) {
          final alive =
              await _vpnChannel.invokeMethod<bool>('testProcessAlive') ??
                  false;
          if (!alive) break;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final job = jsonEncode({
          'url': 'http://www.gstatic.com/generate_204',
          'items': [
            for (final e in chunk) {'name': e.key, 'config': e.value},
          ],
        });
        final written =
            await _vpnChannel.invokeMethod<bool>('writeTestJob', job) ??
                false;
        started = written &&
            (await _vpnChannel.invokeMethod<bool>('startTestService') ??
                false);
      } catch (_) {
        started = false;
      }
      if (!started) {
        if (!anyLaunched) return false;
        // A later chunk that cannot even start counts as
        // timed out wholesale; the run still continues.
        if (mounted) {
          setState(() {
            _delays = {..._delays, for (final e in chunk) e.key: null};
          });
        }
        _logEvent('speed test: chunk failed to start');
        continue;
      }
      anyLaunched = true;
      final got = await _pollTestResults({for (final e in chunk) e.key});
      if (!mounted) return true;
      // Whatever the chunk did not report - wedged instance,
      // dead process - is a timeout for those nodes; the run
      // moves on to the next chunk regardless.
      final missing = [
        for (final e in chunk)
          if (!got.contains(e.key)) e.key,
      ];
      if (missing.isNotEmpty) {
        setState(() {
          _delays = {..._delays, for (final name in missing) name: null};
        });
        _logEvent(
          'speed test: chunk gave up on ${missing.length} nodes',
        );
      }
    }
    return anyLaunched;
  }

  /// One launch's polling: applies result lines as they land
  /// and returns the set of node names that reported. Ends
  /// when the launch reports done, stalls for 15 seconds (the
  /// test process died or wedged), or hits a per-launch cap.
  Future<Set<String>> _pollTestResults(Set<String> names) async {
    final got = <String>{};
    var consumed = 0;
    var lastProgress = DateTime.now();
    final launchStart = DateTime.now();
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) {
        try {
          await _vpnChannel.invokeMethod('stopTestService');
        } catch (_) {}
        return got;
      }
      Map<dynamic, dynamic>? res;
      try {
        res = await _vpnChannel
            .invokeMethod<Map<dynamic, dynamic>>('readTestResults');
      } catch (_) {
        res = null;
      }
      if (res == null) break;
      final done = res['done'] == true;
      final lines = <String>[
        for (final l in (res['lines'] as String? ?? '').split('\n'))
          if (l.trim().isNotEmpty) l,
      ];
      final batch = <String, int?>{};
      while (consumed < lines.length) {
        final line = lines[consumed++];
        lastProgress = DateTime.now();
        try {
          final m = jsonDecode(line) as Map<String, dynamic>;
          final name = m['name'] as String?;
          if (name == null || !names.contains(name)) continue;
          got.add(name);
          final raw = (m['ms'] as num?)?.toInt() ?? -1;
          final ms = raw >= 0 ? raw : null;
          _logEvent('speed test done: $name ${ms ?? 'timeout'}');
          batch[name] = ms;
        } catch (_) {}
      }
      if (batch.isNotEmpty && mounted) {
        setState(() => _delays = {..._delays, ...batch});
      }
      if (done) break;
      if (DateTime.now().difference(lastProgress) >
          const Duration(seconds: 15)) {
        _logEvent('speed test: launch stalled, will relaunch');
        break;
      }
      if (DateTime.now().difference(launchStart) >
          const Duration(seconds: 150)) {
        break;
      }
    }
    return got;
  }

  /// The pre-0.47 in-process measurement, kept as the fallback
  /// for when the test service cannot start. Eight workers,
  /// core-side lifecycle serialization (0.46) still applies.
  Future<void> _measureAllInProcess(
    List<MapEntry<String, String>> entries,
  ) async {
    var next = 0;
    // Results land in a pending map and flush to the UI at
    // most every 300ms: one setState per finished node (44
    // for a big profile, times eight workers) rebuilt the
    // whole page each time and made the grid stutter while
    // the test ran. The delays still appear progressively,
    // just in small batches.
    final pending = <String, int?>{};
    Timer? flushTimer;
    void flush() {
      if (pending.isEmpty || !mounted) return;
      final batch = Map<String, int?>.of(pending);
      pending.clear();
      setState(() => _delays = {..._delays, ...batch});
    }

    flushTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => flush(),
    );
    Future<void> worker() async {
      while (next < entries.length) {
        final entry = entries[next++];
        int? ms;
        try {
          final r = await _xrayMeasureInIsolate(
            entry.value,
            'http://www.gstatic.com/generate_204',
          );
          ms = r >= 0 ? r : null;
        } catch (e) {
          _logEvent('speed test: ${entry.key} failed: $e');
          ms = null;
        }
        _logEvent('speed test done: ${entry.key} ${ms ?? 'timeout'}');
        pending[entry.key] = ms;
      }
    }

    try {
      await Future.wait([for (var i = 0; i < 8; i++) worker()]);
    } finally {
      flushTimer.cancel();
      flush();
    }
  }

  Future<void> _pickFastest() async {
    await _testAll();
    if (!mounted || _profile == null) return;
    String? best;
    int? bestMs;
    for (final n in _profile!.nodes) {
      if (isInfoNode(n.name)) continue;
      final d = _delays[n.name];
      if (d != null && (bestMs == null || d < bestMs)) {
        best = n.name;
        bestMs = d;
      }
    }
    if (best == null) {
      _toast('没有测到可用节点');
      return;
    }
    await _selectNode(best);
    _toast('已选最快节点：$best（$bestMs ms）');
  }

  Future<void> _selectNode(String name) async {
    if (name == _selectedNode) return;
    setState(() => _selectedNode = name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_node', name);
    if (_running) {
      final config = _profile?.configs[name];
      if (config == null) return;
      try {
        await _restartForMode(config);
        _pushVpnStatus();
        unawaited(_primeStatus());
        _toast('已切换到 $name');
      } on CoreException catch (e) {
        setState(() => _running = false);
        _toast('切换失败：${e.message}');
      }
    }
    unawaited(_republishRootConfigsIfNeeded());
  }

  Future<void> _openSettings() async {
    try {
      _batteryIgnored =
          await _vpnChannel.invokeMethod<bool>('batteryState') ?? false;
      final docs = await getApplicationDocumentsDirectory();
      _geoReady = await File('${docs.path}/geoip.dat').exists() &&
          await File('${docs.path}/geosite.dat').exists();
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsPage(
          navStyle: _navStyle,
          onNavStyleChanged: _setNavStyle,
          notifyOnStart: _notifyOnStart,
          onNotifyOnStartChanged: _setNotifyOnStart,
          notifySubUpdate: _notifySubUpdate,
          onNotifySubUpdateChanged: _setNotifySubUpdate,
          bypassPkgs: _bypassPkgs,
          bypassEnabled: _splitEnabled,
          bypassAllow: _splitAllow,
          onBypassSettingsChanged: _setBypassSettings,
          batteryIgnored: _batteryIgnored,
          onOpenBatterySettings: () async {
            try {
              await _vpnChannel.invokeMethod('openBatterySettings');
            } catch (_) {}
          },
          outMode: _outMode,
          onOutModeChanged: _setOutMode,
          geoReady: _geoReady,
          onUpdateGeo: _updateGeoData,
          autoIntervalHours: _subAutoIntervalHours,
          onAutoIntervalChanged: _setSubAutoInterval,
          ipv6Enabled: _ipv6Enabled,
          onIpv6Changed: _setIpv6Enabled,
          ipv6Disabler: _ipv6Disabler,
          onIpv6DisablerChanged: _setIpv6Disabler,
          logEnabled: _logEnabled,
          onLogEnabledChanged: _setLogEnabled,
          rootBootStart: _rootBootStart,
          onRootBootStartChanged: _setRootBootStart,
          runMode: _runMode,
          onRunModeChanged: _setRunMode,
          onExportBackup: _exportBackup,
          onImportBackup: _importBackup,
        ),
      ),
    );
    _checkNetwork();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _subTimer?.cancel();
    _traffic.dispose();
    _rateHistory.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// The log page is a pushed route off the tools tab
  /// since 0.69 (the reference layout's four tabs are
  /// dashboard, proxies, profiles, tools).
  void _openLogs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogsPage(ebpfMode: _runMode == 'ebpf'),
      ),
    );
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _pageAnimating = true;
    _pageController
        .animateToPage(
          index,
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _pageAnimating = false);
  }

  void _setNavStyle(NavStyle style) {
    setState(() => _navStyle = style);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt('nav_style', style.index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          if (_pageAnimating) {
            // A nav-initiated jump is in flight: the pages
            // it passes through are not selections.
            // Reacting to them re-set the index per page
            // and restarted the nav pill's slide each
            // time - one restart per page crossed.
            if (index == _index) _pageAnimating = false;
            return;
          }
          setState(() => _index = index);
        },
        children: [
          _DashboardPage(
            onOpenSettings: _openSettings,
            running: _running,
            hasProfile: _profile != null,
            currentNode: _selectedNode,
            traffic: _traffic,
            rates: _rateHistory,
            startedAt: _startedAt,
            netBlocked: _netBlocked,
            onOpenNetSettings: _openNetSettings,
            onRecheckNetwork: _checkNetwork,
            profileName: _profileName,
            currentDelay:
                _selectedNode != null ? _delays[_selectedNode] : null,
            outMode: _outMode,
            onOutModeChanged: _setOutMode,
            onShowProxies: () => _select(1),
            onToggle: _busy ? null : _toggleCore,
            busy: _busy,
            ebpfMode: _runMode == 'ebpf',
            vpnIpv6: _vpnIpv6,
          ),
          ProxiesPage(
            onEditNode: _openNodeEditor,
            onAddNode: () => _openNodeEditor(),
            onImportLink: _importFromLink,
            profile: _profile,
            profileName: _profileName,
            selectedNode: _selectedNode,
            onSelect: _selectNode,
            delays: _delays,
            testing: _testing,
            onTestAll: _profile == null ? null : _testAll,
            favorites: _favNodes,
            onToggleFav: _toggleFav,
            onPickFastest: _profile == null ? null : _pickFastest,
          ),
          ProfilesPage(
            subs: _subs,
            activeSubId: _activeSubId,
            activeSkipped: _profile?.skipped ?? const [],
            onImport: _importProfile,
            onImportUrl: _importFromUrl,
            onSwitch: _switchSub,
            onUpdate: (sub) => _fetchSubscription(sub.url!, updateSub: sub),
            onDelete: _deleteSub,
            onEditSub: _openSubEditor,
            onImportLink: _importFromLink,
            onToggleEnabled: _setSubEnabled,
            onUpdateAll: _updateAllSubs,
          ),
          _ToolsPage(
            onOpenLogs: _openLogs,
            onOpenSettings: _openSettings,
            geoReady: _geoReady,
            onUpdateGeo: _updateGeoData,
          ),
        ],
      ),
      bottomNavigationBar: RepaintBoundary(
        child: switch (_navStyle) {
        NavStyle.glass => _GlassNavBar(
            index: _index,
            destinations: _destinations,
            onTap: _select,
          ),
        NavStyle.slidingGlass => _SlidingGlassNavBar(
            index: _index,
            destinations: _destinations,
            onTap: _select,
          ),
        },
      ),
    );
  }
}

// Shared glass shell for the two glass bars: gradient specular edge,
// backdrop blur with a saturation lift, translucent fill, soft shadow.
class _GlassShell extends StatelessWidget {
  const _GlassShell({required this.child, this.pressGlow = 0});

  static final ImageFilter _blurFilter =
      ImageFilter.blur(sigmaX: 16, sigmaY: 16);

  final Widget child;
  final double pressGlow;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final fill = dark
        ? const Color(0xFF1D1D20).withValues(alpha: 0.38)
        : Colors.white.withValues(alpha: 0.30 + pressGlow * 0.08);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: dark ? 0.28 : 0.75),
                Colors.white.withValues(alpha: dark ? 0.05 : 0.12),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(31),
            child: BackdropFilter(
              // Plain blur only: composing a saturation matrix over a
              // sigma-26 blur made every frame scrolled under the
              // floating bar pay for the full filter chain.
              filter: _blurFilter,
              child: Container(color: fill, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItemContent extends StatelessWidget {
  const _NavItemContent({required this.destination, required this.selected});

  final _Destination destination;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        selected ? _accent : scheme.onSurface.withValues(alpha: 0.45);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(destination.icon, size: 22, color: color),
        const SizedBox(height: 3),
        Text(
          destination.label,
          style: TextStyle(fontSize: 11, color: color, height: 1),
        ),
      ],
    );
  }
}

// Static liquid glass: the pill slides with an ease curve. No physics,
// no drag.
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.index,
    required this.destinations,
    required this.onTap,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    const horizontalPadding = 5.0;
    return _GlassShell(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final itemWidth =
              (constraints.maxWidth - horizontalPadding * 2) /
                  destinations.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                left: horizontalPadding + index * itemWidth,
                top: 5,
                bottom: 5,
                width: itemWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: dark ? 0.26 : 0.15),
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: _NavItemContent(
                          destination: destinations[i],
                          selected: i == index,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

// Sliding glass: looks exactly like the static glass bar, but the pill
// can be dragged between items and swells while pressed.
class _SlidingGlassNavBar extends StatefulWidget {
  const _SlidingGlassNavBar({
    required this.index,
    required this.destinations,
    required this.onTap,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onTap;

  @override
  State<_SlidingGlassNavBar> createState() => _SlidingGlassNavBarState();
}

class _SlidingGlassNavBarState extends State<_SlidingGlassNavBar>
    with TickerProviderStateMixin {
  static const _horizontalPadding = 5.0;

  late final AnimationController _slideController;
  late final AnimationController _pressController;
  late final CurvedAnimation _slideCurve;
  Tween<double>? _tween;
  double _pos = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _pos = widget.index.toDouble();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slideCurve = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    );
    _slideController.addListener(() {
      final tween = _tween;
      if (tween != null) {
        setState(() => _pos = tween.evaluate(_slideCurve));
      }
    });
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
  }

  @override
  void didUpdateWidget(_SlidingGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && widget.index != oldWidget.index) {
      final target = widget.index.toDouble();
      if (_slideController.isAnimating && _tween?.end == target) {
        return; // already settling there
      }
      _slideTo(target);
    }
  }

  @override
  void dispose() {
    _slideCurve.dispose();
    _slideController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  void _slideTo(double target) {
    _tween = Tween<double>(begin: _pos, end: target);
    _slideController
      ..reset()
      ..forward();
  }

  int get _nearest =>
      _pos.round().clamp(0, widget.destinations.length - 1);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _pressController,
      builder: (context, _) {
        final press = Curves.easeOut.transform(_pressController.value);
        return _GlassShell(
          pressGlow: press,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth =
                  (constraints.maxWidth - _horizontalPadding * 2) /
                      widget.destinations.length;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) {
                  _dragging = true;
                  _slideController.stop();
                  _pressController.forward();
                },
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _pos = (_pos + details.delta.dx / itemWidth)
                        .clamp(-0.15, widget.destinations.length - 0.85);
                  });
                },
                onHorizontalDragEnd: (_) {
                  _dragging = false;
                  _pressController.reverse();
                  final target = _nearest;
                  if (target != widget.index) {
                    HapticFeedback.selectionClick();
                    // No local slide: the parent's index
                    // change drives the settle through
                    // didUpdateWidget. Sliding here as
                    // well ran it twice - the extra
                    // bounce after a pill drag.
                    widget.onTap(target);
                  } else {
                    _slideTo(target.toDouble());
                  }
                },
                onLongPressStart: (_) {
                  HapticFeedback.selectionClick();
                  _pressController.forward();
                },
                onLongPressEnd: (_) => _pressController.reverse(),
                onLongPressCancel: () => _pressController.reverse(),
                child: Stack(
                  children: [
                    Positioned(
                      left: _horizontalPadding + _pos * itemWidth,
                      top: 5,
                      bottom: 5,
                      width: itemWidth,
                      child: Transform.scale(
                        scale: 1 + press * 0.10,
                        child: Container(
                          decoration: BoxDecoration(
                            color: _accent.withValues(
                              alpha: (dark ? 0.26 : 0.15) + press * 0.07,
                            ),
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < widget.destinations.length; i++)
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (_) => _pressController.forward(),
                              onTapUp: (_) => _pressController.reverse(),
                              onTapCancel: () => _pressController.reverse(),
                              onTap: () => widget.onTap(i),
                              child: _NavItemContent(
                                destination: widget.destinations[i],
                                selected: _nearest == i,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        // Content runs under the floating glass bar
        // (extendBody); each scrollable page carries
        // its own bottom spacer so its last card can
        // still scroll fully clear of the bar.
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const Spacer(),
                ?action,
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtSpeed(double bps) => '${_fmtBytes(bps.round())}/s';

String _fmtDuration(Duration d) {
  final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
  final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
}

/// Solid card surface (white in light mode, raised dark
/// grey in dark mode) over the grey page - the reference
/// client's look, replacing the old translucent fills that
/// read as unfinished.
Color _cardColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E1E22)
        : Colors.white;

/// Card surface with depth: the shared fill plus a hairline
/// border and, in light mode, a faint shadow. Flat fills alone
/// read as unfinished; every page's cards use this.
BoxDecoration _cardDecoration(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: _cardColor(context),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(
      color: Theme.of(context)
          .colorScheme
          .onSurface
          .withValues(alpha: dark ? 0.09 : 0.05),
    ),
    boxShadow: dark
        ? const []
        : [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.045),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
  );
}

/// Rounded-square tinted icon tile (card and section leads).
Widget _iconTile(IconData icon, {Color color = _accent, double size = 40}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(size * 0.3),
    ),
    child: Icon(icon, color: color, size: size * 0.52),
  );
}

/// Latency as a pill: colored dot and value on a tinted ground.
Widget _delayPill(int? delay, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          delay == null ? '超时' : '$delay ms',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.onOpenSettings,
    required this.running,
    required this.hasProfile,
    required this.currentNode,
    required this.traffic,
    required this.rates,
    required this.startedAt,
    required this.netBlocked,
    required this.onOpenNetSettings,
    required this.onRecheckNetwork,
    required this.profileName,
    required this.currentDelay,
    required this.outMode,
    required this.onOutModeChanged,
    required this.onShowProxies,
    required this.onToggle,
    required this.busy,
    this.ebpfMode = false,
    this.vpnIpv6 = false,
  });

  final VoidCallback? onToggle;
  final bool busy;

  final VoidCallback onOpenSettings;
  final bool running;
  final bool hasProfile;
  final String? currentNode;
  final ValueListenable<_Traffic> traffic;
  final ValueListenable<List<_RateSample>> rates;
  final DateTime? startedAt;
  final bool netBlocked;
  final VoidCallback onOpenNetSettings;
  final VoidCallback onRecheckNetwork;
  final String? profileName;
  final int? currentDelay;
  final int outMode;
  final ValueChanged<int> onOutModeChanged;
  final VoidCallback onShowProxies;
  final bool ebpfMode;
  final bool vpnIpv6;

  Widget _card(BuildContext context, {required Widget child, VoidCallback? onTap}) {
    return Container(
      decoration: _cardDecoration(context),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  Widget _speedCard(
    BuildContext context, {
    required IconData icon,
    required Color tint,
    required String label,
    required String speed,
    required String total,
    required Color muted,
  }) {
    return _card(
      context,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _iconTile(icon, color: tint, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: muted, fontSize: 12.5)),
                const SizedBox(height: 2),
                Text(
                  speed,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(total, style: TextStyle(color: muted, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: selected
            ? _accent.withValues(alpha: 0.16)
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected
                    ? _accent
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final String statusDetail;
    if (running) {
      statusDetail = ebpfMode
          ? 'Xray 核心 · bpf2socks 桥 · eBPF 模式'
          : 'Xray 核心 · sing-box 数据通路 · VPN 模式'
              '${vpnIpv6 ? ' · IPv6 开' : ' · IPv6 关'}';
    } else if (!hasProfile) {
      statusDetail = '先到「配置」页导入一个 Clash 配置';
    } else {
      statusDetail = '已就绪，点圆钮启动';
    }
    return _PageFrame(
      title: '仪表盘',
      action: IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: '设置',
        onPressed: onOpenSettings,
      ),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (netBlocked) ...[
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .error
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FlBox 当前无法联网',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '域名解析失败、所有连接都会超时——通常是系统的分应用联网开关把 FlBox 关了'
                      '（或是设备暂时离线）。去系统设置里确认「允许网络访问」已打开。',
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: onOpenNetSettings,
                          child: const Text('去打开联网开关'),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: onRecheckNetwork,
                          child: const Text('重新检测'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            ValueListenableBuilder<_Traffic>(
              valueListenable: traffic,
              builder: (context, traffic, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _card(
                    context,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text('状态',
                                      style: TextStyle(
                                          color: muted, fontSize: 13)),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: running
                                          ? const Color(0xFF34A853)
                                              .withValues(alpha: 0.12)
                                          : muted.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      running ? '运行中' : '未运行',
                                      style: TextStyle(
                                        color: running
                                            ? const Color(0xFF34A853)
                                            : muted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                currentNode ?? '未选择节点',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                statusDetail,
                                style:
                                    TextStyle(color: muted, fontSize: 12.5),
                              ),
                              if (running && startedAt != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  '运行时长 ${_fmtDuration(DateTime.now().difference(startedAt!))}',
                                  style: TextStyle(
                                      color: muted, fontSize: 12.5),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        // The session switch lives in the
                        // status card (the reference layout's
                        // big round button); the floating
                        // action button is gone.
                        Material(
                          color: _accent,
                          shape: const CircleBorder(),
                          elevation: 5,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: onToggle,
                            child: SizedBox(
                              width: 76,
                              height: 76,
                              child: busy
                                  ? const Padding(
                                      padding: EdgeInsets.all(24),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
                                      running ? Icons.stop : Icons.play_arrow,
                                      color: Colors.white,
                                      size: 36,
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _speedCard(
                          context,
                          icon: Icons.arrow_upward,
                          tint: const Color(0xFF34A853),
                          label: '上行',
                          speed: _fmtSpeed(traffic.speedUp),
                          total: '共 ${_fmtBytes(traffic.up)}',
                          muted: muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _speedCard(
                          context,
                          icon: Icons.arrow_downward,
                          tint: _accent,
                          label: '下行',
                          speed: _fmtSpeed(traffic.speedDown),
                          total: '共 ${_fmtBytes(traffic.down)}',
                          muted: muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<List<_RateSample>>(
              valueListenable: rates,
              builder: (context, samples, _) {
                var peakDown = 0.0;
                var peakUp = 0.0;
                for (final s in samples) {
                  if (s.down > peakDown) peakDown = s.down;
                  if (s.up > peakUp) peakUp = s.up;
                }
                return _card(
                  context,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('实时速率',
                              style: TextStyle(color: muted, fontSize: 13)),
                          const Spacer(),
                          Text(
                            samples.length < 2
                                ? '暂无数据'
                                : '峰值 ↓ ${_fmtSpeed(peakDown)} · ↑ ${_fmtSpeed(peakUp)}',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ],
                      ),
                      if (samples.length >= 2) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 72,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: _RateChartPainter(samples),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: _accent,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('下行',
                                style:
                                    TextStyle(color: muted, fontSize: 12)),
                            const SizedBox(width: 16),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF34A853),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('上行',
                                style:
                                    TextStyle(color: muted, fontSize: 12)),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            _card(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('出站模式', style: TextStyle(color: muted, fontSize: 13)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _modeChip(
                        context,
                        label: '全局模式',
                        selected: outMode == 1,
                        onTap: () => onOutModeChanged(1),
                      ),
                      const SizedBox(width: 10),
                      _modeChip(
                        context,
                        label: '规则模式',
                        selected: outMode == 0,
                        onTap: () => onOutModeChanged(0),
                      ),
                      const SizedBox(width: 10),
                      _modeChip(
                        context,
                        label: '直连模式',
                        selected: outMode == 2,
                        onTap: () => onOutModeChanged(2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              context,
              onTap: onShowProxies,
              child: Row(
                children: [
                  _iconTile(Icons.dns_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('当前节点',
                            style: TextStyle(color: muted, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(
                          currentNode ?? '-',
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '订阅：${profileName ?? '-'}',
                          style: TextStyle(color: muted, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (currentDelay != null) ...[
                    _delayPill(currentDelay, _delayColor(currentDelay)),
                    const SizedBox(width: 6),
                  ],
                  Icon(Icons.chevron_right, size: 18, color: muted),
                ],
              ),
            ),
            const SizedBox(height: 104),
          ],
        ),
      ),
    );
  }
}

/// Two-series rate history: download in the accent color with a
/// soft fill, upload in green. Right-aligned fixed window (the
/// sampler keeps at most 45 points, about 90 seconds).
class _RateChartPainter extends CustomPainter {
  _RateChartPainter(this.samples);

  final List<_RateSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    // Hard clip: a bogus sample must never paint outside the
    // chart box - the runaway lines across the dashboard at
    // group switches came from exactly that (negative rates
    // right after an in-place restart zeroed the counters).
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final baseline = Paint()
      ..color = Colors.grey.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      baseline,
    );
    if (samples.length < 2) return;
    var maxV = 0.0;
    for (final s in samples) {
      if (s.down > maxV) maxV = s.down;
      if (s.up > maxV) maxV = s.up;
    }
    if (maxV <= 0 || !maxV.isFinite) maxV = 1;
    final stepX = size.width / 44;
    double x(int i) => size.width - (samples.length - 1 - i) * stepX;
    double y(double v) {
      if (!v.isFinite) v = 0;
      final r = size.height - 3 - (v / maxV) * (size.height - 8);
      return r.clamp(0.0, size.height).toDouble();
    }

    final fill = Path()
      ..moveTo(x(0), y(samples[0].down));
    for (var i = 1; i < samples.length; i++) {
      fill.lineTo(x(i), y(samples[i].down));
    }
    fill
      ..lineTo(x(samples.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = _accent.withValues(alpha: 0.10),
    );

    void stroke(double Function(_RateSample) pick, Color color) {
      final path = Path()..moveTo(x(0), y(pick(samples[0])));
      for (var i = 1; i < samples.length; i++) {
        path.lineTo(x(i), y(pick(samples[i])));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    stroke((s) => s.down, _accent);
    stroke((s) => s.up, const Color(0xFF34A853));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RateChartPainter old) => old.samples != samples;
}

// Settings live on their own page, reached from the dashboard gear, so
// the main pages stay free of configuration controls.
class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.navStyle,
    required this.onNavStyleChanged,
    required this.notifyOnStart,
    required this.onNotifyOnStartChanged,
    required this.notifySubUpdate,
    required this.onNotifySubUpdateChanged,
    required this.bypassPkgs,
    required this.bypassEnabled,
    required this.bypassAllow,
    required this.onBypassSettingsChanged,
    required this.batteryIgnored,
    required this.onOpenBatterySettings,
    required this.outMode,
    required this.onOutModeChanged,
    required this.geoReady,
    required this.onUpdateGeo,
    required this.autoIntervalHours,
    required this.onAutoIntervalChanged,
    required this.ipv6Enabled,
    required this.onIpv6Changed,
    required this.ipv6Disabler,
    required this.onIpv6DisablerChanged,
    required this.logEnabled,
    required this.onLogEnabledChanged,
    required this.rootBootStart,
    required this.onRootBootStartChanged,
    required this.runMode,
    required this.onRunModeChanged,
    required this.onExportBackup,
    required this.onImportBackup,
  });

  final NavStyle navStyle;
  final ValueChanged<NavStyle> onNavStyleChanged;
  final bool notifyOnStart;
  final ValueChanged<bool> onNotifyOnStartChanged;
  final bool notifySubUpdate;
  final ValueChanged<bool> onNotifySubUpdateChanged;
  final Set<String> bypassPkgs;
  final bool bypassEnabled;
  final bool bypassAllow;
  final void Function(bool, bool, Set<String>) onBypassSettingsChanged;
  final bool batteryIgnored;
  final VoidCallback onOpenBatterySettings;
  final int outMode;
  final ValueChanged<int> onOutModeChanged;
  final bool geoReady;
  final VoidCallback onUpdateGeo;
  final int autoIntervalHours;
  final ValueChanged<int> onAutoIntervalChanged;
  final bool ipv6Enabled;
  final ValueChanged<bool> onIpv6Changed;
  final bool ipv6Disabler;
  final ValueChanged<bool> onIpv6DisablerChanged;
  final bool logEnabled;
  final ValueChanged<bool> onLogEnabledChanged;
  final bool rootBootStart;
  final ValueChanged<bool> onRootBootStartChanged;
  final String runMode;
  final ValueChanged<String> onRunModeChanged;
  final VoidCallback onExportBackup;
  final VoidCallback onImportBackup;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late NavStyle _navStyle = widget.navStyle;
  late int _autoIntervalHours = widget.autoIntervalHours;

  // Local copies of the remaining mutable values. This page is
  // a pushed route: it does not rebuild when the home shell
  // setStates after applying a change, so controls bound
  // straight to widget values looked frozen until the page was
  // closed and reopened. Each control updates its copy through
  // this page's own setState and forwards the change up. (The
  // routing-mode copy is optimistic: if the shell rejects the
  // switch it toasts, and the check corrects on next open.)
  late bool _rootBootStart = widget.rootBootStart;
  late bool _ipv6Enabled = widget.ipv6Enabled;
  late bool _ipv6Disabler = widget.ipv6Disabler;
  late bool _logEnabled = widget.logEnabled;
  late String _runMode = widget.runMode;
  late bool _notifyOnStart = widget.notifyOnStart;
  late bool _notifySubUpdate = widget.notifySubUpdate;
  late int _outMode = widget.outMode;
  late Set<String> _bypassPkgs = widget.bypassPkgs;
  late bool _splitEnabled = widget.bypassEnabled;
  late bool _splitAllow = widget.bypassAllow;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);

    // Grouped solid cards with a small header above each -
    // the settings layout of the reference client: grey page,
    // white cards, rows inside.
    Widget section(String title, List<Widget> rows) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: TextStyle(
                color: muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            decoration: _cardDecoration(context),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(children: rows),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          section('外观', [
            for (final style in NavStyle.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(style.label),
                trailing: _navStyle == style
                    ? const Icon(Icons.check, color: _accent)
                    : null,
                onTap: () {
                  setState(() => _navStyle = style);
                  widget.onNavStyleChanged(style);
                },
              ),
          ]),
          const SizedBox(height: 20),
          section('运行模式', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('VPN 模式'),
              subtitle: Text(
                '系统 VpnService 接管流量，无需 root',
                style: TextStyle(color: muted),
              ),
              trailing: _runMode == 'vpn'
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () {
                setState(() => _runMode = 'vpn');
                widget.onRunModeChanged('vpn');
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Root eBPF'),
              subtitle: Text(
                'root 守护进程＋流量重定向接管，无 TUN 设备；当前 IPv4，出站为${_outMode == 0 ? '规则' : (_outMode == 2 ? '直连' : '全局')}模式',
                style: TextStyle(color: muted),
              ),
              trailing: _runMode == 'ebpf'
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () {
                setState(() => _runMode = 'ebpf');
                widget.onRunModeChanged('ebpf');
              },
            ),
            if (_runMode == 'ebpf')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机自启动'),
                subtitle: Text(
                  'Magisk service.d 脚本在开机时直接拉起守护进程，不用打开应用（与 AsteriskNG 相同）；使用最近一次发布的节点配置',
                  style: TextStyle(color: muted),
                ),
                value: _rootBootStart,
                onChanged: (v) {
                  setState(() => _rootBootStart = v);
                  widget.onRootBootStartChanged(v);
                },
              ),
          ]),
          const SizedBox(height: 20),
          section('代理', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.apps_outlined),
              title: const Text('分应用代理'),
              subtitle: Text(
                !_splitEnabled
                    ? '未启用，所有应用都走 VPN'
                    : _splitAllow
                        ? '仅 ${_bypassPkgs.length} 个应用走 VPN'
                        : '${_bypassPkgs.length} 个应用绕过 VPN',
                style: TextStyle(color: muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _BypassAppsPage(
                      initialPkgs: _bypassPkgs,
                      initialEnabled: _splitEnabled,
                      initialAllow: _splitAllow,
                      onSave: (enabled, allow, pkgs) {
                        setState(() {
                          _splitEnabled = enabled;
                          _splitAllow = allow;
                          _bypassPkgs = pkgs;
                        });
                        widget.onBypassSettingsChanged(enabled, allow, pkgs);
                      },
                    ),
                  ),
                );
              },
            ),
          ]),
          const SizedBox(height: 20),
          section('路由', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.public_outlined),
              title: const Text('全局模式'),
              subtitle:
                  Text('所有流量都走代理', style: TextStyle(color: muted)),
              trailing: _outMode == 1
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () {
                setState(() => _outMode = 1);
                widget.onOutModeChanged(1);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alt_route),
              title: const Text('规则模式（分流）'),
              subtitle: Text('v2ray 原版绕过大陆：国内域名与 IP 直连，其余走代理',
                  style: TextStyle(color: muted)),
              trailing: _outMode == 0
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () {
                setState(() => _outMode = 0);
                widget.onOutModeChanged(0);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shortcut),
              title: const Text('直连模式'),
              subtitle: Text('所有流量不走代理、直接连接',
                  style: TextStyle(color: muted)),
              trailing: _outMode == 2
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () {
                setState(() => _outMode = 2);
                widget.onOutModeChanged(2);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.library_books_outlined),
              title: const Text('分流规则库'),
              subtitle: Text(
                widget.geoReady
                    ? '已内置于安装包，点按可刷新'
                    : '内置于安装包（开启规则模式时自动释放）',
                style: TextStyle(color: muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onUpdateGeo,
            ),
          ]),
          const SizedBox(height: 20),
          section('连接', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('新订阅默认更新周期'),
              subtitle: Text(
                '每份订阅的自动更新开关、周期、更新网络和节点过滤在配置页点订阅的「编辑」设置；到期后应用在前台和后台都会自动更新',
                style: TextStyle(color: muted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final h in const [6, 12, 24, 48, 72])
                    ChoiceChip(
                      label: Text('$h 小时'),
                      selected: _autoIntervalHours == h,
                      onSelected: (_) {
                        setState(() => _autoIntervalHours = h);
                        widget.onAutoIntervalChanged(h);
                      },
                    ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          section('高级', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.language_outlined),
              title: const Text('IPv6'),
              subtitle: Text(
                _runMode == 'ebpf'
                    ? 'eBPF 模式手动开关，下次启动时生效；开：桥尝试接管 v6 走节点（root 数据面 v6 普遍不稳，节点无 v6 出口则不通）；关：看下方「系统级禁用 IPv6」开关，开则禁用、关则原生直连'
                    : 'VPN 模式手动开关，下次启动时生效；开：v6 进隧道走节点（节点无 v6 出口则失败回落 v4）；关：v6 在隧道口直接丢弃，不直连泄漏',
                style: TextStyle(color: muted),
              ),
              value: _ipv6Enabled,
              onChanged: (v) {
                setState(() => _ipv6Enabled = v);
                widget.onIpv6Changed(v);
              },
            ),
            if (_runMode == 'ebpf')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.block_outlined),
                title: const Text('系统级禁用 IPv6'),
                subtitle: Text(
                  _ipv6Disabler
                      ? '开（AS 式独立开关）：上方 IPv6 关闭时，会话期间逐网卡禁用系统 v6，应用回落 v4、不直连泄漏；下次启动时生效'
                      : '关：上方 IPv6 关闭时桥不接管、系统也不禁，v6 走运营商原生直连（AS 的默认行为）；下次启动时生效',
                  style: TextStyle(color: muted),
                ),
                value: _ipv6Disabler,
                onChanged: (v) {
                  setState(() => _ipv6Disabler = v);
                  widget.onIpv6DisablerChanged(v);
                },
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.receipt_long_outlined),
              title: const Text('核心日志'),
              subtitle: Text(
                _logEnabled
                    ? '开启：核心日志写入「工具 → 日志」'
                    : '关闭：核心不再写日志（省电、少写盘），排障时再开；下次启动核心时生效',
                style: TextStyle(color: muted),
              ),
              value: _logEnabled,
              onChanged: (v) {
                setState(() => _logEnabled = v);
                widget.onLogEnabledChanged(v);
              },
            ),
          ]),
          const SizedBox(height: 20),
          section('通知', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('常驻通知信息'),
              subtitle: Text('在 VPN 常驻通知里实时显示当前节点、延迟与上下行速度',
                  style: TextStyle(color: muted)),
              value: _notifyOnStart,
              onChanged: (v) {
                setState(() => _notifyOnStart = v);
                widget.onNotifyOnStartChanged(v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.update),
              title: const Text('订阅自动更新通知'),
              subtitle: Text('订阅自动更新成功后推送通知',
                  style: TextStyle(color: muted)),
              value: _notifySubUpdate,
              onChanged: (v) {
                setState(() => _notifySubUpdate = v);
                widget.onNotifySubUpdateChanged(v);
              },
            ),
          ]),
          const SizedBox(height: 20),
          section('系统', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('电池优化'),
              subtitle: Text(
                widget.batteryIgnored
                    ? '已豁免，后台运行不受限'
                    : '未豁免，切后台久了可能被系统杀掉',
                style: TextStyle(color: muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenBatterySettings,
            ),
          ]),
          const SizedBox(height: 20),
          section('内核', [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Xray（试用中）'),
              trailing: Icon(Icons.check, color: _accent),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'sing-box（待接入）',
                style: TextStyle(color: muted),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          section('备份', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出备份'),
              subtitle: Text('全部订阅和设置存成一个文件',
                  style: TextStyle(color: muted)),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onExportBackup,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('恢复备份'),
              subtitle: Text('从备份文件恢复，会覆盖现有订阅和设置',
                  style: TextStyle(color: muted)),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onImportBackup,
            ),
          ]),
          const SizedBox(height: 28),
          Center(
            child: Text(
              'FlBox 0.71.2-beta3 · app.flbox · Xray 内核',
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class ProxiesPage extends StatefulWidget {
  const ProxiesPage({
    super.key,
    required this.profile,
    required this.profileName,
    required this.selectedNode,
    required this.onSelect,
    required this.delays,
    required this.testing,
    required this.onTestAll,
    required this.favorites,
    required this.onToggleFav,
    required this.onPickFastest,
    required this.onEditNode,
    required this.onAddNode,
    required this.onImportLink,
  });

  final XrayProfile? profile;
  final String? profileName;
  final String? selectedNode;
  final ValueChanged<String> onSelect;
  final Map<String, int?> delays;
  final bool testing;
  final VoidCallback? onTestAll;
  final Set<String> favorites;
  final ValueChanged<String> onToggleFav;
  final VoidCallback? onPickFastest;
  final ValueChanged<String> onEditNode;
  final VoidCallback onAddNode;
  final VoidCallback onImportLink;

  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage> {
  String _query = '';
  int _sortMode = 0; // 0 智能（测速优先）· 1 按延迟 · 2 按名称
  bool _sortOpen = false; // 排序选项行是否展开（不用弹出菜单：模态层会挡住滑动）

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final profile = widget.profile;
    if (profile == null) {
      return _PageFrame(
        title: '代理',
        child: Text('还没有配置，先到「配置」页导入。', style: TextStyle(color: muted)),
      );
    }
    // Favorites first in smart order; then tested nodes (fastest
    // first), untested, timeouts; profile order breaks ties.
    int rank(XrayNode n) {
      final base = !widget.delays.containsKey(n.name)
          ? 1
          : (widget.delays[n.name] == null ? 2 : 0);
      return widget.favorites.contains(n.name) ? base - 3 : base;
    }

    final indexed = <(int, XrayNode)>[
      for (var i = 0; i < profile.nodes.length; i++) (i, profile.nodes[i]),
    ];
    if (_sortMode == 2) {
      indexed.sort((a, b) => a.$2.name.compareTo(b.$2.name));
    } else if (_sortMode == 1) {
      indexed.sort((a, b) {
        final da = widget.delays[a.$2.name];
        final db = widget.delays[b.$2.name];
        if (da == null && db == null) return a.$1.compareTo(b.$1);
        if (da == null) return 1;
        if (db == null) return -1;
        final byDelay = da.compareTo(db);
        return byDelay != 0 ? byDelay : a.$1.compareTo(b.$1);
      });
    } else {
      indexed.sort((a, b) {
        final byRank = rank(a.$2).compareTo(rank(b.$2));
        if (byRank != 0) return byRank;
        if (rank(a.$2) == 0) {
          final byDelay =
              widget.delays[a.$2.name]!.compareTo(widget.delays[b.$2.name]!);
          if (byDelay != 0) return byDelay;
        }
        return a.$1.compareTo(b.$1);
      });
    }
    final nodes = <XrayNode>[
      for (final e in indexed)
        if (_query.isEmpty ||
            e.$2.name.toLowerCase().contains(_query.toLowerCase()))
          e.$2,
    ];
    // Only the active subscription's nodes are shown
    // here; switching subscriptions lives on the
    // profiles page.
    return _PageFrame(
      title: '代理',
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${profile.nodes.length} 个节点',
                        style: TextStyle(color: muted),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.link),
                      tooltip: '导入单节点链接',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onImportLink,
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: '手动添加节点',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onAddNode,
                    ),
                    FilledButton.tonal(
                      onPressed: widget.testing ? null : widget.onTestAll,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(widget.testing
                          ? '测速中 ${widget.delays.length}/'
                              '${profile.nodes.where((n) => !isInfoNode(n.name)).length}'
                          : '全部测速'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.bolt),
                      tooltip: '测速并选最快',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.testing ? null : widget.onPickFastest,
                    ),
                    IconButton(
                      icon: const Icon(Icons.sort),
                      tooltip: '排序',
                      color: _sortOpen
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      onPressed: () =>
                          setState(() => _sortOpen = !_sortOpen),
                    ),
                  ],
                ),
                // Inline sort options, not a popup menu: a modal popup
                // layer swallows all gestures until an item is tapped, so
                // the grid could not be scrolled with the menu open. The
                // chips live in the page itself, scrolling always works.
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.topCenter,
                  child: !_sortOpen
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              for (var i = 0; i < 3; i++) ...[
                                if (i > 0) const SizedBox(width: 8),
                                ChoiceChip(
                                  label: Text(const [
                                    '智能排序',
                                    '按延迟',
                                    '按名称'
                                  ][i]),
                                  selected: _sortMode == i,
                                  onSelected: (_) => setState(() {
                                    _sortMode = i;
                                    _sortOpen = false;
                                  }),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索节点',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          // Lazy sliver grid: with 30+ nodes an eager list
          // built every tile on every rebuild (search
          // keystrokes, delay updates), which visibly hitched.
          SliverGrid.builder(
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: 104,
            ),
            itemCount: nodes.length,
            itemBuilder: (context, i) {
              final node = nodes[i];
              return _NodeTile(
                node: node,
                info: isInfoNode(node.name),
                muted: muted,
                favorite: widget.favorites.contains(node.name),
                hasDelay: widget.delays.containsKey(node.name),
                delay: widget.delays[node.name],
                delayColor: _delayColor(widget.delays[node.name]),
                selected: node.name == widget.selectedNode,
                onTap: () => widget.onSelect(node.name),
                onFav: () => widget.onToggleFav(node.name),
                onEdit: () => widget.onEditNode(node.name),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 104)),
        ],
      ),
    );
  }
}

/// One node card in the proxies grid (FlClash-style): name on top,
/// type and latency along the bottom, selected card tinted and
/// outlined with the accent color.
class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.node,
    required this.info,
    required this.muted,
    required this.favorite,
    required this.hasDelay,
    required this.delay,
    required this.delayColor,
    required this.selected,
    required this.onTap,
    required this.onFav,
    required this.onEdit,
  });

  final XrayNode node;
  final bool info;
  final Color muted;
  final bool favorite;
  final bool hasDelay;
  final int? delay;
  final Color delayColor;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFav;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? _accent.withValues(alpha: 0.12)
          : _cardColor(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: selected
                ? Border.all(color: _accent, width: 1.5)
                : Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.05),
                  ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        node.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, height: 1.3),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    tooltip: '编辑',
                    color: muted,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    icon: Icon(
                      favorite ? Icons.star : Icons.star_border,
                      color: favorite ? _accent : muted,
                      size: 18,
                    ),
                    tooltip: '收藏',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: onFav,
                  ),
                ],
              ),
              const Spacer(),
              if (info)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: muted.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '订阅信息',
                      style: TextStyle(color: muted, fontSize: 11),
                    ),
                  ),
                )
              else
                Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: muted.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      node.type,
                      style: TextStyle(color: muted, fontSize: 11),
                    ),
                  ),
                  const Spacer(),
                  if (hasDelay)
                    _delayPill(delay, delayColor)
                  else if (selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(Icons.check_circle,
                          color: _accent, size: 16),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FieldKind { text, number, toggle, choice }

class _FieldSpec {
  const _FieldSpec(this.key, this.label,
      {this.kind = _FieldKind.text, this.options});

  final String key;
  final String label;
  final _FieldKind kind;
  final List<String>? options;
}

List<_FieldSpec> _specsFor(String type) {
  const network = _FieldSpec(
    'network',
    '传输方式',
    kind: _FieldKind.choice,
    options: ['tcp', 'ws', 'grpc'],
  );
  switch (type) {
    case 'vless':
      return [
        const _FieldSpec('uuid', 'UUID'),
        const _FieldSpec('flow', 'Flow（可空）'),
        network,
        const _FieldSpec('tls', 'TLS', kind: _FieldKind.toggle),
        const _FieldSpec('servername', 'SNI'),
        const _FieldSpec('client-fingerprint', '指纹（可空）'),
        const _FieldSpec('reality-opts.public-key', 'REALITY 公钥'),
        const _FieldSpec('reality-opts.short-id', 'REALITY Short ID'),
        const _FieldSpec('ws-opts.path', 'WS 路径'),
        const _FieldSpec('ws-opts.headers.Host', 'WS Host'),
        const _FieldSpec('skip-cert-verify', '跳过证书验证',
            kind: _FieldKind.toggle),
        const _FieldSpec('pinned-cert-sha256', '证书指纹 SHA-256（可空）'),
      ];
    case 'vmess':
      return [
        const _FieldSpec('uuid', 'UUID'),
        const _FieldSpec('alterId', 'Alter ID', kind: _FieldKind.number),
        const _FieldSpec(
          'cipher',
          '加密方式',
          kind: _FieldKind.choice,
          options: ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'none'],
        ),
        network,
        const _FieldSpec('tls', 'TLS', kind: _FieldKind.toggle),
        const _FieldSpec('servername', 'SNI'),
        const _FieldSpec('ws-opts.path', 'WS 路径'),
        const _FieldSpec('ws-opts.headers.Host', 'WS Host'),
        const _FieldSpec('skip-cert-verify', '跳过证书验证',
            kind: _FieldKind.toggle),
      ];
    case 'trojan':
      return [
        const _FieldSpec('password', '密码'),
        network,
        const _FieldSpec('servername', 'SNI'),
        const _FieldSpec('skip-cert-verify', '跳过证书验证',
            kind: _FieldKind.toggle),
        const _FieldSpec('pinned-cert-sha256', '证书指纹 SHA-256（可空）'),
      ];
    case 'ss':
      return [
        const _FieldSpec(
          'cipher',
          '加密方式',
          kind: _FieldKind.choice,
          options: [
            'aes-256-gcm',
            'aes-128-gcm',
            'chacha20-ietf-poly1305',
            'xchacha20-ietf-poly1305',
            '2022-blake3-aes-128-gcm',
            '2022-blake3-aes-256-gcm',
            '2022-blake3-chacha20-poly1305',
          ],
        ),
        const _FieldSpec('password', '密码'),
      ];
    case 'hysteria2':
      return [
        const _FieldSpec('password', '密码（auth）'),
        const _FieldSpec(
          'obfs',
          '混淆',
          kind: _FieldKind.choice,
          options: ['', 'salamander'],
        ),
        const _FieldSpec('obfs-password', '混淆密码'),
        const _FieldSpec('sni', 'SNI'),
        const _FieldSpec('up', '带宽上行（如 50 或 50 Mbps）'),
        const _FieldSpec('down', '带宽下行（如 200 或 200 Mbps）'),
        const _FieldSpec('skip-cert-verify', '跳过证书验证',
            kind: _FieldKind.toggle),
        const _FieldSpec('pinned-cert-sha256', '证书指纹 SHA-256（可空）'),
      ];
    case 'wireguard':
      return [
        const _FieldSpec('private-key', '私钥'),
        const _FieldSpec('public-key', '对端公钥'),
        const _FieldSpec('ip', '内网 IP（如 10.0.0.2）'),
        const _FieldSpec('ipv6', '内网 IPv6（可空）'),
        const _FieldSpec('pre-shared-key', '预共享密钥（可空）'),
        const _FieldSpec('mtu', 'MTU（可空）', kind: _FieldKind.number),
        const _FieldSpec('allowed-ips', 'Allowed IPs（逗号分隔，可空）'),
        const _FieldSpec('reserved', 'Reserved（逗号分隔 3 个数，可空）'),
      ];
  }
  return const [];
}

/// The per-protocol node form (the v2rayNG-style editor): common
/// fields on top, protocol fields below. Saving returns the full
/// entry map (the original entry overlaid with the form, so fields
/// the form does not know survive an edit); the Go side splices it
/// into the profile YAML.
class _NodeEditPage extends StatefulWidget {
  const _NodeEditPage({
    required this.isNew,
    required this.detail,
    required this.siblingNames,
    required this.fromSubscription,
    this.onShare,
  });

  final bool isNew;
  final Map<String, dynamic> detail;
  final Set<String> siblingNames;
  final bool fromSubscription;
  final VoidCallback? onShare;

  @override
  State<_NodeEditPage> createState() => _NodeEditPageState();
}

class _NodeEditPageState extends State<_NodeEditPage> {
  static const _types = [
    'vless',
    'vmess',
    'trojan',
    'ss',
    'hysteria2',
    'wireguard',
  ];

  late String _type;
  late final TextEditingController _nameCtl;
  late final TextEditingController _serverCtl;
  late final TextEditingController _portCtl;
  final _text = <String, TextEditingController>{};
  final _flags = <String, bool>{};
  final _choices = <String, String>{};

  dynamic _dig(Map<String, dynamic> m, String dotted) {
    dynamic cur = m;
    for (final part in dotted.split('.')) {
      if (cur is Map && cur.containsKey(part)) {
        cur = cur[part];
      } else {
        return null;
      }
    }
    return cur;
  }

  String _stringify(dynamic v) {
    if (v == null) return '';
    if (v is List) return v.join(',');
    return v.toString();
  }

  void _initSpecs() {
    for (final c in _text.values) {
      c.dispose();
    }
    _text.clear();
    _flags.clear();
    _choices.clear();
    for (final spec in _specsFor(_type)) {
      final v = _dig(widget.detail, spec.key);
      switch (spec.kind) {
        case _FieldKind.toggle:
          _flags[spec.key] = v == true;
        case _FieldKind.choice:
          final s = _stringify(v);
          _choices[spec.key] =
              spec.options!.contains(s) ? s : spec.options!.first;
        default:
          _text[spec.key] = TextEditingController(text: _stringify(v));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _type = _stringify(widget.detail['type']);
    if (!_types.contains(_type)) _type = 'vless';
    _nameCtl = TextEditingController(text: _stringify(widget.detail['name']));
    _serverCtl =
        TextEditingController(text: _stringify(widget.detail['server']));
    _portCtl = TextEditingController(text: _stringify(widget.detail['port']));
    _initSpecs();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _serverCtl.dispose();
    _portCtl.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  dynamic _deepCopy(dynamic v) {
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries) e.key.toString(): _deepCopy(e.value),
      };
    }
    if (v is List) return [for (final e in v) _deepCopy(e)];
    return v;
  }

  void _setDotted(Map<String, dynamic> entry, String dotted, Object? value) {
    final parts = dotted.split('.');
    var cur = entry;
    for (var i = 0; i < parts.length - 1; i++) {
      final next = cur[parts[i]];
      if (next is Map<String, dynamic>) {
        cur = next;
      } else {
        final fresh = <String, dynamic>{};
        cur[parts[i]] = fresh;
        cur = fresh;
      }
    }
    if (value == null) {
      cur.remove(parts.last);
    } else {
      cur[parts.last] = value;
    }
  }

  void _pruneEmpties(Map<String, dynamic> entry, String key) {
    final v = entry[key];
    if (v is Map<String, dynamic>) {
      v.removeWhere((_, sub) => sub is Map && sub.isEmpty);
      if (v.isEmpty) entry.remove(key);
    }
  }

  String _textOf(String key) => _text[key]?.text.trim() ?? '';

  void _save() {
    final name = _nameCtl.text.trim();
    final server = _serverCtl.text.trim();
    final port = int.tryParse(_portCtl.text.trim());
    String? error;
    if (name.isEmpty) {
      error = '名称不能为空';
    } else if (name != widget.detail['name'] &&
        widget.siblingNames.contains(name)) {
      error = '已存在同名节点';
    } else if (server.isEmpty) {
      error = '地址不能为空';
    } else if (port == null || port < 1 || port > 65535) {
      error = '端口不合法';
    } else if ((_type == 'vless' || _type == 'vmess') &&
        _textOf('uuid').isEmpty) {
      error = 'UUID 不能为空';
    } else if ((_type == 'trojan' ||
            _type == 'ss' ||
            _type == 'hysteria2') &&
        _textOf('password').isEmpty) {
      error = '密码不能为空';
    } else if (_type == 'wireguard' &&
        (_textOf('private-key').isEmpty ||
            _textOf('public-key').isEmpty ||
            _textOf('ip').isEmpty)) {
      error = 'WireGuard 需要私钥、对端公钥和内网 IP';
    }
    if (error != null) {
      _showToast(context, error);
      return;
    }
    final entry = _deepCopy(widget.detail) as Map<String, dynamic>;
    entry['name'] = name;
    entry['type'] = _type;
    entry['server'] = server;
    entry['port'] = port;
    for (final spec in _specsFor(_type)) {
      switch (spec.kind) {
        case _FieldKind.toggle:
          _setDotted(entry, spec.key, _flags[spec.key] ?? false);
        case _FieldKind.choice:
          final v = _choices[spec.key] ?? '';
          _setDotted(entry, spec.key, v.isEmpty ? null : v);
        case _FieldKind.number:
          final raw = _textOf(spec.key);
          _setDotted(entry, spec.key, raw.isEmpty ? null : int.tryParse(raw));
        case _FieldKind.text:
          final raw = _textOf(spec.key);
          if (raw.isEmpty) {
            _setDotted(entry, spec.key, null);
          } else if (spec.key == 'allowed-ips') {
            _setDotted(entry, spec.key,
                [for (final s in raw.split(',')) s.trim()]);
          } else if (spec.key == 'reserved') {
            _setDotted(entry, spec.key, [
              for (final s in raw.split(',')) int.tryParse(s.trim()) ?? 0,
            ]);
          } else if (spec.key == 'up' || spec.key == 'down') {
            _setDotted(entry, spec.key, num.tryParse(raw) ?? raw);
          } else {
            _setDotted(entry, spec.key, raw);
          }
      }
    }
    _pruneEmpties(entry, 'reality-opts');
    _pruneEmpties(entry, 'ws-opts');
    Navigator.of(context).pop({'entry': entry});
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text('删除节点「${widget.detail['name']}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop({'delete': true});
    }
  }

  Widget _field(_FieldSpec spec) {
    switch (spec.kind) {
      case _FieldKind.toggle:
        return SwitchListTile(
          title: Text(spec.label),
          contentPadding: EdgeInsets.zero,
          value: _flags[spec.key] ?? false,
          onChanged: (v) => setState(() => _flags[spec.key] = v),
        );
      case _FieldKind.choice:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: spec.label,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButton<String>(
              value: _choices[spec.key],
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final o in spec.options!)
                  DropdownMenuItem(
                    value: o,
                    child: Text(o.isEmpty ? '无' : o),
                  ),
              ],
              onChanged: (v) =>
                  setState(() => _choices[spec.key] = v ?? ''),
            ),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: _text[spec.key],
            keyboardType: spec.kind == _FieldKind.number
                ? TextInputType.number
                : TextInputType.text,
            decoration: InputDecoration(
              labelText: spec.label,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '添加节点' : '编辑节点'),
        actions: [
          if (widget.onShare != null)
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: '分享链接',
              onPressed: widget.onShare,
            ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.fromSubscription)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '该节点来自订阅：订阅更新后，对它的修改会被覆盖。',
                style: TextStyle(color: muted),
              ),
            ),
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(
              labelText: '名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          if (widget.isNew)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final t in _types)
                    ChoiceChip(
                      label: Text(t),
                      selected: _type == t,
                      onSelected: (_) => setState(() {
                        _type = t;
                        _initSpecs();
                      }),
                    ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text('协议：$_type', style: TextStyle(color: muted)),
            ),
          TextField(
            controller: _serverCtl,
            decoration: const InputDecoration(
              labelText: '地址',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _portCtl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          for (final spec in _specsFor(_type)) _field(spec),
          if (!widget.isNew) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _delete,
              child: const Text(
                '删除节点',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Subscription settings form: name/link, the per-subscription
/// auto-update opt-in and period, the update route (direct or via
/// the running core), and the keep/drop name filters applied to
/// every refresh.
class _SubEditPage extends StatefulWidget {
  const _SubEditPage({required this.sub});

  final SubProfile sub;

  @override
  State<_SubEditPage> createState() => _SubEditPageState();
}

class _SubEditPageState extends State<_SubEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _urlCtl;
  late final TextEditingController _uaCtl;
  late final TextEditingController _keepCtl;
  late final TextEditingController _dropCtl;
  late bool _autoUpdate;
  late int _interval;
  late bool _viaProxy;

  @override
  void initState() {
    super.initState();
    final s = widget.sub;
    _nameCtl = TextEditingController(text: s.name);
    _urlCtl = TextEditingController(text: s.url ?? '');
    _uaCtl = TextEditingController(text: s.ua);
    _keepCtl = TextEditingController(text: s.keepRegex);
    _dropCtl = TextEditingController(text: s.dropRegex);
    _autoUpdate = s.autoUpdate;
    _interval = s.autoIntervalHours;
    _viaProxy = s.updateViaProxy;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _urlCtl.dispose();
    _uaCtl.dispose();
    _keepCtl.dispose();
    _dropCtl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtl.text.trim();
    final url = _urlCtl.text.trim();
    final keep = _keepCtl.text.trim();
    final drop = _dropCtl.text.trim();
    String? error;
    if (name.isEmpty) {
      error = '名称不能为空';
    } else if (widget.sub.url != null &&
        (url.isEmpty || Uri.tryParse(url)?.host.isEmpty != false)) {
      error = '订阅链接不合法';
    } else {
      for (final pattern in [keep, drop]) {
        if (pattern.isEmpty) continue;
        try {
          RegExp(pattern);
        } catch (_) {
          error = '正则表达式不合法：$pattern';
          break;
        }
      }
    }
    if (error != null) {
      _showToast(context, error);
      return;
    }
    Navigator.of(context).pop({
      'name': name,
      'url': widget.sub.url == null ? null : url,
      'autoUpdate': _autoUpdate,
      'interval': _interval,
      'viaProxy': _viaProxy,
      'keep': keep,
      'drop': drop,
      'ua': _uaCtl.text.trim().isEmpty ? _defaultUa : _uaCtl.text.trim(),
    });
  }

  Widget _textField(
    TextEditingController ctl,
    String label,
    Color fill,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctl,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: fill,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _accent, width: 1.2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final hasUrl = widget.sub.url != null;
    final fill =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05);
    return Container(
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '编辑订阅',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              _textField(_nameCtl, '分组名称', fill),
              if (hasUrl) _textField(_urlCtl, '订阅地址', fill),
              if (hasUrl) _textField(_uaCtl, 'User-Agent', fill),
              if (hasUrl) ...[
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [
                      'ClashMeta/1.0',
                      'v2rayNG/2.3.10',
                      'sing-box/1.14.4',
                    ])
                      ActionChip(
                        label: Text(preset),
                        onPressed: () =>
                            setState(() => _uaCtl.text = preset),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                SwitchListTile(
                  title: const Text('自动更新'),
                  contentPadding: EdgeInsets.zero,
                  value: _autoUpdate,
                  onChanged: (v) => setState(() => _autoUpdate = v),
                ),
                const SizedBox(height: 6),
                Text('自动更新周期', style: TextStyle(color: muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final h in const [6, 12, 24, 48, 72])
                      ChoiceChip(
                        label: Text('$h 小时'),
                        selected: _interval == h,
                        onSelected: (_) => setState(() => _interval = h),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('更新网络', style: TextStyle(color: muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('直连'),
                      selected: !_viaProxy,
                      onSelected: (_) =>
                          setState(() => _viaProxy = false),
                    ),
                    ChoiceChip(
                      label: const Text('经当前代理'),
                      selected: _viaProxy,
                      onSelected: (_) => setState(() => _viaProxy = true),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _textField(_keepCtl, '仅保留（正则，可选）', fill),
                _textField(_dropCtl, '排除（正则，可选）', fill),
                Text(
                  '过滤按节点名匹配，在每次更新时应用；手动添加的节点在「手动节点」里，不受订阅更新影响。',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ] else
                Text(
                  '本地配置没有链接，不参与自动更新。',
                  style: TextStyle(color: muted),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _save,
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({
    super.key,
    required this.subs,
    required this.activeSubId,
    required this.activeSkipped,
    required this.onImport,
    required this.onImportUrl,
    required this.onSwitch,
    required this.onUpdate,
    required this.onDelete,
    required this.onEditSub,
    required this.onImportLink,
    required this.onToggleEnabled,
    required this.onUpdateAll,
  });

  final List<SubProfile> subs;
  final String? activeSubId;
  final List<SkippedNode> activeSkipped;
  final VoidCallback onImport;
  final VoidCallback onImportUrl;
  final ValueChanged<SubProfile> onSwitch;
  final ValueChanged<SubProfile> onUpdate;
  final ValueChanged<SubProfile> onDelete;
  final ValueChanged<SubProfile> onEditSub;
  final VoidCallback onImportLink;
  final void Function(SubProfile, bool) onToggleEnabled;
  final VoidCallback onUpdateAll;

  String _updatedLabel(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '更新于 ${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _confirmDelete(BuildContext context, SubProfile sub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('删除「${sub.name}」？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) onDelete(sub);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '配置',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新全部订阅',
            onPressed: onUpdateAll,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '从订阅链接导入',
            onPressed: onImportUrl,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subs.isEmpty)
              Text('暂无订阅。从文件导入，或粘贴订阅链接拉取；可以存多份随时切换。',
                  style: TextStyle(color: muted)),
            for (final sub in subs) ...[
              _subCard(context, sub, muted),
              const SizedBox(height: 12),
            ],
            if (activeSkipped.isNotEmpty) ...[
              const SizedBox(height: 4),
              for (final s in activeSkipped)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '跳过：${s.name}（${s.type}）${s.reason}',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 12),
            Container(
              decoration: _cardDecoration(context),
              child: Column(
                children: [
                  ListTile(
                    leading:
                        const Icon(Icons.folder_open, color: _accent),
                    title: const Text('从文件导入'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onImport,
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.cloud_download_outlined,
                        color: _accent),
                    title: const Text('从订阅链接导入'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onImportUrl,
                  ),
                  const Divider(height: 1, indent: 56),
                  ListTile(
                    leading: const Icon(Icons.link, color: _accent),
                    title: const Text('从单节点链接导入'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onImportLink,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 104),
          ],
        ),
      ),
    );
  }

  Widget _subCard(BuildContext context, SubProfile sub, Color muted) {
    final active = sub.id == activeSubId;
    final meta = StringBuffer()
      ..write('${sub.nodeCount} 个节点 · ')
      ..write(sub.url != null ? '订阅链接' : '本地文件');
    final updated = _updatedLabel(sub.updatedAtMs);
    if (updated.isNotEmpty) meta.write(' · $updated');
    // The auto-update switch itself lives in the editor (the
    // card face only reports the state), per the user's call.
    if (sub.url != null) {
      meta.write(
        sub.autoUpdate
            ? ' · 自动更新 ${sub.autoIntervalHours}h'
            : ' · 自动更新关',
      );
    }
    double? trafficRatio;
    if (sub.subInfo != null) {
      final m = RegExp(r'已用 ([\d.]+) / 共 ([\d.]+) GB')
          .firstMatch(sub.subInfo!);
      if (m != null) {
        final used = double.tryParse(m.group(1)!);
        final total = double.tryParse(m.group(2)!);
        if (used != null && total != null && total > 0) {
          trafficRatio = (used / total).clamp(0.0, 1.0).toDouble();
        }
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: active
            ? _accent.withValues(alpha: 0.07)
            : _cardColor(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active
              ? _accent.withValues(alpha: 0.55)
              : Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.05),
          width: active ? 1.2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: (!active && sub.enabled) ? () => onSwitch(sub) : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _iconTile(
                sub.id == 'manual'
                    ? Icons.edit_note_outlined
                    : sub.url != null
                        ? Icons.cloud_outlined
                        : Icons.description_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sub.name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (active)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '使用中',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        const SizedBox(width: 4),
                        Switch(
                          value: sub.enabled,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (v) => onToggleEnabled(sub, v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta.toString(),
                      style: TextStyle(color: muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (trafficRatio != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: trafficRatio,
                minHeight: 5,
                backgroundColor: muted.withValues(alpha: 0.15),
                color: _accent,
              ),
            ),
          ],
          if (sub.subInfo != null) ...[
            const SizedBox(height: 8),
            Text(
              sub.subInfo!,
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              const Spacer(),
              if (sub.url != null)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '更新',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onUpdate(sub),
                ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                onPressed: () => onEditSub(sub),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除',
                color: Colors.redAccent,
                visualDensity: VisualDensity.compact,
                onPressed: () => _confirmDelete(context, sub),
              ),
            ],
          ),
        ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The tools tab (0.69): the reference layout's fourth
/// tab. It gathers the entry points that used to be a
/// tab of their own (logs) or a dashboard gear
/// (settings), in the reference client's grouping: a
/// function card, then the rest.
class _ToolsPage extends StatelessWidget {
  const _ToolsPage({
    required this.onOpenLogs,
    required this.onOpenSettings,
    required this.geoReady,
    required this.onUpdateGeo,
  });

  final VoidCallback onOpenLogs;
  final VoidCallback onOpenSettings;
  final bool geoReady;
  final VoidCallback onUpdateGeo;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    Widget group(List<Widget> rows) {
      return Container(
        decoration: BoxDecoration(
          color: _cardColor(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.05),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(children: rows),
      );
    }

    Widget entry({
      required IconData icon,
      required String title,
      required String subtitle,
      VoidCallback? onTap,
    }) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: TextStyle(color: muted)),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      );
    }

    return _PageFrame(
      title: '工具',
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            group([
              entry(
                icon: Icons.terminal,
                title: '日志',
                subtitle: '核心与守护进程日志、内核自检',
                onTap: onOpenLogs,
              ),
              entry(
                icon: Icons.settings_outlined,
                title: '设置',
                subtitle: '运行模式、路由、连接、高级与备份恢复',
                onTap: onOpenSettings,
              ),
              entry(
                icon: Icons.library_books_outlined,
                title: '分流规则库',
                subtitle: geoReady ? '已内置于安装包，点按可刷新' : '开启规则模式时自动释放',
                onTap: onUpdateGeo,
              ),
            ]),
            const SizedBox(height: 20),
            Text('其他', style: TextStyle(color: muted, fontSize: 13)),
            const SizedBox(height: 8),
            group([
              entry(
                icon: Icons.info_outline,
                title: '关于 FlBox',
                subtitle: 'app.flbox · Xray 内核',
              ),
            ]),
            const SizedBox(height: 104),
          ],
        ),
      ),
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, this.ebpfMode = false});

  final bool ebpfMode;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _names = ['核心', '守护·本次', '守护·上次'];
  static const _files = [
    'xray-error.log',
    'root-daemon.log',
    'root-daemon.prev.log',
  ];

  int _source = 0;
  List<String> _lines = const [];
  String _meta = '';
  String? _status;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      var newest = -1;
      var newestTime = DateTime.fromMillisecondsSinceEpoch(0);
      for (var i = 0; i < _files.length; i++) {
        final f = File('${docs.path}/${_files[i]}');
        if (await f.exists()) {
          final t = (await f.stat()).modified;
          if (t.isAfter(newestTime)) {
            newestTime = t;
            newest = i;
          }
        }
      }
      if (newest >= 0 && mounted) setState(() => _source = newest);
    } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    var meta = '';
    var lines = const <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/${_files[_source]}');
      if (await file.exists()) {
        final size = await file.length();
        meta = '${_names[_source]}日志 · $size 字节';
        // Tail only: a whole-file decode of a multi-MB log
        // is slow, and one bad byte blanks the page.
        final raf = await file.open();
        try {
          const chunk = 96 * 1024;
          final start = size > chunk ? size - chunk : 0;
          await raf.setPosition(start);
          final bytes = await raf.read(chunk);
          var text = utf8.decode(bytes, allowMalformed: true);
          if (start > 0) {
            final nl = text.indexOf('\n');
            if (nl >= 0) text = text.substring(nl + 1);
          }
          final all = text.split('\n');
          lines = all.length > 200 ? all.sublist(all.length - 200) : all;
        } finally {
          await raf.close();
        }
      } else {
        meta = '${_names[_source]}日志尚不存在';
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _meta = meta;
        _lines = lines;
        _loading = false;
      });
    }
  }

  Future<void> _clear() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/${_files[_source]}');
      // Truncate, never delete: the writer keeps the file
      // open, and unlinking would swallow later lines.
      if (await file.exists()) await file.writeAsString('');
      setState(() {
        _meta = '${_names[_source]}日志已清空（截断）';
        _lines = const [];
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Scaffold(
      appBar: AppBar(title: const Text('日志')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<int>(
              segments: [
                for (var i = 0; i < _names.length; i++)
                  ButtonSegment(value: i, label: Text(_names[i])),
              ],
              selected: {_source},
              onSelectionChanged: (s) {
                setState(() => _source = s.first);
                _load();
              },
            ),
            if (widget.ebpfMode && _source == 0) ...[
              const SizedBox(height: 10),
              Text(
                'eBPF 模式下核心在守护进程中运行：「核心」是 VPN 模式的日志，当前会话请看「守护·本次」',
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: () {
                    try {
                      setState(() => _status = CoreBridge().xrayStatus());
                    } catch (e) {
                      setState(() => _status = '自检失败：$e');
                    }
                  },
                  child: const Text('内核自检'),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _loading ? null : _load,
                  child: Text(_loading ? '刷新中…' : '刷新日志'),
                ),
                const Spacer(),
                TextButton(onPressed: _clear, child: const Text('清空')),
              ],
            ),
            const SizedBox(height: 8),
            Text(_meta, style: TextStyle(color: muted, fontSize: 12)),
            if (_status != null) ...[
              const SizedBox(height: 10),
              Text(_status!),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: _lines.isEmpty
                  ? Text(
                      _source == 0
                          ? '暂无日志。启动一次内核后，Xray 的运行日志会写到这里。'
                          : '暂无守护日志。用 Root 模式启动一次后，守护进程的日志会写到这里。',
                      style: TextStyle(color: muted),
                    )
                  : ListView.builder(
                      itemCount: _lines.length,
                      itemBuilder: (context, i) => Text(
                        _lines[i],
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.45,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// Per-app split page, laid out after the reference client:
// two switches on top - the master enable and the mode - and
// the app list below with launcher icons, names and package
// names. Bypass mode (the mode switch on): checked apps are
// excluded from the VPN (addDisallowedApplication). Allowlist
// mode (switch off): only the checked apps are routed into
// the VPN (addAllowedApplication). The choice takes effect
// the next time the VPN starts.
class _BypassAppsPage extends StatefulWidget {
  const _BypassAppsPage({
    required this.initialPkgs,
    required this.initialEnabled,
    required this.initialAllow,
    required this.onSave,
  });

  final Set<String> initialPkgs;
  final bool initialEnabled;
  final bool initialAllow;
  final void Function(bool enabled, bool allow, Set<String> pkgs) onSave;

  @override
  State<_BypassAppsPage> createState() => _BypassAppsPageState();
}

class _BypassAppsPageState extends State<_BypassAppsPage> {
  static const _channel = MethodChannel('flbox/vpn');

  late bool _enabled = widget.initialEnabled;
  late bool _allow = widget.initialAllow;
  late final Set<String> _selected = {...widget.initialPkgs};
  List<({String pkg, String label, Uint8List? icon})> _apps = [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listApps');
      final apps = <({String pkg, String label, Uint8List? icon})>[];
      for (final e in raw ?? const []) {
        final map = e as Map<dynamic, dynamic>;
        final pkg = map['pkg'] as String?;
        if (pkg == null || pkg == 'app.flbox') continue;
        final icon = map['icon'];
        apps.add((
          pkg: pkg,
          label: map['label'] as String? ?? pkg,
          icon: icon is Uint8List ? icon : null,
        ));
      }
      if (mounted) {
        setState(() {
          _apps = apps;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final visible = <({String pkg, String label, Uint8List? icon})>[
      for (final app in _apps)
        if (_query.isEmpty ||
            app.label.toLowerCase().contains(_query.toLowerCase()) ||
            app.pkg.toLowerCase().contains(_query.toLowerCase()))
          app,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('分应用设置'),
        actions: [
          TextButton(
            onPressed: () {
              widget.onSave(_enabled, _allow, _selected);
              Navigator.of(context).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Row(
              children: [
                const Expanded(child: Text('启用分应用')),
                Switch(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                const SizedBox(width: 24),
                const Expanded(child: Text('绕行模式')),
                Switch(
                  value: !_allow,
                  onChanged: (v) => setState(() => _allow = !v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                !_enabled
                    ? '未启用：所有应用都走 VPN'
                    : _allow
                        ? '绕行模式关：仅勾选的应用走 VPN，其余直连'
                        : '绕行模式开：勾选的应用绕过 VPN 直连',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索应用',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final app = visible[i];
                      final checked = _selected.contains(app.pkg);
                      return ListTile(
                        leading: app.icon != null
                            ? Image.memory(
                                app.icon!,
                                width: 42,
                                height: 42,
                                gaplessPlayback: true,
                              )
                            : const Icon(Icons.apps, size: 42),
                        title: Text(app.label),
                        subtitle: Text(
                          app.pkg,
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        trailing: Checkbox(
                          value: checked,
                          onChanged: (v) {
                            setState(() {
                              if (v ?? false) {
                                _selected.add(app.pkg);
                              } else {
                                _selected.remove(app.pkg);
                              }
                            });
                          },
                        ),
                        onTap: () {
                          setState(() {
                            if (checked) {
                              _selected.remove(app.pkg);
                            } else {
                              _selected.add(app.pkg);
                            }
                          });
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
