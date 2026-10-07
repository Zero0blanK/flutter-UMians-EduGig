import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/core/constants/firestore_paths.dart';
import 'package:student_freelance_services/core/errors/app_failure.dart';
import 'package:student_freelance_services/features/chat/data/chat_repository.dart';
import 'package:student_freelance_services/features/chat/domain/chat_models.dart';
import 'package:student_freelance_services/features/services/domain/freelance_service.dart';

void main() {
  group('message validation rules', () {
    test('max message length matches repository constant', () {
      expect(ChatRepository.maxMessageLength, 2000);
    });
  });

  group('conversation id determinism', () {
    test('same pair always maps to one conversation regardless of order', () {
      final a = FirestorePaths.conversationIdFor('user-b', 'user-a');
      final b = FirestorePaths.conversationIdFor('user-a', 'user-b');
      expect(a, b);
      expect(a, contains('_'));
    });

    test('self-conversation is still deterministic', () {
      expect(
        FirestorePaths.conversationIdFor('u1', 'u1'),
        FirestorePaths.conversationIdFor('u1', 'u1'),
      );
    });
  });

  group('unread counter targeting', () {
    test('derives the recipient from the deterministic conversation id', () {
      expect(
        ChatRepository.otherParticipantOf('alice-uid_bob-uid', 'alice-uid'),
        'bob-uid',
      );
      expect(
        ChatRepository.otherParticipantOf('alice-uid_bob-uid', 'bob-uid'),
        'alice-uid',
      );
    });

    test('returns null for malformed ids or unknown senders', () {
      expect(ChatRepository.otherParticipantOf('no-separator', 'a'), isNull);
      expect(
        ChatRepository.otherParticipantOf('alice-uid_bob-uid', 'stranger'),
        isNull,
      );
    });

    test('conversation model exposes per-user unread counts safely', () {
      final zero = Conversation(
        id: 'c',
        participantIds: ['a', 'b'],
        lastMessagePreview: '',
        lastMessageSenderId: '',
        lastMessageAt: null,
        createdAt: DateTime(2026),
        unreadCount: const {},
      );
      expect(zero.unreadFor('a'), 0);
    });
  });

  group('service model integrity', () {
    FreelanceService service(Map<String, dynamic> data) =>
        FreelanceService.fromMap('s1', {'sellerId': 'seller', ...data});

    test('unknown status values never surface as published', () {
      expect(service({'status': 'bogus'}).isPublished, isFalse);
      expect(service({'status': null}).isPublished, isFalse);
      expect(service({'status': 'published'}).isPublished, isTrue);
      expect(service({'status': 'draft'}).isPublished, isFalse);
    });

    test('missing numeric fields default safely instead of throwing', () {
      final s = service({});
      expect(s.startingPrice, 0);
      expect(s.deliveryDays, 1);
      expect(s.revisionCount, 0);
    });
  });

  group('AppFailure mapping', () {
    test('Firebase permission errors map to PermissionFailure', () {
      final failure = AppFailure.from(
        FirebaseException(plugin: 'firestore', code: 'permission-denied'),
      );
      expect(failure, isA<PermissionFailure>());
    });

    test('auth failures produce friendly, non-leaky messages', () {
      final failure = AppFailure.from(
        FirebaseAuthException(code: 'wrong-password'),
      );
      expect(failure.message, contains('Incorrect email or password'));
      // The raw error code must not leak into the user-facing message.
      expect(failure.message.contains('wrong-password'), isFalse);
    });

    test('unknown errors never expose internals to users', () {
      const failure = UnknownFailure('secret-internal-code');
      expect(failure.toString(), isNot(contains('secret')));
    });
  });
}
