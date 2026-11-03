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

import 'core_bridge.dart';

void main() {
  runApp(const FlboxApp());
}

// Visual baseline (see DESIGN.md): one background color, one accent color,
// generous whitespace, system font, stock Material widgets. Decoration is
// reserved for the floating glass navigation bar.
const _accent = Color(0xFF3478F6);
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
  });

  final String id;
  String name;
  String? url;
  String? subInfo;
  int nodeCount;
  int updatedAtMs;
  bool autoUpdate;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'subInfo': subInfo,
        'nodeCount': nodeCount,
        'updatedAtMs': updatedAtMs,
        'autoUpdate': autoUpdate,
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

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
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
  DateTime? _startedAt;
  Timer? _pollTimer;
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
    _restore();
    _checkNetwork();
    _askNotifications();
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
    // Per-subscription auto-update: each URL subscription opts in
    // on its own card; the check interval is a global setting.
    // Runs once at startup, like the old daily check did.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final intervalMs = _subAutoIntervalHours * 3600000;
    for (final sub in _subs) {
      if (sub.autoUpdate &&
          sub.url != null &&
          nowMs - sub.updatedAtMs > intervalMs) {
        await _fetchSubscription(sub.url!, updateSub: sub);
      }
    }
    await _resyncCoreState();
    if (_autoConnect && _profile != null && !_running && mounted) {
      await _toggleCore();
    }
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
          _logEvent('resync: adopted live VPN session');
          setState(() {
            _running = true;
            _startedAt = DateTime.now();
          });
          _startPolling();
        } else if (vpnActive) {
          _logEvent('resync: tunnel without core (zombie), tearing down');
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
      CoreBridge().xrayStart(config, _modeVpn ? _tunFd : 0);
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
    if (_running) {
      _toast('先停止再切换路由模式');
      return;
    }
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

  /// Fetches a subscription URL. With [updateSub] it refreshes that
  /// entry in place; without, it adds a new entry.
  Future<void> _fetchSubscription(String url, {SubProfile? updateSub}) async {
    final client = HttpClient();
    // Subscription traffic never goes through a proxy: not the
    // core's own local listener, not a system proxy. An update must
    // still succeed when every node is dead — that is usually when
    // it is needed most. (The app is also excluded from its own
    // VPN tunnel, so this fetch is direct end to end.)
    client.findProxy = (_) => 'DIRECT';
    try {
      client.userAgent = 'ClashMeta/1.0';
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
      if (response.statusCode != 200) {
        _toast('拉取失败：HTTP ${response.statusCode}');
        return;
      }
      final subInfo =
          _formatSubInfo(response.headers.value('subscription-userinfo'));
      final text = await response.transform(utf8.decoder).join();
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
        _toast('订阅已更新：${profile.nodes.length} 个节点');
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
      _toast('订阅内容不可用：${e.message}');
    } catch (e) {
      _toast('拉取失败：$e');
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
  }

  Future<void> _toggleCore() async {
    if (_busy) return;
    if (_running) {
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
      CoreBridge().xrayStart(config, fd);
      _logEvent(
          'core started (vpn=$_modeVpn, rules=$_rulesMode, node=$_selectedNode)');
      _startedAt = DateTime.now();
      setState(() => _running = true);
      _startPolling();
    } catch (e) {
      if (_modeVpn) {
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
    final fd = _modeVpn ? _tunFd : 0;
    setState(() {
      _testing = true;
      _delays = {};
    });
    try {
      final all = CoreBridge().translateAllXray(_profileYaml!, logPath: '');
      CoreBridge().xrayStart(all.config, 0);
      final entries = all.ports.entries.toList();
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
          CoreBridge().xrayStart(_profile!.configs[prevNode]!, fd);
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
        CoreBridge().xrayStart(config, _modeVpn ? _tunFd : 0);
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
    _pollTimer?.cancel();
    _traffic.dispose();
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
          ? 'Xray 内核 · VPN 模式（系统代理）'
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
                  Text(
                    '订阅：${profileName ?? '-'}${currentDelay != null ? ' · $currentDelay ms' : ''}',
                    style: TextStyle(color: muted, fontSize: 12.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            title: const Text('订阅自动更新间隔'),
            subtitle: Text(
              '启动时检查已开启自动更新的订阅；每个订阅的开关在配置页的订阅卡片上',
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
              'FlBox 0.21.0 · app.flbox · Xray 内核',
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

  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage> {
  String _query = '';
  int _sortMode = 0; // 0 智能（测速优先）· 1 按延迟 · 2 按名称
  bool _sortOpen = false; // 排序选项行是否展开（不用弹出菜单：模态层会挡住滑动）

  Color _delayColor(int? ms) {
    if (ms == null) return Colors.redAccent;
    if (ms < 300) return const Color(0xFF34A853);
    if (ms < 800) return Colors.orange;
    return Colors.redAccent;
  }

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
          Row(
            children: [
              Text(
                widget.profileName != null
                    ? '${widget.profileName} · ${profile.nodes.length} 个节点'
                    : '${profile.nodes.length} 个节点',
                style: TextStyle(color: muted),
              ),
              const Spacer(),
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
                  muted: muted,
                  favorite: widget.favorites.contains(node.name),
                  hasDelay: widget.delays.containsKey(node.name),
                  delay: widget.delays[node.name],
                  delayColor: _delayColor(widget.delays[node.name]),
                  selected: node.name == widget.selectedNode,
                  onTap: () => widget.onSelect(node.name),
                  onFav: () => widget.onToggleFav(node.name),
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
    required this.muted,
    required this.favorite,
    required this.hasDelay,
    required this.delay,
    required this.delayColor,
    required this.selected,
    required this.onTap,
    required this.onFav,
  });

  final XrayNode node;
  final Color muted;
  final bool favorite;
  final bool hasDelay;
  final int? delay;
  final Color delayColor;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFav;

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
        final lines = await file.readAsLines();
        final tail = lines.length > 200
            ? lines.sublist(lines.length - 200)
            : lines;
        _logTail = tail.join('\n');
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
                      style: const TextStyle(fontSize: 12, height: 1.5),
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
