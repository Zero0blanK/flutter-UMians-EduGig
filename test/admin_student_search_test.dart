import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:student_freelance_services/features/admin/data/admin_repository.dart';
import 'package:student_freelance_services/features/admin/presentation/admin_management.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';

class _Admin extends Fake implements AdminRepository {
  final queries = <String>[];

  @override
  Stream<List<UserProfile>> watchUsers({String query = '', int limit = 50}) {
    queries.add(query);
    return Stream.value([]);
  }
}

Future<void> _pump(WidgetTester tester, _Admin repository) async {
  await tester.pumpWidget(
    Provider<AdminRepository>.value(
      value: repository,
      child: const MaterialApp(
        home: Scaffold(
          body: UsersTab(canManageUsers: true, canModerateListings: true),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing searches without Enter and cancels earlier keystrokes', (
    tester,
  ) async {
    final repository = _Admin();
    await _pump(tester, repository);
    await tester.enterText(find.byType(TextField), 'i');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), '  IVAN  ');
    await tester.pump(const Duration(milliseconds: 299));
    expect(repository.queries, ['']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.queries, ['', 'ivan']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter searches immediately without a second debounced query', (
    tester,
  ) async {
    final repository = _Admin();
    await _pump(tester, repository);
    await tester.enterText(find.byType(TextField), 'Cruz');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(repository.queries, ['', 'cruz']);
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.queries, ['', 'cruz']);
  });

  testWidgets('clear restores default list and cancels pending search', (
    tester,
  ) async {
    final repository = _Admin();
    await _pump(tester, repository);
    await tester.enterText(find.byType(TextField), 'ivan');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'maya');
    await tester.pump();
    await tester.tap(find.byTooltip('Clear student search'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.queries, ['', 'ivan', '']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byTooltip('Clear student search'), findsNothing);
  });

  testWidgets('leaving tab cancels pending search', (tester) async {
    final repository = _Admin();
    await _pump(tester, repository);
    await tester.enterText(find.byType(TextField), 'ivan');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.queries, ['']);
    expect(tester.takeException(), isNull);
  });
}
