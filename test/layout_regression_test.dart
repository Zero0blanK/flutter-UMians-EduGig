import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:student_freelance_services/app/theme/app_theme.dart';
import 'package:student_freelance_services/core/widgets/lily.dart';
import 'package:student_freelance_services/features/chat/data/chat_repository.dart';
import 'package:student_freelance_services/features/marketplace/presentation/widgets/service_card.dart';
import 'package:student_freelance_services/features/services/domain/freelance_service.dart';

class _ChatRepository extends Fake implements ChatRepository {
  @override
  Future<PeerSummary> summaryOf(String uid) async => PeerSummary(
    name: uid == 'short' ? 'Ana' : 'A student with a very long display name',
    verified: uid != 'short',
  );

  @override
  Future<String> displayNameOf(String uid) async => (await summaryOf(uid)).name;
}

FreelanceService _service(String seller, int days) => FreelanceService(
  id: seller,
  sellerId: seller,
  title: 'Programming and development support for your final project',
  description: '',
  categoryId: 'programming',
  skills: const [],
  startingPrice: 12345,
  currency: 'PHP',
  deliveryDays: days,
  revisionCount: 1,
  status: ServiceStatus.published,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  ratingSum: 495,
  ratingCount: 100,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double scale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    Provider<ChatRepository>.value(
      value: _ChatRepository(),
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 1200),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('delivery ends at the right inset regardless of seller name', (
    tester,
  ) async {
    await _pump(
      tester,
      Column(
        children: [
          ServiceCard(service: _service('short', 1)),
          ServiceCard(service: _service('long', 30)),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    final cards = find.byType(Card);
    final right = tester.getRect(cards.first).right - 14;
    expect(tester.getRect(find.text('1 day')).right, closeTo(right, 0.1));
    expect(tester.getRect(find.text('30 days')).right, closeTo(right, 0.1));
  });

  for (final width in [320.0, 390.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('listing and badges fit width $width at text scale $scale', (
        tester,
      ) async {
        await _pump(
          tester,
          Column(
            children: [
              ServiceCard(service: _service('long', 30), featured: true),
              const SizedBox(
                width: 160,
                child: StatusPill(
                  label: 'Paid · released to seller',
                  tone: Tone.success,
                  icon: Icons.check,
                ),
              ),
            ],
          ),
          width: width,
          scale: scale,
          dark: scale == 2,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('featured and compact cards fit their marketplace slots', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      await _pump(
        tester,
        Column(
          children: [
            SizedBox(
              width: 300,
              height: 240 * scale,
              child: ServiceCard(
                service: _service('long', 30),
                featured: true,
                margin: EdgeInsets.zero,
              ),
            ),
            SizedBox(
              width: 138,
              height: 220 * scale,
              child: ServiceCard(
                service: _service('long', 30),
                compact: true,
                margin: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        width: 320,
        scale: scale,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('statistics support empty, single, and narrow layouts', (
    tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: [
          StatGrid(tiles: []),
          StatGrid(
            tiles: [StatTile(label: 'One', value: '1')],
          ),
          SizedBox(
            width: 200,
            child: StatGrid(
              tiles: [
                StatTile(label: 'First', value: '1'),
                StatTile(label: 'Second', value: '2'),
              ],
            ),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('Second')).dy,
      greaterThan(tester.getBottomLeft(find.text('First')).dy),
    );
  });
}
