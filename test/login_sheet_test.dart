import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/app/theme/app_theme.dart';
import 'package:student_freelance_services/core/config/app_environment.dart';
import 'package:student_freelance_services/features/auth/presentation/login_screen.dart';

void main() {
  testWidgets('login hides demo controls until the sheet is dragged up', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const LoginScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Demo account'), findsNothing);
    expect(find.text('Continue with UM Google'), findsOneWidget);

    final sheet = find.byType(DraggableScrollableSheet);
    final controller = tester
        .widget<DraggableScrollableSheet>(sheet)
        .controller!;
    final bounds = tester.getRect(sheet);
    final top = bounds.bottom - bounds.height * controller.size;
    final collapsedSize = controller.size;
    final header = find.text('Student Freelance\nServices');
    final headerTop = tester.getTopLeft(header).dy;
    await tester.dragFrom(Offset(195, top + 20), const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(
      tester.getTopLeft(header).dy,
      closeTo(headerTop - bounds.height * (controller.size - collapsedSize), 1),
    );
    expect(
      find.text('Demo account'),
      kAppEnvironment.demoLogin ? findsOneWidget : findsNothing,
    );

    controller.jumpTo(
      tester.widget<DraggableScrollableSheet>(sheet).minChildSize,
    );
    await tester.pumpAndSettle();
    expect(find.text('Demo account'), findsNothing);
    expect(tester.getTopLeft(header).dy, closeTo(headerTop, 1));
    expect(tester.takeException(), isNull);
  });
}
