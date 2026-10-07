import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/services/data/service_repository.dart';

/// The Firestore emulator does not enforce composite indexes, so a query
/// shape nobody added to `firestore.indexes.json` passes every local suite
/// and fails in production. This test is the only local check.
void main() {
  late Set<String> deployed;

  String key(List<IndexField> shape) => shape.join(', ');

  setUpAll(() {
    final file = File('firestore.indexes.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final indexes = json['indexes'] as List<Object?>;
    deployed = {
      for (final entry in indexes.cast<Map<String, Object?>>())
        if (entry['collectionGroup'] == 'services')
          key([
            for (final field
                in (entry['fields'] as List<Object?>)
                    .cast<Map<String, Object?>>())
              IndexField(
                field['fieldPath'] as String,
                (field['order'] ?? field['arrayConfig']) as String,
              ),
          ]),
    };
  });

  test('every marketplace query shape has a deployed composite index', () {
    final shapes = ServiceRepository.indexShapes();
    // 2 category × 2 search × 3 sorts; featured uses a projection document.
    expect(shapes, hasLength(2 * 2 * ServiceSort.values.length));

    final missing = shapes.map(key).where((s) => !deployed.contains(s));
    expect(
      missing,
      isEmpty,
      reason:
          'add these to firestore.indexes.json and deploy before shipping:\n'
          '${missing.join('\n')}',
    );
  });

  test('a shape is only matched by an index in the same field order', () {
    // Sanity check on the comparison itself: swapping the sort direction
    // must not be accepted, since an ascending index cannot serve a
    // descending orderBy.
    const shape = [
      IndexField('status', 'ASCENDING'),
      IndexField('createdAt', 'ASCENDING'),
    ];
    expect(deployed.contains(key(shape)), isFalse);
  });
}
