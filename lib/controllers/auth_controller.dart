import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<User?>>((ref) {
      return AuthController();
    });

class AuthController extends StateNotifier<AsyncValue<User?>> {
  AuthController() : super(const AsyncValue.loading()) {
    _init();
  }

  void _init() {
    try {
      // Check if Firebase is properly initialized
      if (FirebaseAuth.instance == null) {
        print('Firebase Auth not initialized');
        state = AsyncValue.error(
          'Firebase not initialized',
          StackTrace.current,
        );
        return;
      }

      FirebaseAuth.instance.authStateChanges().listen(
        (user) {
          state = AsyncValue.data(user);
        },
        onError: (error) {
          print('Auth state changes error: $error');
          state = AsyncValue.error(error, StackTrace.current);
        },
      );
    } catch (e) {
      print('Error initializing auth controller: $e');
      state = AsyncValue.error(e, StackTrace.current);
    }
  }

  Future<Map<String, dynamic>> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    try {
      // Check if Firebase is properly initialized
      if (FirebaseAuth.instance == null) {
        throw Exception('Firebase not initialized');
      }

      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);

      if (userCredential.user == null) {
        throw Exception('Failed to sign in');
      }

      // Get user role from Firestore
      final userDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userCredential.user!.uid)
              .get();

      if (!userDoc.exists) {
        throw Exception('User profile not found');
      }

      final userData = userDoc.data() as Map<String, dynamic>;
      print('User data from Firestore: $userData'); // Debug print

      final role = userData['role'] as String? ?? 'user';
      print('Assigned role: $role'); // Debug print

      return {'user': userCredential.user, 'role': role};
    } on FirebaseAuthException catch (e) {
      String message;
      switch (e.code) {
        case 'user-not-found':
          message = 'No user found with this email';
          break;
        case 'wrong-password':
          message = 'Wrong password provided';
          break;
        case 'invalid-email':
          message = 'Invalid email address';
          break;
        case 'user-disabled':
          message = 'This account has been disabled';
          break;
        default:
          message = 'An error occurred during sign in';
      }
      throw Exception(message);
    } catch (e) {
      throw Exception('An error occurred during sign in: $e');
    }
  }

  Future<void> signOut() async {
    try {
      if (FirebaseAuth.instance != null) {
        await FirebaseAuth.instance.signOut();
      }
    } catch (e) {
      throw Exception('Failed to sign out: $e');
    }
  }

  bool get isAdmin => state.when(
    data: (user) => user != null,
    loading: () => false,
    error: (_, __) => false,
  );
}
