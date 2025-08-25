import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.android:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for android - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBtX3vOYyo5eaNJ5kRhQdQtD2jHZzxZNHs',
    appId: '1:96694132450:web:6f40a5f119d0ab7c13c8bb',
    messagingSenderId: '96694132450',
    projectId: 'camacho-daily-log',
    storageBucket: 'camacho-daily-log.firebasestorage.app',
    authDomain: 'camacho-daily-log.firebaseapp.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBtX3vOYyo5eaNJ5kRhQdQtD2jHZzxZNHs',
    appId: '1:96694132450:ios:6f40a5f119d0ab7c13c8bb',
    messagingSenderId: '96694132450',
    projectId: 'camacho-daily-log',
    storageBucket: 'camacho-daily-log.firebasestorage.app',
    iosBundleId: 'com.camacho.dailylog',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyBtX3vOYyo5eaNJ5kRhQdQtD2jHZzxZNHs',
    appId: '1:96694132450:ios:6f40a5f119d0ab7c13c8bb',
    messagingSenderId: '96694132450',
    projectId: 'camacho-daily-log',
    storageBucket: 'camacho-daily-log.firebasestorage.app',
    iosBundleId: 'com.camacho.dailylog',
  );
}
