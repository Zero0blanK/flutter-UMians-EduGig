import '../../../core/backend/backend_client.dart';

class PeopleSearchResult {
  const PeopleSearchResult({
    required this.uid,
    required this.displayName,
    required this.photoUrl,
    required this.program,
    required this.department,
    required this.joinedAt,
    required this.publicRole,
  });

  final String uid;
  final String displayName;
  final String? photoUrl;
  final String? program;
  final String? department;
  final DateTime? joinedAt;
  final String? publicRole;

  factory PeopleSearchResult.fromJson(Map<String, dynamic> json) {
    return PeopleSearchResult(
      uid: json['uid'] as String,
      displayName: json['displayName'] as String? ?? 'Student',
      photoUrl: json['photoUrl'] as String?,
      program: json['program'] as String?,
      department: json['department'] as String?,
      joinedAt: DateTime.tryParse(json['joinedAt'] as String? ?? ''),
      publicRole: json['publicRole'] as String?,
    );
  }
}

class PeopleSearchRepository {
  const PeopleSearchRepository(this._backend);

  final BackendClient _backend;

  Future<List<PeopleSearchResult>> search(String query) async {
    final response = await _backend.post(
      '/users/search',
      body: {'query': query},
    );
    final users = response['users'];
    if (users is! List) return const [];
    final unique = <String, PeopleSearchResult>{};
    for (final item in users) {
      if (item is! Map<String, dynamic>) continue;
      final person = PeopleSearchResult.fromJson(item);
      unique.putIfAbsent(person.uid, () => person);
    }
    return unique.values.toList(growable: false);
  }
}
