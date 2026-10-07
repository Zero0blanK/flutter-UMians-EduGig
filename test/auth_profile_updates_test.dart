import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/auth/data/auth_repository.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';
import 'package:student_freelance_services/features/auth/presentation/auth_controller.dart';

UserProfile _profile({bool pro = false}) => UserProfile(
  uid: 'student',
  displayName: 'Student',
  bio: '',
  skills: const [],
  createdAt: DateTime(2026),
  proUntil: pro ? DateTime.now().add(const Duration(days: 30)) : null,
);

class _User extends Fake implements User {
  @override
  String get uid => 'student';
}

class _Repository extends Fake implements AuthRepository {
  final authChanges = StreamController<User?>();
  final profiles = StreamController<UserProfile>();
  User? user;
  @override
  User? get currentUser => user;
  @override
  Stream<User?> get authStateChanges => authChanges.stream;
  @override
  Future<UserProfile> ensureProfile(User user) async => _profile();
  @override
  Stream<UserProfile> watchProfile(String uid) => profiles.stream;
}

void main() {
  test(
    'subscription changes refresh the cached profile without signing in again',
    () async {
      final repository = _Repository();
      final auth = AuthController(repository)..init();
      repository.user = _User();
      repository.authChanges.add(repository.user);
      await Future<void>.delayed(Duration.zero);
      expect(auth.profile?.isPro, isFalse);
      repository.profiles.add(_profile(pro: true));
      await Future<void>.delayed(Duration.zero);
      expect(auth.profile?.isPro, isTrue);
      repository.user = null;
      repository.authChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      repository.profiles.add(_profile(pro: true));
      await Future<void>.delayed(Duration.zero);
      expect(auth.profile, isNull);
      auth.dispose();
      await repository.authChanges.close();
      await repository.profiles.close();
    },
  );
}
