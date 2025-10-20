import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import 'config/app_theme.dart';
import 'config/router.dart';
import 'firebase_options.dart';
import 'controllers/app_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    print('Initializing Firebase...');
    print('Current platform: ${defaultTargetPlatform}');
    print('Is web: $kIsWeb');

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    print('Firebase initialized successfully');
  } catch (e) {
    print('Firebase initialization failed: $e');
    print('Error type: ${e.runtimeType}');
    print('Error stack trace: ${e.toString()}');

    // Show a user-friendly error message
    if (kIsWeb) {
      print(
        'Firebase initialization failed on web. Please check your web configuration.',
      );
    }

    // Continue with app startup even if Firebase fails
    // The app will handle Firebase errors gracefully in the UI
  }

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Trigger app controller initialization early
    ref.watch(appControllerProvider);

    return MaterialApp.router(
      title: 'Record App',
      theme: AppTheme.lightTheme,
      routerConfig: router,
    );
  }
}
