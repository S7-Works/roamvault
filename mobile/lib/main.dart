// TODO(slint): When the slint-flutter plugin is production-ready, wrap the
// MaterialApp with a SlintWidget root and bridge BackupState / AppSettings
// to Slint via platform channels or dart:ffi.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/backup_state.dart';
import 'screens/dashboard_screen.dart';
import 'screens/backup_screen.dart';
import 'screens/app_analysis_screen.dart';
import 'services/whatsapp_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BackupState()),
        ChangeNotifierProvider(create: (_) => AppSettings()),
      ],
      child: const RoamVaultApp(),
    ),
  );
}

class RoamVaultApp extends StatefulWidget {
  const RoamVaultApp({super.key});

  @override
  State<RoamVaultApp> createState() => _RoamVaultAppState();
}

class _RoamVaultAppState extends State<RoamVaultApp> {
  @override
  void initState() {
    super.initState();
    _initShareIntent();
  }

  void _initShareIntent() {
    final settings = context.read<AppSettings>();
    final backup = context.read<BackupState>();
    final svc = WhatsappService(settings: settings, state: backup);

    // Handle initial launch-via-share
    svc.handleInitialIntent();

    // Listen for subsequent shares while the app is open
    svc.shareStream.listen(svc.handleSharedFiles);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RoamVault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF005FA3), // deep travel blue
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF005FA3),
      ),
      home: const _RootShell(),
    );
  }
}

class _RootShell extends StatefulWidget {
  const _RootShell();

  @override
  State<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<_RootShell> {
  int _currentIndex = 0;

  final _screens = const [
    DashboardScreen(),
    BackupScreen(),
    AppAnalysisScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.backup_outlined),
            selectedIcon: Icon(Icons.backup),
            label: 'Backup',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Analysis',
          ),
        ],
      ),
    );
  }
}
