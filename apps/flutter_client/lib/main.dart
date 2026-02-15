import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

import 'services/app_mode_service.dart';
import 'services/saved_movies_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Popcorn',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
