import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Birth date picker used at sign-up and, for accounts that predate the
/// field, in the profile editor.
///
/// Selling and payouts are open to adults only; buying is open to anyone
/// signed in. The date is set once and never editable afterwards (rules pin
/// it), which is why the helper text says so before the student commits.
class BirthDateField extends StatelessWidget {
  const BirthDateField({
    super.key,
    required this.value,
    required this.onChanged,
    this.required = true,
  });

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool required;

  /// The youngest anyone may register (13, the usual floor for an account)
  /// and the oldest plausible date.
  static DateTime get latest =>
      DateTime.now().subtract(const Duration(days: 13 * 365));
  static DateTime get earliest =>
      DateTime.now().subtract(const Duration(days: 100 * 365));

  static bool isAdult(DateTime birthDate) {
    final now = DateTime.now();
    final cutoff = DateTime(now.year - 18, now.month, now.day);
    return !birthDate.isAfter(cutoff);
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: value ?? DateTime(latest.year - 5, latest.month, latest.day),
      firstDate: earliest,
      lastDate: latest,
      helpText: 'Your birth date',
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return FormField<DateTime>(
      initialValue: value,
      validator: (_) =>
          required && value == null ? 'Enter your birth date' : null,
      builder: (state) => InputDecorator(
        decoration: InputDecoration(
          labelText: 'Birth date',
          prefixIcon: const Icon(Icons.cake_outlined),
          errorText: state.errorText,
          helperText: value == null
              ? 'Selling and payouts are for students 18 and over. '
                    'Set once; it cannot be changed later.'
              : isAdult(value!)
              ? 'You can buy, sell, and request payouts.'
              : 'Under 18: you can hire, but not sell or receive payouts.',
          helperMaxLines: 3,
        ),
        child: InkWell(
          onTap: () => _pick(context),
          child: Text(
            value == null
                ? 'Tap to choose'
                : DateFormat.yMMMMd().format(value!),
          ),
        ),
      ),
    );
  }
}
