import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyArfeTkyJ0VyleDteHMJM_hJtC6iDiab80',
    appId: '1:903083291092:web:fccf0199968903b777a641',
    messagingSenderId: '903083291092',
    projectId: 'popcorn-a3a65',
    authDomain: 'popcorn-a3a65.firebaseapp.com',
    storageBucket: 'popcorn-a3a65.firebasestorage.app',
    measurementId: 'G-8XNERNHSLG',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyArfeTkyJ0VyleDteHMJM_hJtC6iDiab80',
    appId: '1:903083291092:web:fccf0199968903b777a641', // using web app ID since we only have web configured in desktop
    messagingSenderId: '903083291092',
    projectId: 'popcorn-a3a65',
    storageBucket: 'popcorn-a3a65.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyArfeTkyJ0VyleDteHMJM_hJtC6iDiab80',
    appId: '1:903083291092:web:fccf0199968903b777a641',
    messagingSenderId: '903083291092',
    projectId: 'popcorn-a3a65',
    storageBucket: 'popcorn-a3a65.firebasestorage.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyArfeTkyJ0VyleDteHMJM_hJtC6iDiab80',
    appId: '1:903083291092:web:fccf0199968903b777a641',
    messagingSenderId: '903083291092',
    projectId: 'popcorn-a3a65',
    storageBucket: 'popcorn-a3a65.firebasestorage.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyArfeTkyJ0VyleDteHMJM_hJtC6iDiab80',
    appId: '1:903083291092:web:fccf0199968903b777a641',
    messagingSenderId: '903083291092',
    projectId: 'popcorn-a3a65',
    authDomain: 'popcorn-a3a65.firebaseapp.com',
    storageBucket: 'popcorn-a3a65.firebasestorage.app',
    measurementId: 'G-8XNERNHSLG',
  );
}
