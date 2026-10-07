import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/content_width.dart';
import '../presentation/auth_controller.dart';
import 'widgets/academic_fields.dart';
import 'widgets/birth_date_field.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String? _collegeId;
  String? _program;
  DateTime? _birthDate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _birthDate = context.read<AuthController>().profile?.birthDate;
  }

  Future<void> _continue() async {
    final college = _collegeId;
    final program = _program;
    final birthDate = _birthDate;
    if (college == null || program == null || birthDate == null || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<AuthController>().completeOnboarding(
        collegeId: college,
        program: program,
        birthDate: birthDate,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save your academic details. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Complete your profile')),
      body: Center(
        child: ContentWidth(
          maxWidth: 520,
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              Text(
                'What do you study?',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Your Google name, school email, and profile photo are already '
                'filled in. Add your birth date and study details to finish setup.',
              ),
              const SizedBox(height: 24),
              AcademicFields(
                collegeId: _collegeId,
                program: _program,
                onChanged: (collegeId, program) => setState(() {
                  _collegeId = collegeId;
                  _program = program;
                }),
              ),
              const SizedBox(height: 16),
              BirthDateField(
                value: _birthDate,
                onChanged: (date) => setState(() => _birthDate = date),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed:
                    _collegeId != null &&
                        _program != null &&
                        _birthDate != null &&
                        !_saving
                    ? _continue
                    : null,
                child: Text(_saving ? 'Saving…' : 'Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
