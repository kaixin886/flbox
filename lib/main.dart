import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

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
  String? _profileUrl;
  Set<String> _bypassPkgs = {};
  bool _netBlocked = false;
  bool _batteryIgnored = false;
  int _upBytes = 0;
  int _downBytes = 0;
  double _speedUp = 0;
  double _speedDown = 0;
  DateTime? _startedAt;
  Timer? _pollTimer;

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

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    _modeVpn = prefs.getBool('mode_vpn') ?? true;
    _profileUrl = prefs.getString('profile_url');
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
      final file = File('${docs.path}/profile.yaml');
      if (await file.exists()) {
        final yaml = await file.readAsString();
        _profileYaml = yaml;
        final profile = CoreBridge().translateXray(
          yaml,
          vpn: _modeVpn,
          logPath: _logPath,
        );
        final stored = prefs.getString('selected_node');
        setState(() {
          _profile = profile;
          _profileName = prefs.getString('profile_name') ?? '已保存的配置';
          _selectedNode =
              profile.nodes.any((n) => n.name == stored)
                  ? stored
                  : profile.nodes.first.name;
        });
      }
    } catch (_) {
      // A stale or corrupt saved profile must not block startup.
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Shared landing path for file import and subscription fetch.
  /// A null [url] means a local file (and clears any stored URL).
  Future<void> _applyProfileYaml(
    String text, {
    required String name,
    String? url,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    _logPath = '${docs.path}/xray-error.log';
    final profile = CoreBridge().translateXray(
      text,
      vpn: _modeVpn,
      logPath: _logPath,
    );
    _profileYaml = text;
    await File('${docs.path}/profile.yaml').writeAsString(text);
    final prefs = await SharedPreferences.getInstance();
    final selected =
        profile.nodes.any((n) => n.name == _selectedNode)
            ? _selectedNode!
            : profile.nodes.first.name;
    await prefs.setString('profile_name', name);
    await prefs.setString('selected_node', selected);
    if (url != null) {
      await prefs.setString('profile_url', url);
    } else {
      await prefs.remove('profile_url');
    }
    setState(() {
      _profile = profile;
      _profileName = name;
      _selectedNode = selected;
      _profileUrl = url;
      _delays = {};
    });
    _toast('已导入 ${profile.nodes.length} 个可用节点');
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
      await _applyProfileYaml(text, name: picked.files.single.name);
    } on CoreException catch (e) {
      _toast('导入失败：${e.message}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<String?> _askUrl() async {
    final controller = TextEditingController(text: _profileUrl ?? '');
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

  Future<void> _fetchSubscription(String url) async {
    final client = HttpClient();
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
      final text = await response.transform(utf8.decoder).join();
      final host = Uri.parse(url).host;
      await _applyProfileYaml(
        text,
        name: host.isEmpty ? '订阅配置' : host,
        url: url,
      );
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

  Future<void> _updateSubscription() async {
    final url = _profileUrl;
    if (url == null) return;
    await _fetchSubscription(url);
  }

  Future<void> _deleteProfile() async {
    if (_running) {
      _toast('先停止再删除配置');
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    try {
      await File('${docs.path}/profile.yaml').delete();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('profile_name');
    await prefs.remove('profile_url');
    await prefs.remove('selected_node');
    setState(() {
      _profile = null;
      _profileName = null;
      _profileYaml = null;
      _profileUrl = null;
      _selectedNode = null;
      _delays = {};
    });
    _toast('已删除配置');
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
    var lastTick = DateTime.now();
    _upBytes = 0;
    _downBytes = 0;
    _speedUp = 0;
    _speedDown = 0;
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
          _speedUp = (up - lastUp) / dt;
          _speedDown = (down - lastDown) / dt;
        }
        lastUp = up;
        lastDown = down;
        lastTick = now;
        setState(() {
          _upBytes = up;
          _downBytes = down;
        });
      } catch (_) {
        // A failed poll just skips a beat; the next one retries.
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _startedAt = null;
    _speedUp = 0;
    _speedDown = 0;
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
        );
        setState(() => _profile = profile);
      } catch (e) {
        _toast('切换模式失败：$e');
      }
    }
  }

  Future<void> _testAll() async {
    if (_testing || _profile == null || _profileYaml == null) return;
    // When idle, the profile configs may carry a tun inbound that
    // needs a real VpnService fd, so measure with local-mode configs.
    XrayProfile testProfile;
    var fd = 0;
    if (_running) {
      testProfile = _profile!;
      fd = _modeVpn ? _tunFd : 0;
    } else {
      try {
        testProfile = CoreBridge().translateXray(
          _profileYaml!,
          vpn: false,
          logPath: '',
        );
      } catch (e) {
        _toast('测速准备失败：$e');
        return;
      }
    }
    final wasRunning = _running;
    final prevNode = _selectedNode;
    setState(() {
      _testing = true;
      _delays = {};
    });
    for (final node in testProfile.nodes) {
      if (!mounted || !_testing) break;
      final cfg = testProfile.configs[node.name];
      if (cfg == null) continue;
      int? ms;
      HttpClient? client;
      try {
        CoreBridge().xrayStart(cfg, fd);
        final sw = Stopwatch()..start();
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        client.findProxy = (_) => 'PROXY 127.0.0.1:7890';
        final req = await client
            .getUrl(Uri.parse('http://www.gstatic.com/generate_204'))
            .timeout(const Duration(seconds: 5));
        final resp = await req.close().timeout(const Duration(seconds: 5));
        await resp.drain<void>();
        sw.stop();
        ms = (resp.statusCode == 204 || resp.statusCode == 200)
            ? sw.elapsedMilliseconds
            : null;
      } catch (_) {
        ms = null;
      } finally {
        client?.close(force: true);
      }
      if (mounted) {
        setState(() => _delays = {..._delays, node.name: ms});
      }
    }
    try {
      if (wasRunning && prevNode != null) {
        CoreBridge().xrayStart(_profile!.configs[prevNode]!, fd);
      } else if (!wasRunning) {
        CoreBridge().xrayStop();
      }
    } catch (_) {}
    if (mounted) setState(() => _testing = false);
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
        ),
      ),
    );
    _checkNetwork();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
          DashboardPage(
            onOpenSettings: _openSettings,
            running: _running,
            busy: _busy,
            hasProfile: _profile != null,
            currentNode: _selectedNode,
            onToggle: _toggleCore,
            modeVpn: _modeVpn,
            upBytes: _upBytes,
            downBytes: _downBytes,
            speedUp: _speedUp,
            speedDown: _speedDown,
            startedAt: _startedAt,
            netBlocked: _netBlocked,
            onOpenNetSettings: _openNetSettings,
            onRecheckNetwork: _checkNetwork,
          ),
          ProxiesPage(
            profile: _profile,
            selectedNode: _selectedNode,
            onSelect: _selectNode,
            delays: _delays,
            testing: _testing,
            onTestAll: _profile == null ? null : _testAll,
          ),
          ProfilesPage(
            profile: _profile,
            profileName: _profileName,
            onImport: _importProfile,
            profileUrl: _profileUrl,
            onImportUrl: _importFromUrl,
            onUpdateSubscription:
                _profileUrl == null ? null : _updateSubscription,
            onDelete: _profile == null ? null : _deleteProfile,
          ),
          LogsPage(),
        ],
      ),
      bottomNavigationBar: switch (_navStyle) {
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
          NavigationDestination(icon: Icon(d.icon), label: d.label),
      ],
    );
  }
}

// Shared glass shell for the two glass bars: gradient specular edge,
// backdrop blur with a saturation lift, translucent fill, soft shadow.
class _GlassShell extends StatelessWidget {
  const _GlassShell({required this.child, this.pressGlow = 0});

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
              filter: ImageFilter.compose(
                outer: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                inner: const ColorFilter.matrix([
                  1.18, 0.12, 0.02, 0, -6,
                  0.10, 1.14, 0.04, 0, -6,
                  0.02, 0.10, 1.20, 0, -6,
                  0, 0, 0, 1, 0,
                ]),
              ),
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
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 120),
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
            const SizedBox(height: 24),
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

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.onOpenSettings,
    required this.running,
    required this.busy,
    required this.hasProfile,
    required this.currentNode,
    required this.onToggle,
    required this.modeVpn,
    required this.upBytes,
    required this.downBytes,
    required this.speedUp,
    required this.speedDown,
    required this.startedAt,
    required this.netBlocked,
    required this.onOpenNetSettings,
    required this.onRecheckNetwork,
  });

  final VoidCallback onOpenSettings;
  final bool running;
  final bool busy;
  final bool hasProfile;
  final String? currentNode;
  final VoidCallback onToggle;
  final bool modeVpn;
  final int upBytes;
  final int downBytes;
  final double speedUp;
  final double speedDown;
  final DateTime? startedAt;
  final bool netBlocked;
  final VoidCallback onOpenNetSettings;
  final VoidCallback onRecheckNetwork;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final String detail;
    if (running) {
      detail = modeVpn
          ? '当前节点：${currentNode ?? '-'} · Xray 内核 · VPN 模式（系统代理）'
          : '当前节点：${currentNode ?? '-'} · Xray 内核 · 普通模式 127.0.0.1:7890';
    } else if (!hasProfile) {
      detail = '先到「配置」页导入一个 Clash 配置。';
    } else {
      detail = '已就绪，节点：${currentNode ?? '-'}';
    }
    return _PageFrame(
      title: '仪表盘',
      action: IconButton(
        icon: const Icon(Icons.settings_outlined),
        tooltip: '设置',
        onPressed: onOpenSettings,
      ),
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
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(20),
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
            const SizedBox(height: 16),
          ],
          Container(
            decoration: BoxDecoration(
              color: _cardColor(context),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(20),
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
                        _fmtDuration(DateTime.now().difference(startedAt!)),
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Text(detail, style: TextStyle(color: muted)),
              ],
            ),
          ),
          if (running) ...[
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: _cardColor(context),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('↑ 上行', style: TextStyle(color: muted)),
                        const SizedBox(height: 6),
                        Text(
                          _fmtSpeed(speedUp),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '共 ${_fmtBytes(upBytes)}',
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('↓ 下行', style: TextStyle(color: muted)),
                        const SizedBox(height: 6),
                        Text(
                          _fmtSpeed(speedDown),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '共 ${_fmtBytes(downBytes)}',
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: busy ? null : onToggle,
              child: Text(busy ? '处理中…' : (running ? '停止' : '启动')),
            ),
          ),
        ],
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
  });

  final NavStyle navStyle;
  final ValueChanged<NavStyle> onNavStyleChanged;
  final bool modeVpn;
  final ValueChanged<bool> onModeChanged;
  final Set<String> bypassPkgs;
  final ValueChanged<Set<String>> onBypassChanged;
  final bool batteryIgnored;
  final VoidCallback onOpenBatterySettings;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late NavStyle _navStyle = widget.navStyle;
  late bool _modeVpn = widget.modeVpn;

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
        ],
      ),
    );
  }
}

class ProxiesPage extends StatefulWidget {
  const ProxiesPage({
    super.key,
    required this.profile,
    required this.selectedNode,
    required this.onSelect,
    required this.delays,
    required this.testing,
    required this.onTestAll,
  });

  final XrayProfile? profile;
  final String? selectedNode;
  final ValueChanged<String> onSelect;
  final Map<String, int?> delays;
  final bool testing;
  final VoidCallback? onTestAll;

  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage> {
  String _query = '';

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
    // Tested nodes first (fastest first), then untested, then timeouts;
    // the original profile order breaks ties.
    int rank(XrayNode n) {
      if (!widget.delays.containsKey(n.name)) return 1;
      return widget.delays[n.name] == null ? 2 : 0;
    }

    final indexed = <(int, XrayNode)>[
      for (var i = 0; i < profile.nodes.length; i++) (i, profile.nodes[i]),
    ];
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
                '${profile.nodes.length} 个节点',
                style: TextStyle(color: muted),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: widget.testing ? null : widget.onTestAll,
                child: Text(widget.testing
                    ? '测速中 ${widget.delays.length}/${profile.nodes.length}'
                    : '全部测速'),
              ),
            ],
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
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final node in nodes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _cardColor(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        title: Text(node.name),
                        subtitle:
                            Text(node.type, style: TextStyle(color: muted)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.delays.containsKey(node.name))
                              Text(
                                widget.delays[node.name] == null
                                    ? '超时'
                                    : '${widget.delays[node.name]} ms',
                                style: TextStyle(
                                  color: _delayColor(widget.delays[node.name]),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (node.name == widget.selectedNode) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle, color: _accent),
                            ],
                          ],
                        ),
                        onTap: () => widget.onSelect(node.name),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({
    super.key,
    required this.profile,
    required this.profileName,
    required this.onImport,
    required this.profileUrl,
    required this.onImportUrl,
    required this.onUpdateSubscription,
    required this.onDelete,
  });

  final XrayProfile? profile;
  final String? profileName;
  final VoidCallback onImport;
  final String? profileUrl;
  final VoidCallback onImportUrl;
  final VoidCallback? onUpdateSubscription;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final profile = this.profile;
    return _PageFrame(
      title: '配置',
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (profile == null)
              Text('暂无配置。从文件导入，或粘贴机场的订阅链接拉取。',
                  style: TextStyle(color: muted))
            else ...[
              Container(
                decoration: BoxDecoration(
                  color: _cardColor(context),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profileName ?? '已导入配置',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${profile.nodes.length} 个可用节点 · ${profile.skipped.length} 个已跳过',
                      style: TextStyle(color: muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profileUrl != null
                          ? '来源：订阅链接'
                          : '来源：本地文件',
                      style: TextStyle(color: muted),
                    ),
                  ],
                ),
              ),
              if (profile.skipped.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final s in profile.skipped)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '跳过：${s.name}（${s.type}）${s.reason}',
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: onImport,
                child: Text(profile == null ? '从文件导入' : '从文件重新导入'),
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
            if (onUpdateSubscription != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: FilledButton.tonal(
                  onPressed: onUpdateSubscription,
                  child: const Text('更新订阅'),
                ),
              ),
            ],
            if (onDelete != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: onDelete,
                child: const Text(
                  '删除配置',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ],
        ),
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
        final lines = await file.readAsLines();
        final tail = lines.length > 200
            ? lines.sublist(lines.length - 200)
            : lines;
        _logTail = tail.join('\n');
      } else {
        _logTail = '';
      }
    } catch (_) {
      _logTail = '';
    }
    if (mounted) setState(() => _loading = false);
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
            ],
          ),
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
        if (pkg == null || pkg == 'com.kaixin886.flbox.dev') continue;
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
