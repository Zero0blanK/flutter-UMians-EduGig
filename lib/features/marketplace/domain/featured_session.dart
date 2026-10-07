import '../../services/domain/freelance_service.dart';

/// App-lifetime popup state is independent of the 30-minute card selection.
class FeaturedSession {
  static const rotationInterval = Duration(minutes: 30);

  bool showcaseShown = false;
  DateTime? suppressedUntil;

  bool canShowShowcase(DateTime now) =>
      !showcaseShown && !(suppressedUntil?.isAfter(now) ?? false);

  static DateTime nextDay(DateTime now) =>
      DateTime(now.year, now.month, now.day + 1);
  DateTime? selectedAt;
  int seed = 0;
  List<FreelanceService> services = [];
  List<FreelanceService> queued = [];
  Set<String> sellerIds = {};
  int pageIndex = 0;
  bool exhausted = false;

  bool isFresh(DateTime now) =>
      selectedAt != null &&
      !now.isBefore(selectedAt!) &&
      now.difference(selectedAt!) < rotationInterval;
}
