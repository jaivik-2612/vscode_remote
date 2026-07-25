import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/home/home_page.dart';
import 'features/projects/projects_page.dart';
import 'features/search/search_page.dart';
import 'features/settings/settings_page.dart';
import 'features/team/team_page.dart';
import 'providers.dart';

class WaypointApp extends ConsumerWidget {
  const WaypointApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Waypoint',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: waypointTheme(Brightness.light),
      darkTheme: waypointTheme(Brightness.dark),
      home: const AppShell(),
    );
  }
}

ThemeData waypointTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    cardTheme: const CardThemeData(clipBehavior: Clip.antiAlias),
  );
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination('My work', Icons.today_outlined, Icons.today),
  _Destination('Projects', Icons.folder_outlined, Icons.folder),
  _Destination('Team', Icons.groups_outlined, Icons.groups),
  _Destination('Search', Icons.search_outlined, Icons.search),
  _Destination('Settings', Icons.settings_outlined, Icons.settings),
];

/// Adaptive navigation: rail on wide screens (desktop/tablet), bottom bar on
/// phones — one codebase, native-feeling on all five platforms.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _pages = [
    HomePage(),
    ProjectsPage(),
    TeamPage(),
    SearchPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final body = IndexedStack(index: _index, children: _pages);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Icon(
                  Icons.explore,
                  color: Theme.of(context).colorScheme.primary,
                  size: 32,
                ),
              ),
              destinations: [
                for (final destination in _destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}
