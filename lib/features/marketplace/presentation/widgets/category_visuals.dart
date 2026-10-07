import 'package:flutter/material.dart';

import '../../../../app/theme/app_theme.dart';

/// Categories share a neutral tint; labels and icons provide identification.
({IconData icon, Color tint}) categoryVisualOf(
  String categoryId, {
  Brightness brightness = Brightness.light,
}) => (
  icon: switch (categoryId) {
    'tutoring' => Icons.school_outlined,
    'design' => Icons.brush_outlined,
    'writing' => Icons.edit_note_outlined,
    'programming' => Icons.terminal_outlined,
    'video' => Icons.movie_outlined,
    'photography' => Icons.photo_camera_outlined,
    'music' => Icons.music_note_outlined,
    _ => Icons.category_outlined,
  },
  tint: AppTheme.categoryTint(brightness),
);
