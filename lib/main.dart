import 'dart:ui';

import 'package:flutter/material.dart';

void main() {
  runApp(const FlboxApp());
}

// Visual baseline (see DESIGN.md): one background color, one accent color,
// generous whitespace, system font, stock Material widgets. The only
// decorated surface is the floating glass navigation bar.
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

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _pageController = PageController();
  int _index = 0;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _index = index),
        children: const [
          DashboardPage(),
          ProxiesPage(),
          ProfilesPage(),
          LogsPage(),
        ],
      ),
      bottomNavigationBar: _GlassNavBar(
        index: _index,
        destinations: _destinations,
        onTap: _select,
      ),
    );
  }
}

// Floating capsule bar with a liquid-glass finish: backdrop blur, a
// translucent fill, a faint highlight edge, and a pill indicator that
// slides between destinations. Glass is reserved for this bar and future
// overlays; pages stay plain.
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
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final fill = dark
        ? const Color(0xFF1D1D20).withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.66);
    final edge = dark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.6);
    const horizontalPadding = 5.0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: edge, width: 1),
                ),
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
                          top: 6,
                          bottom: 6,
                          width: itemWidth,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _accent.withValues(
                                alpha: dark ? 0.26 : 0.15,
                              ),
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
                                  child: _NavItem(
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.destination, required this.selected});

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
  const DashboardPage({super.key});

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
