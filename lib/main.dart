import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// Navigation bar appearance, switchable on the dashboard. Dynamic liquid
// glass is the default.
enum NavStyle {
  plain('普通导航栏'),
  glass('液态玻璃'),
  dynamicGlass('动态液态玻璃');

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
  NavStyle _navStyle = NavStyle.dynamicGlass;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getInt('nav_style');
      if (saved != null && saved >= 0 && saved < NavStyle.values.length) {
        setState(() => _navStyle = NavStyle.values[saved]);
      }
    });
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
          DashboardPage(navStyle: _navStyle, onNavStyleChanged: _setNavStyle),
          const ProxiesPage(),
          const ProfilesPage(),
          const LogsPage(),
        ],
      ),
      bottomNavigationBar: switch (_navStyle) {
        NavStyle.plain => _PlainNavBar(index: _index, onTap: _select),
        NavStyle.glass => _GlassNavBar(
            index: _index,
            destinations: _destinations,
            onTap: _select,
          ),
        NavStyle.dynamicGlass => _DynamicGlassNavBar(
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

// The FlClash-style lens: a wide glass capsule with chromatic fringes on
// its left and right edges (red and cyan peeking out from under the main
// capsule), a specular sheen across the top, and an accent tint wash.
class _Lens extends StatelessWidget {
  const _Lens({required this.dark, required this.press});

  final bool dark;
  final double press;

  // Fringes fade out toward the top and bottom so the color split reads
  // as refraction at the lens ends, not a full colored outline.
  Widget _fringe(Color color, double shift) {
    return Positioned(
      left: shift,
      right: -shift,
      top: 0,
      bottom: 0,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, 0.3, 0.7, 1],
        ).createShader(rect),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(26)),
            border: Border.all(
              color: color.withValues(alpha: 0.22 + press * 0.25),
              width: 0.9,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(26));
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: _accent.withValues(alpha: 0.06 + press * 0.22),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ),
        _fringe(const Color(0xFFFF453A), -1.1),
        _fringe(const Color(0xFF32ADE6), 1.1),
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: dark ? 0.13 : 0.22),
                  _accent.withValues(alpha: (dark ? 0.12 : 0.07) + press * 0.06),
                  Colors.white.withValues(alpha: dark ? 0.04 : 0.08),
                ],
                stops: const [0, 0.55, 1],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.40 + press * 0.35),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  heightFactor: 0.5,
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.30),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                color: Colors.white.withValues(alpha: press * 0.14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Dynamic liquid glass: the pill rides a spring, stretches along its
// travel direction, follows horizontal drags, and swells with a glow
// while the bar is long-pressed.
class _DynamicGlassNavBar extends StatefulWidget {
  const _DynamicGlassNavBar({
    required this.index,
    required this.destinations,
    required this.onTap,
  });

  final int index;
  final List<_Destination> destinations;
  final ValueChanged<int> onTap;

  @override
  State<_DynamicGlassNavBar> createState() => _DynamicGlassNavBarState();
}

class _DynamicGlassNavBarState extends State<_DynamicGlassNavBar>
    with TickerProviderStateMixin {
  static const _horizontalPadding = 5.0;
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 320,
    ratio: 1.0,
  );

  late final AnimationController _springController;
  late final AnimationController _pressController;
  double _pos = 0;
  double _velocity = 0;
  double _lastPos = 0;
  int? _lastTick;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _pos = widget.index.toDouble();
    _lastPos = _pos;
    _springController = AnimationController.unbounded(vsync: this)
      ..addListener(_onSpringTick);
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
  }

  @override
  void didUpdateWidget(_DynamicGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && widget.index != oldWidget.index) {
      _springTo(widget.index.toDouble());
    }
  }

  @override
  void dispose() {
    _springController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  void _onSpringTick() {
    final now = DateTime.now().microsecondsSinceEpoch;
    setState(() {
      _pos = _springController.value;
      if (_lastTick != null) {
        final dt = (now - _lastTick!) / 1e6;
        if (dt > 0) {
          final v = (_pos - _lastPos) / dt;
          _velocity = _velocity * 0.6 + v * 0.4;
        }
      }
      _lastPos = _pos;
      _lastTick = now;
    });
  }

  void _springTo(double target) {
    _springController.animateWith(
      SpringSimulation(_spring, _pos, target, _velocity),
    );
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
        return Transform.scale(
          scale: 1 + press * 0.02,
          child: _GlassShell(
            pressGlow: press,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final contentWidth = constraints.maxWidth;
                final itemWidth =
                    (contentWidth - _horizontalPadding * 2) /
                        widget.destinations.length;
                final stretch = (_velocity.abs() * 0.03).clamp(0.0, 0.10);
                // Lens: only slightly wider than one item slot.
                final pillWidth = itemWidth * 1.22 * (1 + stretch);
                final itemCenter = _horizontalPadding +
                    _pos * itemWidth +
                    itemWidth / 2;
                final pillLeft = (itemCenter - pillWidth / 2)
                    .clamp(2.0, contentWidth - pillWidth - 2);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) {
                    _dragging = true;
                    _springController.stop();
                    _pressController.forward();
                  },
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _pos = (_pos + details.delta.dx / itemWidth)
                          .clamp(-0.15, widget.destinations.length - 0.85);
                      _velocity = 0;
                      _lastPos = _pos;
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    _dragging = false;
                    _pressController.reverse();
                    final target = _nearest;
                    _springTo(target.toDouble());
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
                        left: pillLeft,
                        top: 8,
                        bottom: 8,
                        width: pillWidth,
                        child: Transform.scale(
                          scale: 1 + press * 0.13,
                          child: _Lens(dark: dark, press: press),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0;
                              i < widget.destinations.length;
                              i++)
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
          ),
        );
      },
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.child});

  final String title;
  final Widget child;

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
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            child,
          ],
        ),
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.navStyle,
    required this.onNavStyleChanged,
  });

  final NavStyle navStyle;
  final ValueChanged<NavStyle> onNavStyleChanged;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '仪表盘',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('未启动', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('内核状态与流量概览将显示在这里。', style: TextStyle(color: muted)),
          const SizedBox(height: 32),
          FilledButton(onPressed: () {}, child: const Text('启动')),
          const SizedBox(height: 48),
          Text('导航栏样式', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final style in NavStyle.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(style.label),
              trailing: navStyle == style
                  ? const Icon(Icons.check, color: _accent)
                  : null,
              onTap: () => onNavStyleChanged(style),
            ),
        ],
      ),
    );
  }
}

class ProxiesPage extends StatelessWidget {
  const ProxiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '代理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入配置后，节点组与测速结果显示在这里。', style: TextStyle(color: muted)),
          const SizedBox(height: 16),
          for (final name in ['示例节点 A', '示例节点 B'])
            Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(name),
                  trailing: Text('-- ms', style: TextStyle(color: muted)),
                ),
                const Divider(),
              ],
            ),
        ],
      ),
    );
  }
}

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '配置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('暂无配置', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('支持导入 Clash YAML 配置文件。', style: TextStyle(color: muted)),
          const SizedBox(height: 32),
          OutlinedButton(onPressed: () {}, child: const Text('导入配置')),
        ],
      ),
    );
  }
}

class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: 0.5);
    return _PageFrame(
      title: '日志',
      child: Text('内核日志将实时显示在这里。', style: TextStyle(color: muted)),
    );
  }
}
