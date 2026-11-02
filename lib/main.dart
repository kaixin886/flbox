import 'dart:async';
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
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    _modeVpn = prefs.getBool('mode_vpn') ?? true;
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
      final docs = await getApplicationDocumentsDirectory();
      _logPath = '${docs.path}/xray-error.log';
      _profileYaml = text;
      final profile = CoreBridge().translateXray(
        text,
        vpn: _modeVpn,
        logPath: _logPath,
      );
      await File('${docs.path}/profile.yaml').writeAsString(text);
      final prefs = await SharedPreferences.getInstance();
      final name = picked.files.single.name;
      final selected =
          profile.nodes.any((n) => n.name == _selectedNode)
              ? _selectedNode!
              : profile.nodes.first.name;
      await prefs.setString('profile_name', name);
      await prefs.setString('selected_node', selected);
      setState(() {
        _profile = profile;
        _profileName = name;
        _selectedNode = selected;
      });
      _toast('已导入 ${profile.nodes.length} 个可用节点');
    } on CoreException catch (e) {
      _toast('导入失败：${e.message}');
    } catch (e) {
      _toast('导入失败：$e');
    }
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
      }
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
        await _vpnChannel.invokeMethod('startVpn');
        fd = await _tunReady!.future.timeout(const Duration(seconds: 15));
        _tunFd = fd;
      }
      CoreBridge().xrayStart(config, fd);
      setState(() => _running = true);
    } catch (e) {
      if (_modeVpn) {
        try {
          await _vpnChannel.invokeMethod('stopVpn');
        } catch (_) {}
        _tunFd = 0;
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

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsPage(
          navStyle: _navStyle,
          onNavStyleChanged: _setNavStyle,
          modeVpn: _modeVpn,
          onModeChanged: _setModeVpn,
        ),
      ),
    );
  }

  @override
  void dispose() {
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
  });

  final VoidCallback onOpenSettings;
  final bool running;
  final bool busy;
  final bool hasProfile;
  final String? currentNode;
  final VoidCallback onToggle;
  final bool modeVpn;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            running ? '运行中' : '未启动',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(detail, style: TextStyle(color: muted)),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: busy ? null : onToggle,
            child: Text(busy ? '处理中…' : (running ? '停止' : '启动')),
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
  });

  final NavStyle navStyle;
  final ValueChanged<NavStyle> onNavStyleChanged;
  final bool modeVpn;
  final ValueChanged<bool> onModeChanged;

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

class ProxiesPage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final profile = this.profile;
    if (profile == null) {
      return _PageFrame(
        title: '代理',
        child: Text('还没有配置，先到「配置」页导入。', style: TextStyle(color: muted)),
      );
    }
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
                onPressed: testing ? null : onTestAll,
                child: Text(testing
                    ? '测速中 ${delays.length}/${profile.nodes.length}'
                    : '全部测速'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final node in profile.nodes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(node.name),
                    subtitle: Text(node.type, style: TextStyle(color: muted)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (delays.containsKey(node.name))
                          Text(
                            delays[node.name] == null
                                ? '超时'
                                : '${delays[node.name]} ms',
                            style: TextStyle(
                              color: delays[node.name] == null
                                  ? Colors.redAccent
                                  : muted,
                            ),
                          ),
                        if (node.name == selectedNode) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.check_circle, color: _accent),
                        ],
                      ],
                    ),
                    onTap: () => onSelect(node.name),
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
  });

  final XrayProfile? profile;
  final String? profileName;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    final profile = this.profile;
    return _PageFrame(
      title: '配置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (profile == null)
            Text('暂无配置。导入 Clash 配置文件后，用 Xray 内核启动。',
                style: TextStyle(color: muted))
          else ...[
            Text(
              profileName ?? '已导入配置',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${profile.nodes.length} 个可用节点 · ${profile.skipped.length} 个已跳过',
              style: TextStyle(color: muted),
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
          const SizedBox(height: 32),
          FilledButton(
            onPressed: onImport,
            child: Text(profile == null ? '导入配置' : '重新导入'),
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
