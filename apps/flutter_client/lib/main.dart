import 'dart:ui';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

import 'screens/welcome_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/mode_selector_screen.dart';
import 'screens/update_overlay.dart';
import 'screens/maintenance_overlay.dart';
import 'screens/no_internet_overlay.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

import 'services/app_mode_service.dart';
import 'services/saved_movies_service.dart';
import 'services/deep_link_service.dart';
import 'services/feature_flags_service.dart';
import 'services/torrent/torrent_engine_service.dart';
import 'services/trending_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Apache 2.0 attribution for the bundled Yellowtail font.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Yellowtail font'],
      await rootBundle.loadString('assets/fonts/Yellowtail-LICENSE.txt'),
    );
  });

  // Always start in portrait, regardless of whatever orientation the OS
  // Activity was left in. PlayerScreen/WebPlayer lock to landscape and only
  // reset back to portrait in their own dispose() — but if Android kills the
  // app process outright (common after the screen turns off mid-playback,
  // to reclaim memory) that dispose() never runs, since the process is
  // terminated abruptly rather than closed gracefully. The landscape lock
  // is held at the Activity level and survives the kill, so without this,
  // reopening from Recents cold-starts fresh into the mode selector screen
  // while still stuck in landscape.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Draw behind the system bars from the start (Android 15+ enforces this
  // anyway; the players already restore edgeToEdge when they close), and
  // drop Android's default translucent status bar scrim. See
  // AppTheme.systemUiStyle — it's also the root AnnotatedRegion below, so
  // screens that override it (e.g. ModeSelectorScreen) revert on leave.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(AppTheme.systemUiStyle);

  MediaKit.ensureInitialized();
  await SavedMoviesService().init();
  await AppModeService().init();
  await FeatureFlagsService().init();
  // Not awaited: this spins up the native libtorrent engine (DHT bootstrap,
  // tracker connections), which isn't needed until the user actually starts
  // streaming something. Awaiting it here delayed the first frame on every
  // cold start, even for users who just want to browse. streamMagnet()
  // already awaits init() itself if it hasn't finished by the time it's needed.
  unawaited(TorrentEngineService.instance.init());

  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print(
      "Warning: .env not found, TMDB API calls might fail if key is missing.",
    );
  }

  // Not awaited: warms up the mode selector's background slideshow while
  // the splash plays (needs the TMDB key from .env above).
  unawaited(TrendingService().fetch(AppModeService().currentMode.value));

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

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  _AppScreen _currentScreen = _AppScreen.checking;
  // The splash intro keeps covering the app until it has played through,
  // even if _checkConfig already resolved the next screen. Then:
  //  1. _splashRevealing: the next screen is built *underneath* the still,
  //     opaque splash, so its expensive first frames (layout, image
  //     decodes) happen where nobody can see them stutter.
  //  2. _splashFading: a moment later the splash fades out on top of it.
  //  3. _splashDone: the splash is removed.
  bool _splashRevealing = false;
  bool _splashFading = false;
  bool _splashDone = false;
  // Whether the mode selector's first background slide is loaded. The
  // splash waits for it (up to a cap) when that's the next screen, so the
  // selector doesn't open on an empty background.
  bool _selectorWarm = false;
  String _maintenanceMsg = "";
  String _updateMsg = "";
  String _updateUrl = "";

  final _navigatorKey = GlobalKey<NavigatorState>();
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkConfig();
    // Image precaching needs a context below MaterialApp (MediaQuery), so
    // start once the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmUpSelector());
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

  // Best-effort clean shutdown of the native libtorrent engine (DHT, peer
  // connections) when the OS is tearing the app down, instead of leaving it
  // running until the process is killed outright.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      TorrentEngineService.instance.dispose();
    }
    // Picks up flag edits (e.g. hide_playback) without a cold restart.
    if (state == AppLifecycleState.resumed) {
      FeatureFlagsService().refreshIfStale();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription.cancel();
    DeepLinkService().dispose();
    super.dispose();
  }

  Future<void> _warmUpSelector() async {
    final context = _navigatorKey.currentContext;
    if (context != null) {
      try {
        await TrendingService()
            .warmUp(AppModeService().currentMode.value, context)
            // Slow or offline: give up and let the selector show its
            // placeholder rather than holding the splash indefinitely.
            .timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    if (mounted) setState(() => _selectorWarm = true);
  }

  Future<void> _checkConfig() async {
    // Flags come from docs/flags.json on GitHub Pages (see
    // FeatureFlagsService). If the fetch fails (offline, slow network),
    // the last fetched values are used instead.
    final flags = FeatureFlagsService();
    await flags.refresh();

    if (flags.maintenanceEnabled) {
      if (mounted) {
        setState(() {
          _currentScreen = _AppScreen.maintenance;
          _maintenanceMsg = flags.maintenanceMessage;
        });
      }
      return;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (_isVersionLessThan(packageInfo.version, flags.minRequiredVersion)) {
        if (mounted) {
          setState(() {
            _currentScreen = _AppScreen.updateRequired;
            _updateMsg = flags.updateRequiredMessage;
            _updateUrl = flags.updateUrl;
          });
        }
        return;
      }
    } catch (e) {
      print("Failed to check app version: $e");
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

  void _onSplashFinished() {
    setState(() => _splashRevealing = true);
    // Give the newly mounted screen a couple of frames to lay out and
    // decode its first images before the splash starts fading off it.
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _splashFading = true);
    });
  }

  Widget? _buildScreen() {
    switch (_currentScreen) {
      case _AppScreen.checking:
        return null;
      case _AppScreen.updateRequired:
        return UpdateOverlay(message: _updateMsg, url: _updateUrl);
      case _AppScreen.maintenance:
        return MaintenanceOverlay(message: _maintenanceMsg);
      case _AppScreen.welcome:
        return WelcomeScreen(onGetStarted: _onWelcomeComplete);
      case _AppScreen.onboarding:
        return OnboardingScreen(onComplete: _onOnboardingComplete);
      case _AppScreen.modeSelector:
        return const ModeSelectorScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final screen = _splashRevealing ? _buildScreen() : null;

    return MaterialApp(
      title: 'Popcorn',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      builder: (context, child) {
        // `child` is the app's whole Navigator — swapping it out for
        // NoInternetOverlay (instead of stacking on top of it) unmounts the
        // Navigator entirely, destroying whatever route the user was on. On
        // reconnect, `child!` had to be rebuilt from scratch, restarting at
        // `home: homeWidget` (always ModeSelectorScreen by that point in a
        // session) instead of returning to where they were. Stacking the
        // overlay on top instead keeps the Navigator alive underneath —
        // it's just visually and interactively covered while offline.
        //
        // The root AnnotatedRegion sets the default system-bar style, so a
        // screen's own region (e.g. the mode selector's transparent
        // navigation bar) stops applying once that screen is gone instead
        // of sticking app-wide.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.systemUiStyle,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (child != null) child,
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: _isOffline
                    ? const NoInternetOverlay()
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
      home: Stack(
        fit: StackFit.expand,
        children: [
          if (screen != null)
            // Cross-fade between later startup screens (welcome →
            // onboarding → mode selector) instead of hard-cutting. The
            // first screen shown appears without a transition — it's
            // revealed by the splash fading off it.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: KeyedSubtree(
                key: ValueKey(_currentScreen),
                child: screen,
              ),
            ),
          if (!_splashDone)
            IgnorePointer(
              ignoring: _splashRevealing,
              child: AnimatedOpacity(
                opacity: _splashFading ? 0 : 1,
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOut,
                onEnd: () => setState(() => _splashDone = true),
                child: Scaffold(
                  backgroundColor: AppTheme.scaffoldColor,
                  body: Stack(
                    children: [
                      SplashScreen(
                        ready: _currentScreen != _AppScreen.checking &&
                            (_currentScreen != _AppScreen.modeSelector ||
                                _selectorWarm),
                        onFinished: _onSplashFinished,
                      ),
                      const _ShaderWarmup(),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Forces the BackdropFilter blur shader used throughout the movies UI
/// (nav bar, app bar, hero banner, details back button, etc.) to compile
/// now, during the startup loading screen, instead of the first time a
/// real blur is actually shown on screen — which otherwise freezes the
/// raster thread for a multi-second stall the first time it's needed each
/// app session (classic Flutter shader-compilation jank, most noticeable
/// switching into movies mode since it's the heaviest user of this
/// effect). 1x1 so it's imperceptible — the one-time compile cost is the
/// same regardless of how much screen area actually gets blurred.
class _ShaderWarmup extends StatelessWidget {
  const _ShaderWarmup();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      height: 1,
      child: ClipRect(
        child: BackdropFilter(
          // Kept in sync with the sigma actually used app-wide (see
          // custom_app_bar.dart/floating_bottom_nav_bar.dart/etc.) — this
          // widget's only job is to precompile that exact blur variant.
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(color: Colors.transparent),
        ),
      ),
    );
  }
}
