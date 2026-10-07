import 'package:cloud_firestore/cloud_firestore.dart';

import '../../features/admin/domain/admin_access.dart';
import '../constants/firestore_paths.dart';

/// The runtime switches staff manage: `settings/platform` and `categories`.
///
/// Read-only for the app. Staff write them from the console through
/// `AdminRepository`; the rules gate those writes on `settings.manage` and
/// `categories.manage`. Both streams are held once at the root and shared,
/// so a banner and a category filter cost one listener each, not one per
/// screen.
class PlatformSettingsRepository {
  PlatformSettingsRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Stream<PlatformSettings> watch() {
    return _firestore
        .doc(FirestorePaths.platformSettings)
        .snapshots()
        .map(
          (snapshot) => snapshot.exists
              ? PlatformSettings.fromFirestore(snapshot)
              : PlatformSettings.none,
        );
  }

  /// The categories a student can pick from or filter by: the built-in list
  /// with staff entries merged on top (an entry with the same id overrides
  /// the label; a retired one hides it; a new id is added), ordered by
  /// `sortOrder`.
  Stream<List<({String id, String label})>> watchCategories() {
    return _firestore
        .collection(FirestorePaths.categories)
        .orderBy('sortOrder')
        .snapshots()
        .map((snapshot) {
          final staff = snapshot.docs.map(Category.fromFirestore).toList();
          return mergeCategories(staff);
        })
        .handleError((_) => mergeCategories(const []));
  }

  static List<({String id, String label})> mergeCategories(
    List<Category> staff,
  ) {
    final overrides = {for (final c in staff) c.id: c};
    final merged = <({String id, String label, int order})>[];
    for (final (index, builtIn) in kServiceCategories.indexed) {
      final override = overrides[builtIn.id];
      if (override == null) {
        merged.add((id: builtIn.id, label: builtIn.label, order: index));
      } else if (override.active) {
        merged.add((
          id: builtIn.id,
          label: override.label,
          order: override.sortOrder,
        ));
      }
    }
    for (final c in staff) {
      if (c.active && !kServiceCategories.any((b) => b.id == c.id)) {
        merged.add((id: c.id, label: c.label, order: c.sortOrder));
      }
    }
    merged.sort((a, b) => a.order.compareTo(b.order));
    return [for (final m in merged) (id: m.id, label: m.label)];
  }
}
