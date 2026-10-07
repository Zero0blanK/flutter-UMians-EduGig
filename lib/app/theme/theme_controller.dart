import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the light/dark preference and remembers it across launches.
///
/// The app shipped with a [ThemeData] for both brightnesses and no way to
/// choose between them, so the dark theme only ever appeared if the whole
/// device was already dark. This is that missing control.
///
/// [ThemeMode.system] stays the default: a phone that switches itself at
/// sunset should carry the app with it unless the student has said otherwise.
/// Only an explicit choice is written to disk.
class ThemeController extends ChangeNotifier {
  ThemeController();

  static const _key = 'theme_mode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// Reads the stored preference. Safe to call without awaiting: the app
  /// starts on [ThemeMode.system] and repaints once if the stored value
  /// differs, which is a frame or two on a cold start.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_key);
      final restored = _parse(stored);
      if (restored == _mode) return;
      _mode = restored;
      notifyListeners();
    } catch (_) {
      // A preference that cannot be read is not worth failing a launch over;
      // the system default is a reasonable place to land.
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode.name);
    } catch (_) {
      // The choice still applies for this session.
    }
  }

  static ThemeMode _parse(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

/// Labels and icons for the three choices, kept next to the controller so the
/// picker and any future shortcut cannot drift apart.
extension ThemeModeDisplay on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  IconData get icon => switch (this) {
    ThemeMode.system => Icons.brightness_auto_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };
}
