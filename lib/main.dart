import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import 'config/app_theme.dart';
import 'config/router.dart';
import 'firebase_options.dart';
import 'controllers/app_controller.dart';
import 'services/sheet_outbox.dart';
import 'widgets/splash_overlay.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Keep everything the app has downloaded on the device (no size limit),
    // so admin screens open from the cache and only fetch what changed
    // (see services/data_sync.dart).
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    // Sheets saved on this tablet: retry uploads now and on every resume.
    SheetOutbox.instance.start();
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
    // Continue with app startup even if Firebase fails
    // The app will handle Firebase errors gracefully in the UI
  }

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  /// The launch splash covers the first screens (login / redirect to home)
  /// on a cold start, then removes itself.
  bool _splash = true;

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // Trigger app controller initialization early
    ref.watch(appControllerProvider);

    return MaterialApp.router(
      title: 'Camacho Daily Log',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: router,
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          if (_splash)
            Positioned.fill(
              child: SplashOverlay(onFinished: () => setState(() => _splash = false)),
            ),
        ],
      ),
    );
  }
}
