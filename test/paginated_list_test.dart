import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/core/errors/app_failure.dart';
import 'package:student_freelance_services/core/widgets/paginated_list.dart';

void main() {
  testWidgets('scrolling expands the live window and stops at the end', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final limits = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginatedList<int>(
            pageSize: 3,
            emptyMessage: 'Empty',
            load: (limit) {
              limits.add(limit);
              return Stream.value(
                List.generate(min(limit, 8), (index) => index),
              );
            },
            itemBuilder: (_, item) =>
                SizedBox(height: 100, child: Text('Row $item')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(limits, [4]);
    for (var index = 0; index < 5; index++) {
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    expect(limits, [4, 7, 10]);
    expect(find.text('Row 7'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed next page keeps rows and retry uses the same window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final limits = <int>[];
    var fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginatedList<int>(
            pageSize: 3,
            emptyMessage: 'Empty',
            load: (limit) {
              limits.add(limit);
              if (limit > 4 && fail) {
                return Stream.error(const NetworkFailure());
              }
              return Stream.value(
                List.generate(min(limit, 6), (index) => index),
              );
            },
            itemBuilder: (_, item) =>
                SizedBox(height: 100, child: Text('Row $item')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(find.text('Row 2'), findsOneWidget);
    expect(find.textContaining('Retry'), findsOneWidget);
    fail = false;
    await tester.tap(find.textContaining('Retry'));
    await tester.pumpAndSettle();
    expect(limits, [4, 7, 7]);
    expect(find.textContaining('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
