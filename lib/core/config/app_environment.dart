/// Which Firebase the build talks to, chosen at compile time:
///
/// ```sh
/// flutter run                                        # production (default)
/// flutter run --dart-define=APP_ENV=development      # real project + demo sign-in
/// flutter run --dart-define=APP_ENV=emulator         # local emulators
/// ```
///
/// Production and development are the same Firebase project until a separate
/// development project exists; the difference is that development compiles
/// in the selector for the seeded demo students (`tools/seed`), which
/// a production build never renders. Emulator points Firestore and Auth at
/// the local emulators (`firebase emulators:start`) for the UI smoke test
/// and rules work.
enum AppEnvironment {
  production,
  development,
  emulator;

  /// Whether Firestore and Auth are redirected to the local emulators.
  bool get usesEmulator => this == emulator;

  /// Whether the login screen offers the seeded demo accounts.
  bool get demoLogin => this != production;

  String get label => switch (this) {
    production => 'Production',
    development => 'Development',
    emulator => 'Emulator',
  };
}

const _appEnvName = String.fromEnvironment(
  'APP_ENV',
  defaultValue: 'production',
);

/// The environment this build was compiled for. A misspelt `APP_ENV` is
/// refused at startup by [checkAppEnvironment] rather than silently becoming
/// production.
const kAppEnvironment = _appEnvName == 'emulator'
    ? AppEnvironment.emulator
    : _appEnvName == 'development'
    ? AppEnvironment.development
    : AppEnvironment.production;

/// Throws when `APP_ENV` is set to something that is not an environment.
void checkAppEnvironment() {
  const known = ['production', 'development', 'emulator'];
  if (!known.contains(_appEnvName)) {
    throw StateError(
      'APP_ENV="$_appEnvName" is not one of ${known.join(', ')}.',
    );
  }
}

/// Emulator host for [AppEnvironment.emulator]. `localhost` resolves to the
/// device itself on an Android emulator, where the host machine is reachable
/// at 10.0.2.2 instead: `--dart-define=EMULATOR_HOST=10.0.2.2`.
const kEmulatorHost = String.fromEnvironment(
  'EMULATOR_HOST',
  defaultValue: 'localhost',
);
