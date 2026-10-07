import 'package:flutter/material.dart';

import '../../../../core/constants/academics.dart';

/// College and programme pickers, used at sign-up and when editing a profile.
///
/// The programme list depends on the college, so the two are one widget rather
/// than two loose dropdowns that can disagree — choosing a different college
/// clears a programme that no longer belongs to it, instead of leaving a
/// student filed under "CCE, BS Nursing".
class AcademicFields extends StatelessWidget {
  const AcademicFields({
    super.key,
    required this.collegeId,
    required this.program,
    required this.onChanged,
    this.optionalHint,
  });

  final String? collegeId;
  final String? program;
  final void Function(String? collegeId, String? program) onChanged;

  /// Shown under the fields when they may be skipped.
  final String? optionalHint;

  @override
  Widget build(BuildContext context) {
    final programs = programsFor(collegeId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: collegeId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'College'),
          items: [
            for (final college in kColleges)
              DropdownMenuItem(
                value: college.id,
                child: Text(
                  '${college.short} — ${college.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            // Dropping the programme is deliberate: keeping it would let a
            // stale pairing survive a college change.
            onChanged(value, null);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: programs.contains(program) ? program : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Program',
            hintText: collegeId == null ? 'Choose a college first' : null,
          ),
          items: [
            for (final option in programs)
              DropdownMenuItem(
                value: option,
                child: Text(option, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: programs.isEmpty
              ? null
              : (value) => onChanged(collegeId, value),
        ),
        if (optionalHint != null) ...[
          const SizedBox(height: 8),
          Text(optionalHint!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
