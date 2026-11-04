import 'dart:async';
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
  for (final sub in subs) {
    if (!sub.autoUpdate || sub.url == null || sub.updateViaProxy) {
      continue;
    }
    if (nowMs - sub.updatedAtMs <= sub.autoIntervalHours * 3600000) {
      continue;
    }
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    try {
      client.userAgent = 'ClashMeta/1.0';
      final request = await client
          .getUrl(Uri.parse(sub.url!))
          .timeout(const Duration(seconds: 20));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) continue;
      var text = await response.transform(utf8.decoder).join();
      if (sub.keepRegex.isNotEmpty || sub.dropRegex.isNotEmpty) {
        text = CoreBridge().filterNodes(text, sub.keepRegex, sub.dropRegex);
      }
      final profile = CoreBridge().translateXray(
        text,
        vpn: false,
        logPath: '',
        rules: false,
      );
      if (profile.nodes.isEmpty) continue;
      await File('${docs.path}/sub_${sub.id}.yaml').writeAsString(text);
      sub.nodeCount = profile.nodes.length;
      sub.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      changed = true;
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
    await prefs.setBool('bg_subs_changed', true);
  }
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
const _lightBackground = Color(0xFFF7F7F9);
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
  _Destination(Icons.terminal, '日志'),
];

// Navigation bar appearance, switchable in Settings. The sliding glass
// bar is the default.
enum NavStyle {
  plain('普通导航栏'),
  glass('液态玻璃'),
  slidingGlass('液态玻璃（滑动）');

  const NavStyle(this.label);

  final String label;
}

/// One saved subscription / local profile. Several can coexist; one
/// is active at a time and feeds the core.
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
      );
}

/// One traffic poll sample. Carried in a ValueNotifier so the 2 s
/// poll rebuilds only the dashboard's traffic region instead of the
/// whole shell (all four pages) on every tick.
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

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final _pageController = PageController();
  int _index = 0;
  NavStyle _navStyle = NavStyle.slidingGlass;
  XrayProfile? _profile;
  String? _profileName;
  String? _selectedNode;
  bool _running = false;
  bool _busy = false;
  bool _modeVpn = true;
  int _tunFd = 0;
  String _logPath = '';
  String? _profileYaml;
  Map<String, int?> _delays = {};
  bool _testing = false;
  Completer<int>? _tunReady;
  List<SubProfile> _subs = [];
  String? _activeSubId;
  bool _rulesMode = false;
  bool _geoReady = false;
  Set<String> _favNodes = {};
  bool _autoConnect = false;
  int _subAutoIntervalHours = 24;
  Set<String> _bypassPkgs = {};
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
    _modeVpn = prefs.getBool('mode_vpn') ?? true;
    _rulesMode = prefs.getBool('rules_mode') ?? false;
    _autoConnect = prefs.getBool('auto_connect') ?? false;
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
          final profile = CoreBridge().translateXray(
            yaml,
            vpn: _modeVpn,
            logPath: _logPath,
            rules: _rulesMode,
          );
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
    if (_rulesMode && !_geoReady) {
      await _ensureGeoData();
    }
    // Per-subscription auto-update: each subscription carries its
    // own opt-in and interval (netproxy-style). Runs at startup,
    // on a 30-minute timer while the app lives, and hourly in the
    // background via WorkManager.
    await _checkBgSubUpdates();
    await _runDueSubscriptionUpdates();
    await _resyncCoreState();
    if (_autoConnect && _profile != null && !_running && mounted) {
      await _toggleCore();
    }
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
  void _logEvent(String msg) {
    try {
      if (_logPath.isEmpty) return;
      File(_logPath).writeAsStringSync(
        '${DateTime.now().toIso8601String()} [flbox] $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// Reconciles Dart's session state with reality at startup. After
  /// the task is swiped away or MIUI kills the process, the VPN
  /// service and the Go core can have survived (or not)
  /// independently of this fresh Dart state: adopt a session that is
  /// fully alive, tear down half-dead leftovers (a tunnel with no
  /// core black-holes all traffic and looks un-stoppable).
  Future<void> _resyncCoreState() async {
    try {
      final coreRunning = CoreBridge().xrayStatus().contains('running=true');
      if (_modeVpn) {
        final vpnActive =
            await _vpnChannel.invokeMethod<bool>('vpnActive') ?? false;
        if (vpnActive && coreRunning) {
          final fd = await _vpnChannel.invokeMethod<int>('tunFd') ?? -1;
          if (fd > 0) _tunFd = fd;
          if (!CoreBridge().vpnForwardActive()) {
            // Core and tunnel survived but the packet forwarder did
            // not: restart it on the same fd instead of adopting a
            // session whose tunnel black-holes everything.
            try {
              await _ensureSbSetup();
              CoreBridge().vpnForwardStart(_tunFd);
              _logEvent('resync: restarted the vpn forwarder');
            } catch (e) {
              _logEvent('resync: vpn forwarder restart failed: $e');
              try {
                CoreBridge().xrayStop();
              } catch (_) {}
              await _vpnChannel.invokeMethod('stopVpn');
              _tunFd = 0;
              _toast('已清理失效的 VPN 会话');
              return;
            }
          }
          _logEvent('resync: adopted live VPN session');
          setState(() {
            _running = true;
            _startedAt = DateTime.now();
          });
          _startPolling();
        } else if (vpnActive) {
          _logEvent('resync: tunnel without core (zombie), tearing down');
          try {
            CoreBridge().vpnForwardStop();
          } catch (_) {}
          await _vpnChannel.invokeMethod('stopVpn');
          _toast('已清理上次残留的 VPN 隧道');
        } else if (coreRunning) {
          _logEvent('resync: core without tunnel, stopping core');
          try {
            CoreBridge().xrayStop();
          } catch (_) {}
        }
      } else {
        final hostActive =
            await _vpnChannel.invokeMethod<bool>('coreActive') ?? false;
        if (coreRunning) {
          _logEvent('resync: adopted live local core');
          if (!hostActive) {
            await _vpnChannel.invokeMethod('startCoreService');
          }
          setState(() {
            _running = true;
            _startedAt = DateTime.now();
          });
          _startPolling();
        } else if (hostActive) {
          _logEvent('resync: core host without core, stopping host');
          await _vpnChannel.invokeMethod('stopCoreService');
        }
      }
    } catch (_) {}
  }

  /// The default network changed under a running core (Wi-Fi to
  /// mobile and back): its outbound sockets rot silently and pages
  /// load a little, then stall. Restart the core in place on the
  /// same tunnel, which is what a manual stop/start did, but
  /// automatically. Debounced: network flaps settle first.
  Future<void> _onNetworkChanged() async {
    if (!_running || _busy || _testing) return;
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
      CoreBridge().xrayStart(config, 0);
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
      final ok = await _vpnChannel
          .invokeMethod<bool>('extractGeoData', {'force': force});
      if (ok == true) {
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

  Future<void> _setRulesMode(bool rules) async {
    if (_busy || rules == _rulesMode) return;
    if (rules && !await _ensureGeoData()) {
      _toast('规则库准备失败，检查网络后重试');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rules_mode', rules);
    setState(() => _rulesMode = rules);
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
      // routing preset; the VPN itself never goes down.
      final config = _profile?.configs[_selectedNode];
      if (config != null) {
        try {
          CoreBridge().xrayStart(config, 0);
          _logEvent('core restarted for mode switch (rules=$rules)');
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
    _toast(rules ? '已切换到规则模式（v2ray 绕过大陆）' : '已切换到全局模式');
  }

  Future<void> _setAutoConnect(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect', value);
    setState(() => _autoConnect = value);
  }

  Future<void> _setSubAutoInterval(int hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sub_auto_interval_hours', hours);
    setState(() => _subAutoIntervalHours = hours);
  }

  Future<void> _toggleSubAutoUpdate(SubProfile sub) async {
    setState(() => sub.autoUpdate = !sub.autoUpdate);
    await _persistSubs();
  }

  /// Subscription editor (the netproxy-style form): name, link,
  /// per-subscription auto-update period, update route, and the
  /// node name filters applied on every refresh.
  Future<void> _openSubEditor(SubProfile sub) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => _SubEditPage(sub: sub)),
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

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Translates [text] and makes it the live profile (used whenever a
  /// subscription becomes active). The node selection survives when
  /// the new profile has a node with the same name.
  Future<void> _activateYaml(String text, {required String name}) async {
    final docs = await getApplicationDocumentsDirectory();
    _logPath = '${docs.path}/xray-error.log';
    final profile = CoreBridge().translateXray(
      text,
      vpn: _modeVpn,
      logPath: _logPath,
      rules: _rulesMode,
    );
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
  }

  /// Adds a new subscription entry from YAML text and activates it.
  Future<void> _addSubFromYaml(
    String text, {
    required String name,
    String? url,
    String? subInfo,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    _logPath = '${docs.path}/xray-error.log';
    final profile = CoreBridge().translateXray(
      text,
      vpn: _modeVpn,
      logPath: _logPath,
      rules: _rulesMode,
    );
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
    _toast('已导入 ${profile.nodes.length} 个可用节点');
  }

  Future<void> _switchSub(SubProfile sub) async {
    if (sub.id == _activeSubId) return;
    if (_running) {
      _toast('先停止再切换订阅');
      return;
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      final text = await _subFile(docs, sub.id).readAsString();
      _activeSubId = sub.id;
      await _persistSubs();
      await _activateYaml(text, name: sub.name);
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
          final p = CoreBridge().translateXray(
            targetYaml,
            vpn: _modeVpn,
            logPath: '',
            rules: _rulesMode,
          );
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
      final profile = CoreBridge().translateXray(
        newYaml,
        vpn: _modeVpn,
        logPath: _logPath,
        rules: _rulesMode,
      );
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
    // FileType.any on purpose: Android's picker filters by MIME type,
    // and .yaml files carry no consistent MIME on many ROMs, which left
    // them greyed out. Content is validated by the translator instead.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
    if (picked == null || picked.files.single.path == null) return;
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
  String? _formatSubInfo(String? raw) {
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

  /// Silent due-check used by startup, the in-app timer and (in
  /// its own isolate) the WorkManager task: refreshes every opted-in
  /// subscription whose own interval has elapsed. Via-proxy subs
  /// are skipped while the core is down.
  Future<void> _runDueSubscriptionUpdates() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final sub in _subs) {
      if (!sub.autoUpdate || sub.url == null) continue;
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
      client.userAgent = 'ClashMeta/1.0';
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
        final profile = CoreBridge().translateXray(
          text,
          vpn: _modeVpn,
          logPath: _logPath,
          rules: _rulesMode,
        );
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

  Future<void> _setBypassPkgs(Set<String> pkgs) async {
    setState(() => _bypassPkgs = pkgs);
    final prefs = await SharedPreferences.getInstance();
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
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !_running) return;
      try {
        final decoded =
            jsonDecode(CoreBridge().xrayTraffic()) as Map<String, dynamic>;
        final up = (decoded['up'] as num).toInt();
        final down = (decoded['down'] as num).toInt();
        final now = DateTime.now();
        final dt = now.difference(lastTick).inMilliseconds / 1000.0;
        if (dt > 0) {
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
        final hist = [..._rateHistory.value, _RateSample(speedUp, speedDown)];
        if (hist.length > 45) hist.removeRange(0, hist.length - 45);
        _rateHistory.value = hist;
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
  }

  Future<void> _toggleCore() async {
    if (_busy) return;
    if (_running) {
      if (_modeVpn) {
        try {
          CoreBridge().vpnForwardStop();
        } catch (_) {}
      }
      try {
        CoreBridge().xrayStop();
      } catch (_) {}
      if (_modeVpn) {
        await _vpnChannel.invokeMethod('stopVpn');
        _tunFd = 0;
      } else {
        await _vpnChannel.invokeMethod('stopCoreService');
      }
      _stopPolling();
      setState(() => _running = false);
      return;
    }
    final config = _profile?.configs[_selectedNode];
    if (config == null) {
      _toast('先到「代理」页选一个节点');
      return;
    }
    setState(() => _busy = true);
    try {
      var fd = 0;
      if (_modeVpn) {
        final prep = await _vpnChannel.invokeMethod<String>('prepare');
        if (prep != 'granted') {
          _toast('未授予 VPN 权限');
          return;
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
        _tunReady = Completer<int>();
        await _vpnChannel.invokeMethod('startVpn', {
          'bypass': _bypassPkgs.toList(),
        });
        fd = await _tunReady!.future.timeout(const Duration(seconds: 15));
        _tunFd = fd;
      } else {
        // Local mode: a foreground service hosts the process while the
        // core runs (reference clients never run a core in a bare UI
        // process — it gets frozen and its traffic silently dropped).
        // The service promotes itself to foreground FIRST, before the
        // core opens any socket.
        await _vpnChannel.invokeMethod('startCoreService');
      }
      await _rotateLogIfHuge();
      CoreBridge().xrayStart(config, 0);
      if (_modeVpn) {
        // The packet path: sing-box owns the tunnel fd and forwards
        // every flow into the mixed inbound Xray just opened.
        await _ensureSbSetup();
        CoreBridge().vpnForwardStart(fd);
        _logEvent('vpn forwarder started (sing-box tun -> 127.0.0.1:7890)');
      }
      _logEvent(
          'core started (vpn=$_modeVpn, rules=$_rulesMode, node=$_selectedNode)');
      _startedAt = DateTime.now();
      setState(() => _running = true);
      _startPolling();
    } catch (e) {
      if (_modeVpn) {
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
      } else {
        try {
          await _vpnChannel.invokeMethod('stopCoreService');
        } catch (_) {}
      }
      _toast('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setModeVpn(bool vpn) async {
    if (_running) {
      _toast('先停止再切换模式');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mode_vpn', vpn);
    setState(() => _modeVpn = vpn);
    final yaml = _profileYaml;
    if (yaml != null) {
      try {
        final profile = CoreBridge().translateXray(
          yaml,
          vpn: vpn,
          logPath: _logPath,
          rules: _rulesMode,
        );
        setState(() => _profile = profile);
      } catch (e) {
        _toast('切换模式失败：$e');
      }
    }
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

  /// Parallel latency test: one temporary instance carries every node
  /// on its own local port, and six workers probe them concurrently.
  /// The previously running node (if any) is restored afterwards.
  Future<void> _testAll() async {
    if (_testing || _profile == null || _profileYaml == null) return;
    final wasRunning = _running;
    final prevNode = _selectedNode;
    setState(() {
      _testing = true;
      _delays = {};
    });
    try {
      final all = CoreBridge().translateAllXray(_profileYaml!, logPath: '');
      CoreBridge().xrayStart(all.config, 0);
      final entries = all.ports.entries
          .where((e) => !isInfoNode(e.key))
          .toList();
      var next = 0;
      Future<void> worker() async {
        while (next < entries.length) {
          final entry = entries[next++];
          final ms = await _probePort(entry.value);
          if (mounted) {
            setState(() => _delays = {..._delays, entry.key: ms});
          }
        }
      }

      await Future.wait([for (var i = 0; i < 6; i++) worker()]);
    } catch (e) {
      _toast('测速失败：$e');
    } finally {
      try {
        if (wasRunning && prevNode != null) {
          CoreBridge().xrayStart(_profile!.configs[prevNode]!, 0);
        } else if (!wasRunning) {
          CoreBridge().xrayStop();
        }
      } catch (_) {}
      if (mounted) setState(() => _testing = false);
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
        CoreBridge().xrayStart(config, 0);
        _toast('已切换到 $name');
      } on CoreException catch (e) {
        setState(() => _running = false);
        _toast('切换失败：${e.message}');
      }
    }
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
          modeVpn: _modeVpn,
          onModeChanged: _setModeVpn,
          bypassPkgs: _bypassPkgs,
          onBypassChanged: _setBypassPkgs,
          batteryIgnored: _batteryIgnored,
          onOpenBatterySettings: () async {
            try {
              await _vpnChannel.invokeMethod('openBatterySettings');
            } catch (_) {}
          },
          rulesMode: _rulesMode,
          onRulesModeChanged: _setRulesMode,
          geoReady: _geoReady,
          onUpdateGeo: () async {
            final ok = await _ensureGeoData(force: true);
            _toast(ok ? '规则库已刷新（内置版本）' : '规则库刷新失败');
          },
          autoConnect: _autoConnect,
          onAutoConnectChanged: _setAutoConnect,
          autoIntervalHours: _subAutoIntervalHours,
          onAutoIntervalChanged: _setSubAutoInterval,
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

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  void _setNavStyle(NavStyle style) {
    setState(() => _navStyle = style);
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt('nav_style', style.index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: _navStyle != NavStyle.plain,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _index = index),
        children: [
          _DashboardPage(
            onOpenSettings: _openSettings,
            running: _running,
            hasProfile: _profile != null,
            currentNode: _selectedNode,
            modeVpn: _modeVpn,
            traffic: _traffic,
            rates: _rateHistory,
            startedAt: _startedAt,
            netBlocked: _netBlocked,
            onOpenNetSettings: _openNetSettings,
            onRecheckNetwork: _checkNetwork,
            profileName: _profileName,
            currentDelay:
                _selectedNode != null ? _delays[_selectedNode] : null,
            rulesMode: _rulesMode,
            onRulesModeChanged: _setRulesMode,
            onShowProxies: () => _select(1),
          ),
          ProxiesPage(
            subs: _subs,
            activeSubId: _activeSubId,
            onSwitchSub: _switchSub,
            onEditNode: _openNodeEditor,
            onAddNode: () => _openNodeEditor(),
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
            onToggleAutoUpdate: _toggleSubAutoUpdate,
            onEditSub: _openSubEditor,
          ),
          LogsPage(),
        ],
      ),
      bottomNavigationBar: RepaintBoundary(
        child: switch (_navStyle) {
        NavStyle.plain => _PlainNavBar(index: _index, onTap: _select),
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
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              onPressed: _busy ? null : _toggleCore,
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              child: _busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Icon(_running ? Icons.stop : Icons.play_arrow, size: 30),
            )
          : null,
    );
  }
}

class _PlainNavBar extends StatelessWidget {
  const _PlainNavBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onTap,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      indicatorColor: _accent.withValues(alpha: 0.15),
      destinations: [
        for (final d in _destinations)
          NavigationDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.icon, color: _accent),
            label: d.label,
          ),
      ],
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
        ? const Color(0xFF1D1D20).withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.52 + pressGlow * 0.1);
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
      _slideTo(widget.index.toDouble());
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
                  _slideTo(target.toDouble());
                  if (target != widget.index) {
                    HapticFeedback.selectionClick();
                    widget.onTap(target);
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
        // Bottom padding clears the floating navigation bar.
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 120),
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

Color _cardColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? 0.07 : 0.045,
        );

class _DashboardPage extends StatelessWidget {
  const _DashboardPage({
    required this.onOpenSettings,
    required this.running,
    required this.hasProfile,
    required this.currentNode,
    required this.modeVpn,
    required this.traffic,
    required this.rates,
    required this.startedAt,
    required this.netBlocked,
    required this.onOpenNetSettings,
    required this.onRecheckNetwork,
    required this.profileName,
    required this.currentDelay,
    required this.rulesMode,
    required this.onRulesModeChanged,
    required this.onShowProxies,
  });

  final VoidCallback onOpenSettings;
  final bool running;
  final bool hasProfile;
  final String? currentNode;
  final bool modeVpn;
  final ValueListenable<_Traffic> traffic;
  final ValueListenable<List<_RateSample>> rates;
  final DateTime? startedAt;
  final bool netBlocked;
  final VoidCallback onOpenNetSettings;
  final VoidCallback onRecheckNetwork;
  final String? profileName;
  final int? currentDelay;
  final bool rulesMode;
  final ValueChanged<bool> onRulesModeChanged;
  final VoidCallback onShowProxies;

  Widget _card(BuildContext context, {required Widget child, VoidCallback? onTap}) {
    return Material(
      color: _cardColor(context),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Widget _speedCard(
    BuildContext context, {
    required String label,
    required String speed,
    required String total,
    required Color muted,
  }) {
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: muted, fontSize: 13)),
          const SizedBox(height: 8),
          Text(
            speed,
            style: Theme.of(context).textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(total, style: TextStyle(color: muted, fontSize: 12.5)),
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
      statusDetail = modeVpn
          ? 'Xray 核心 · sing-box 数据通路 · VPN 模式'
          : 'Xray 内核 · 普通模式 127.0.0.1:7890';
    } else if (!hasProfile) {
      statusDetail = '先到「配置」页导入一个 Clash 配置';
    } else {
      statusDetail = '已就绪，点右下角按钮启动';
    }
    return _PageFrame(
      title: '仪表盘',
      action: IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: '设置',
        onPressed: onOpenSettings,
      ),
      child: SingleChildScrollView(
        child: Column(
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: running
                                    ? const Color(0xFF34A853)
                                    : muted,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              running ? '运行中' : '未启动',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (running && startedAt != null) ...[
                              const Spacer(),
                              Text(
                                _fmtDuration(
                                    DateTime.now().difference(startedAt!)),
                                style: TextStyle(color: muted),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(statusDetail, style: TextStyle(color: muted)),
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
                          label: '↑ 上行',
                          speed: _fmtSpeed(traffic.speedUp),
                          total: '共 ${_fmtBytes(traffic.up)}',
                          muted: muted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _speedCard(
                          context,
                          label: '↓ 下行',
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
                              style: TextStyle(color: muted, fontSize: 12)),
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
                              style: TextStyle(color: muted, fontSize: 12)),
                        ],
                      ),
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
                        selected: !rulesMode,
                        onTap: () => onRulesModeChanged(false),
                      ),
                      const SizedBox(width: 10),
                      _modeChip(
                        context,
                        label: '规则模式',
                        selected: rulesMode,
                        onTap: () => onRulesModeChanged(true),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('当前节点',
                          style: TextStyle(color: muted, fontSize: 13)),
                      const Spacer(),
                      Icon(Icons.chevron_right, size: 18, color: muted),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    currentNode ?? '-',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '订阅：${profileName ?? '-'}',
                          style: TextStyle(color: muted, fontSize: 12.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (currentDelay != null)
                        Text(
                          ' · $currentDelay ms',
                          style: TextStyle(
                            color: _delayColor(currentDelay),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
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
    if (maxV <= 0) maxV = 1;
    final stepX = size.width / 44;
    double x(int i) => size.width - (samples.length - 1 - i) * stepX;
    double y(double v) => size.height - 3 - (v / maxV) * (size.height - 8);

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
    required this.modeVpn,
    required this.onModeChanged,
    required this.bypassPkgs,
    required this.onBypassChanged,
    required this.batteryIgnored,
    required this.onOpenBatterySettings,
    required this.rulesMode,
    required this.onRulesModeChanged,
    required this.geoReady,
    required this.onUpdateGeo,
    required this.autoConnect,
    required this.onAutoConnectChanged,
    required this.autoIntervalHours,
    required this.onAutoIntervalChanged,
  });

  final NavStyle navStyle;
  final ValueChanged<NavStyle> onNavStyleChanged;
  final bool modeVpn;
  final ValueChanged<bool> onModeChanged;
  final Set<String> bypassPkgs;
  final ValueChanged<Set<String>> onBypassChanged;
  final bool batteryIgnored;
  final VoidCallback onOpenBatterySettings;
  final bool rulesMode;
  final ValueChanged<bool> onRulesModeChanged;
  final bool geoReady;
  final VoidCallback onUpdateGeo;
  final bool autoConnect;
  final ValueChanged<bool> onAutoConnectChanged;
  final int autoIntervalHours;
  final ValueChanged<int> onAutoIntervalChanged;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late NavStyle _navStyle = widget.navStyle;
  late bool _modeVpn = widget.modeVpn;
  late int _autoIntervalHours = widget.autoIntervalHours;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Text('外观', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('导航栏样式', style: TextStyle(color: muted)),
          const SizedBox(height: 8),
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
          const SizedBox(height: 24),
          Text('模式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('系统代理（VPN）'),
            subtitle: Text('接管全机流量，需要授予 VPN 权限',
                style: TextStyle(color: muted)),
            trailing: _modeVpn
                ? const Icon(Icons.check, color: _accent)
                : null,
            onTap: () {
              setState(() => _modeVpn = true);
              widget.onModeChanged(true);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('普通模式'),
            subtitle: Text('只在本机 127.0.0.1:7890 提供代理',
                style: TextStyle(color: muted)),
            trailing: !_modeVpn
                ? const Icon(Icons.check, color: _accent)
                : null,
            onTap: () {
              setState(() => _modeVpn = false);
              widget.onModeChanged(false);
            },
          ),
          const SizedBox(height: 24),
          Text('代理', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('分应用代理'),
            subtitle: Text(
              widget.bypassPkgs.isEmpty
                  ? '所有应用都走 VPN'
                  : '${widget.bypassPkgs.length} 个应用绕过 VPN',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _BypassAppsPage(
                    initial: widget.bypassPkgs,
                    onChanged: widget.onBypassChanged,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text('代理', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('全局模式'),
            subtitle: Text('所有流量都走代理', style: TextStyle(color: muted)),
            trailing: !widget.rulesMode
                ? const Icon(Icons.check, color: _accent)
                : null,
            onTap: () => widget.onRulesModeChanged(false),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('规则模式（分流）'),
            subtitle:
                Text('v2ray 原版绕过大陆：国内域名与 IP 直连，其余走代理', style: TextStyle(color: muted)),
            trailing: widget.rulesMode
                ? const Icon(Icons.check, color: _accent)
                : null,
            onTap: () => widget.onRulesModeChanged(true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('分流规则库'),
            subtitle: Text(
              widget.geoReady ? '已内置于安装包，点按可刷新' : '内置于安装包（开启规则模式时自动释放）',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onUpdateGeo,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启动后自动连接'),
            subtitle:
                Text('打开 FlBox 时自动启动上次的节点', style: TextStyle(color: muted)),
            value: widget.autoConnect,
            onChanged: widget.onAutoConnectChanged,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('新订阅默认更新周期'),
            subtitle: Text(
              '每份订阅的自动更新开关、周期、更新网络和节点过滤在配置页点订阅的「编辑」设置；到期后应用在前台和后台都会自动更新',
              style: TextStyle(color: muted),
            ),
          ),
          Wrap(
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
          const SizedBox(height: 24),
          Text('系统', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
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
          const SizedBox(height: 24),
          Text('内核', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
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
          const SizedBox(height: 32),
          Center(
            child: Text(
              'FlBox 0.24.0 · app.flbox · Xray 内核',
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
    required this.subs,
    required this.activeSubId,
    required this.onSwitchSub,
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
  final List<SubProfile> subs;
  final String? activeSubId;
  final ValueChanged<SubProfile> onSwitchSub;

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
    return _PageFrame(
      title: '代理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Subscription tabs, like FlClash's group tabs: switching
          // here reuses the profiles page's switch path.
          if (widget.subs.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < widget.subs.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(widget.subs[i].name),
                      selected: widget.subs[i].id == widget.activeSubId,
                      onSelected: (_) => widget.onSwitchSub(widget.subs[i]),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Text(
                widget.profileName != null
                    ? '${widget.profileName} · ${profile.nodes.length} 个节点'
                    : '${profile.nodes.length} 个节点',
                style: TextStyle(color: muted),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: '手动添加节点',
                onPressed: widget.onAddNode,
              ),
              FilledButton.tonal(
                onPressed: widget.testing ? null : widget.onTestAll,
                child: Text(widget.testing
                    ? '测速中 ${widget.delays.length}/${profile.nodes.length}'
                    : '全部测速'),
              ),
              IconButton(
                icon: const Icon(Icons.bolt),
                tooltip: '测速并选最快',
                onPressed: widget.testing ? null : widget.onPickFastest,
              ),
              IconButton(
                icon: const Icon(Icons.sort),
                tooltip: '排序',
                color: _sortOpen
                    ? Theme.of(context).colorScheme.primary
                    : null,
                onPressed: () => setState(() => _sortOpen = !_sortOpen),
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
                            label: Text(
                                const ['智能排序', '按延迟', '按名称'][i]),
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
          Expanded(
            // Builder, not a children list: with 30+ nodes the eager
            // list built every tile on every page rebuild (search
            // keystrokes, delay updates), which visibly hitched.
            child: GridView.builder(
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
          ),
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
                : null,
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
                  Text(
                    node.type,
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const Spacer(),
                  if (hasDelay)
                    Text(
                      delay == null ? '超时' : '$delay ms',
                      style: TextStyle(
                        color: delayColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    )
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
  });

  final bool isNew;
  final Map<String, dynamic> detail;
  final Set<String> siblingNames;
  final bool fromSubscription;

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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
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
    });
  }

  Widget _textField(TextEditingController ctl, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: ctl,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    final hasUrl = widget.sub.url != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑订阅'),
        actions: [
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
          _textField(_nameCtl, '订阅名称'),
          if (hasUrl) _textField(_urlCtl, '订阅链接'),
          if (hasUrl) ...[
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
                  onSelected: (_) => setState(() => _viaProxy = false),
                ),
                ChoiceChip(
                  label: const Text('经当前代理'),
                  selected: _viaProxy,
                  onSelected: (_) => setState(() => _viaProxy = true),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _textField(_keepCtl, '仅保留（正则，可选）'),
            _textField(_dropCtl, '排除（正则，可选）'),
            Text(
              '过滤按节点名匹配，在每次更新时应用；手动添加的节点在「手动节点」里，不受订阅更新影响。',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ] else
            Text(
              '本地配置没有链接，不参与自动更新。',
              style: TextStyle(color: muted),
            ),
        ],
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
    required this.onToggleAutoUpdate,
    required this.onEditSub,
  });

  final List<SubProfile> subs;
  final String? activeSubId;
  final List<SkippedNode> activeSkipped;
  final VoidCallback onImport;
  final VoidCallback onImportUrl;
  final ValueChanged<SubProfile> onSwitch;
  final ValueChanged<SubProfile> onUpdate;
  final ValueChanged<SubProfile> onDelete;
  final ValueChanged<SubProfile> onToggleAutoUpdate;
  final ValueChanged<SubProfile> onEditSub;

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
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: onImport,
                child: const Text('从文件导入'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: FilledButton.tonal(
                onPressed: onImportUrl,
                child: const Text('从订阅链接导入'),
              ),
            ),
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
    return Container(
      decoration: BoxDecoration(
        color: _cardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: active ? Border.all(color: _accent, width: 1.5) : null,
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (active)
                const Text(
                  '使用中',
                  style: TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(meta.toString(), style: TextStyle(color: muted)),
          if (sub.subInfo != null) ...[
            const SizedBox(height: 4),
            Text(sub.subInfo!, style: TextStyle(color: muted)),
          ],
          if (sub.url != null)
            Row(
              children: [
                Text('自动更新', style: TextStyle(color: muted)),
                const Spacer(),
                Switch(
                  value: sub.autoUpdate,
                  onChanged: (_) => onToggleAutoUpdate(sub),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (!active)
                TextButton(
                  onPressed: () => onSwitch(sub),
                  child: const Text('使用'),
                ),
              if (sub.url != null)
                TextButton(
                  onPressed: () => onUpdate(sub),
                  child: const Text('更新'),
                ),
              TextButton(
                onPressed: () => onEditSub(sub),
                child: const Text('编辑'),
              ),
              TextButton(
                onPressed: () => _confirmDelete(context, sub),
                child: const Text(
                  '删除',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String? _status;
  String _logTail = '';
  String _logMeta = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadLog();
  }

  Future<void> _loadLog() async {
    setState(() => _loading = true);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/xray-error.log');
      if (await file.exists()) {
        final size = await file.length();
        _logMeta = '日志文件 $size 字节';
        // Tail read only: the file grows to megabytes, and a
        // whole-file strict UTF-8 decode throws on any damaged byte
        // - which left this page blank while the file kept growing.
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
          final lines = text.split('\n');
          final tail = lines.length > 200
              ? lines.sublist(lines.length - 200)
              : lines;
          _logTail = tail.join('\n').trim();
        } finally {
          await raf.close();
        }
      } else {
        _logMeta = '日志文件尚不存在（核心启动后创建）';
        _logTail = '';
      }
    } catch (_) {
      _logTail = '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _clearLog() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/xray-error.log');
      // Truncate, never delete: the core keeps the file open, and
      // deleting the path would send all later lines to an unlinked
      // inode (the page would show "no logs" until a core restart).
      if (await file.exists()) await file.writeAsString('');
      _logMeta = '日志文件已清空（截断）';
    } catch (_) {}
    if (mounted) setState(() => _logTail = '');
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '日志',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: _loading ? null : _loadLog,
                child: Text(_loading ? '刷新中…' : '刷新日志'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _clearLog,
                child: const Text('清空'),
              ),
            ],
          ),
          if (_logMeta.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_logMeta, style: TextStyle(color: muted, fontSize: 12)),
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            SelectableText(_status!),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: _logTail.isEmpty
                ? Text('暂无日志。启动一次内核后，Xray 的运行日志会写到这里。',
                    style: TextStyle(color: muted))
                : SingleChildScrollView(
                    child: SelectableText(
                      _logTail,
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
    );
  }
}

// Per-app bypass picker: checked apps are excluded from the VPN
// (addDisallowedApplication) the next time it starts.
class _BypassAppsPage extends StatefulWidget {
  const _BypassAppsPage({required this.initial, required this.onChanged});

  final Set<String> initial;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<_BypassAppsPage> createState() => _BypassAppsPageState();
}

class _BypassAppsPageState extends State<_BypassAppsPage> {
  static const _channel = MethodChannel('flbox/vpn');

  late final Set<String> _selected = {...widget.initial};
  List<({String pkg, String label})> _apps = [];
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
      final apps = <({String pkg, String label})>[];
      for (final e in raw ?? const []) {
        final map = (e as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
        final pkg = map['pkg'];
        if (pkg == null || pkg == 'app.flbox') continue;
        apps.add((pkg: pkg, label: map['label'] ?? pkg));
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
    final visible = <({String pkg, String label})>[
      for (final app in _apps)
        if (_query.isEmpty ||
            app.label.toLowerCase().contains(_query.toLowerCase()) ||
            app.pkg.toLowerCase().contains(_query.toLowerCase()))
          app,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('分应用代理'),
        actions: [
          TextButton(
            onPressed: () {
              widget.onChanged(_selected);
              Navigator.of(context).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '勾选的应用绕过 VPN 直连，下次启动 VPN 时生效',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    children: [
                      for (final app in visible)
                        CheckboxListTile(
                          title: Text(app.label),
                          subtitle: Text(
                            app.pkg,
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                          value: _selected.contains(app.pkg),
                          onChanged: (checked) {
                            setState(() {
                              if (checked ?? false) {
                                _selected.add(app.pkg);
                              } else {
                                _selected.remove(app.pkg);
                              }
                            });
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
