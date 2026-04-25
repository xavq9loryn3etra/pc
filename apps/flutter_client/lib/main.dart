import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:media_kit/media_kit.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

import 'firebase_options.dart';
import 'screens/welcome_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/mode_selector_screen.dart';
import 'screens/update_overlay.dart';
import 'screens/maintenance_overlay.dart';
import 'screens/no_internet_overlay.dart';
import 'theme/app_theme.dart';

import 'services/app_mode_service.dart';
import 'services/saved_movies_service.dart';
import 'services/deep_link_service.dart';
import 'widgets/custom_loader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase C++ SDK on Windows only ships Debug libs, causing linker
  // errors in Release builds. The desktop Electron app handles Firebase
  // separately, so we only initialise on mobile.
  //
  // iOS: Currently skipped because firebase_options.dart has a *web* appId
  // for iOS (no iOS app is registered in the Firebase Console and there is
  // no GoogleService-Info.plist). The Firebase iOS native SDK validates the
  // appId format at the Obj-C level, throwing an NSException that kills
  // the process before Dart's try-catch can intercept it.
  // When you register a proper iOS app in Firebase Console, replace the
  // ios FirebaseOptions and add GoogleService-Info.plist, then re-enable.
  if (Platform.isAndroid) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      print("Warning: Firebase initialization failed: $e");
    }
  }

  MediaKit.ensureInitialized();
  await SavedMoviesService().init();
  await AppModeService().init();

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print(
      "Warning: .env not found, TMDB API calls might fail if key is missing.",
    );
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

enum _AppScreen {
  checking,
  updateRequired,
  maintenance,
  welcome,
  onboarding,
  modeSelector,
}

class _MyAppState extends State<MyApp> {
  _AppScreen _currentScreen = _AppScreen.checking;
  String _maintenanceMsg = "";
  String _updateMsg = "";
  
  final _navigatorKey = GlobalKey<NavigatorState>();
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _checkConfig();
    _initConnectivity();
    DeepLinkService().init(_navigatorKey);
  }

  void _initConnectivity() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.every((r) => r == ConnectivityResult.none);
      if (offline != _isOffline && mounted) {
        setState(() => _isOffline = offline);
      }
    });
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    DeepLinkService().dispose();
    super.dispose();
  }

  Future<void> _checkConfig() async {
    // Only check Remote Config on Android — Windows uses the Electron app's
    // own Firebase integration and the C++ SDK doesn't link in Release.
    // iOS is skipped because Firebase initialization is skipped until
    // native iOS configuration is added.
    if (Platform.isAndroid) {
      try {
        final remoteConfig = FirebaseRemoteConfig.instance;
        await remoteConfig.setConfigSettings(RemoteConfigSettings(
          fetchTimeout: const Duration(minutes: 1),
          minimumFetchInterval: const Duration(seconds: 1),
        ));

        await remoteConfig.setDefaults(const {
          "min_required_version": "1.0.0",
          "update_required_message":
              "A new update is available. Please update the app.",
          "maintenance_mode_enabled": false,
          "maintenance_message":
              "We are currently performing a scheduled maintenance. Please check back later."
        });

        await remoteConfig.fetchAndActivate();

        final maintenance = remoteConfig.getBool("maintenance_mode_enabled");
        final maintenanceMsg = remoteConfig.getString("maintenance_message");
        if (maintenance) {
          if (mounted) {
            setState(() {
              _currentScreen = _AppScreen.maintenance;
              _maintenanceMsg = maintenanceMsg;
            });
          }
          return;
        }

        final minVersion = remoteConfig.getString("min_required_version");
        final updateMsg = remoteConfig.getString("update_required_message");

        final packageInfo = await PackageInfo.fromPlatform();
        final currentVersion = packageInfo.version;

        if (_isVersionLessThan(currentVersion, minVersion)) {
          if (mounted) {
            setState(() {
              _currentScreen = _AppScreen.updateRequired;
              _updateMsg = updateMsg;
            });
          }
          return;
        }
      } catch (e) {
        print("Failed to fetch remote config: $e");
      }
    }

    // Determine which screen to show based on first-launch state
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSeenWelcome = prefs.getBool('has_seen_welcome') ?? false;
      final hasSeenOnboarding = prefs.getBool('has_seen_onboarding') ?? false;

      if (!hasSeenWelcome && mounted) {
        setState(() => _currentScreen = _AppScreen.welcome);
      } else if (!hasSeenOnboarding && mounted) {
        setState(() => _currentScreen = _AppScreen.onboarding);
      } else if (mounted) {
        setState(() => _currentScreen = _AppScreen.modeSelector);
      }
    } catch (_) {
      if (mounted) setState(() => _currentScreen = _AppScreen.modeSelector);
    }
  }

  bool _isVersionLessThan(String current, String minReq) {
    try {
      final cClean = current.split('+')[0];
      final mClean = minReq.split('+')[0];

      List<int> c = cClean.split('.').map((e) => int.parse(e)).toList();
      List<int> m = mClean.split('.').map((e) => int.parse(e)).toList();
      for (int i = 0; i < 3; i++) {
        if (c.length > i && m.length > i) {
          if (c[i] < m[i]) return true;
          if (c[i] > m[i]) return false;
        } else if (c.length <= i && m.length > i) {
          if (m[i] > 0) return true;
        } else if (c.length > i && m.length <= i) {
          if (c[i] > 0) return false;
        }
      }
    } catch (e) {
      // Ignored
    }
    return false;
  }

  Future<void> _onWelcomeComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_welcome', true);
    if (mounted) {
      setState(() => _currentScreen = _AppScreen.onboarding);
    }
  }

  Future<void> _onOnboardingComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_onboarding', true);
    if (mounted) {
      setState(() => _currentScreen = _AppScreen.modeSelector);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget homeWidget;

    switch (_currentScreen) {
      case _AppScreen.checking:
        homeWidget = const Scaffold(
          backgroundColor: Colors.black87,
          body: Center(
            child: CustomLoader(),
          ),
        );
        break;
      case _AppScreen.updateRequired:
        homeWidget = UpdateOverlay(message: _updateMsg);
        break;
      case _AppScreen.maintenance:
        homeWidget = MaintenanceOverlay(message: _maintenanceMsg);
        break;
      case _AppScreen.welcome:
        homeWidget = WelcomeScreen(onGetStarted: _onWelcomeComplete);
        break;
      case _AppScreen.onboarding:
        homeWidget = OnboardingScreen(onComplete: _onOnboardingComplete);
        break;
      case _AppScreen.modeSelector:
        homeWidget = const ModeSelectorScreen();
        break;
    }

    return MaterialApp(
      title: 'Popcorn',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      builder: (context, child) {
        if (_isOffline) {
          return const NoInternetOverlay();
        }
        return child!;
      },
      home: homeWidget,
    );
  }
}
