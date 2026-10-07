/// Colleges and degree programmes offered at the university.
///
/// A closed list rather than free text: it keeps profiles comparable, makes
/// "who else is in my college" a query rather than a guess, and stops a
/// hundred spellings of "BSIT" accumulating in the database. Security rules
/// validate the college id against this list, so adding a college here means
/// adding it there too.
library;

class College {
  const College({
    required this.id,
    required this.name,
    required this.short,
    required this.programs,
  });

  final String id;
  final String name;

  /// The abbreviation students actually use out loud.
  final String short;

  final List<String> programs;
}

const List<College> kColleges = [
  College(
    id: 'cce',
    name: 'College of Computing Education',
    short: 'CCE',
    programs: [
      'BS Computer Science',
      'BS Information Technology',
      'BS Information Systems',
      'BS Entertainment and Multimedia Computing',
    ],
  ),
  College(
    id: 'case',
    name: 'College of Arts and Sciences Education',
    short: 'CASE',
    programs: [
      'AB Communication',
      'AB English',
      'AB Political Science',
      'BS Biology',
      'BS Psychology',
      'BS Mathematics',
      'BS Social Work',
    ],
  ),
  College(
    id: 'cbae',
    name: 'College of Business Administration Education',
    short: 'CBAE',
    programs: [
      'BS Business Administration',
      'BS Entrepreneurship',
      'BS Real Estate Management',
      'BS Legal Management',
    ],
  ),
  College(
    id: 'cae',
    name: 'College of Accounting Education',
    short: 'CAE',
    programs: [
      'BS Accountancy',
      'BS Management Accounting',
      'BS Accounting Information System',
    ],
  ),
  College(
    id: 'cee',
    name: 'College of Engineering Education',
    short: 'CEE',
    programs: [
      'BS Civil Engineering',
      'BS Computer Engineering',
      'BS Electrical Engineering',
      'BS Electronics Engineering',
      'BS Mechanical Engineering',
    ],
  ),
  College(
    id: 'cte',
    name: 'College of Teacher Education',
    short: 'CTE',
    programs: [
      'BS Elementary Education',
      'BS Secondary Education',
      'BS Physical Education',
    ],
  ),
  College(
    id: 'chse',
    name: 'College of Health Sciences Education',
    short: 'CHSE',
    programs: [
      'BS Nursing',
      'BS Pharmacy',
      'BS Medical Technology',
      'BS Radiologic Technology',
    ],
  ),
];

/// The college with [id], or null when unset or unrecognised.
College? collegeById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final college in kColleges) {
    if (college.id == id) return college;
  }
  return null;
}

/// Every valid college id, for validation and for mirroring into rules.
List<String> get kCollegeIds => [for (final c in kColleges) c.id];

/// Programmes offered by [collegeId]; empty when the college is unknown.
List<String> programsFor(String? collegeId) =>
    collegeById(collegeId)?.programs ?? const [];

/// "BS Computer Science · CCE", or just one part when the other is missing.
String academicSummary({String? collegeId, String? program}) {
  final college = collegeById(collegeId);
  final parts = <String>[
    if (program != null && program.isNotEmpty) program,
    if (college != null) college.short,
  ];
  return parts.join(' · ');
}
