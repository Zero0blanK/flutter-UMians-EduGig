import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/widgets/academic_fields.dart';
import '../../auth/presentation/widgets/birth_date_field.dart';

/// The profile form on a page of its own, grouped the way a student thinks
/// about it: who they are, where they study, what they can do. It was a
/// five-field dialog; the course pickers alone did not fit.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _bio;
  late final TextEditingController _skills;
  String? _collegeId;
  String? _program;
  DateTime? _birthDate;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = context.read<AuthController>().profile;
    _name = TextEditingController(text: profile?.displayName ?? '');
    _bio = TextEditingController(text: profile?.bio ?? '');
    _skills = TextEditingController(
      text: (profile?.skills ?? const <String>[]).join(', '),
    );
    _collegeId = profile?.collegeId;
    _program = profile?.program;
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _skills.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final auth = context.read<AuthController>();
    try {
      await auth.updateProfile(
        displayName: _name.text,
        bio: _bio.text,
        skills: _skills.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .take(10)
            .toList(),
        collegeId: _collegeId,
        program: _program,
        birthDate: _birthDate,
      );
      if (mounted) Navigator.of(context).pop();
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<AuthController>().profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ContentWidth(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SectionHeader(
                'About you',
                padding: EdgeInsets.fromLTRB(0, 8, 0, 10),
              ),
              LilyPanel(
                child: Column(
                  children: [
                    TextFormField(
                      controller: _name,
                      maxLength: 60,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        helperText: 'How classmates see you across the app.',
                      ),
                      validator: (value) =>
                          value != null && value.trim().isNotEmpty
                          ? null
                          : 'Required',
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _bio,
                      maxLength: 500,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Bio',
                        hintText:
                            'What you do, what you are good at, how you work.',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SectionHeader('Where you study'),
              LilyPanel(
                child: AcademicFields(
                  collegeId: _collegeId,
                  program: _program,
                  onChanged: (nextCollege, nextProgram) => setState(() {
                    _collegeId = nextCollege;
                    _program = nextProgram;
                  }),
                ),
              ),
              const SectionHeader('Skills'),
              LilyPanel(
                child: TextFormField(
                  controller: _skills,
                  decoration: const InputDecoration(
                    labelText: 'Skills',
                    helperText: 'Comma-separated, up to ten. They show on your profile.',
                    hintText: 'Figma, Flutter, copywriting',
                  ),
                ),
              ),
              // Accounts from before the field existed add it here, once.
              if (profile?.birthDate == null) ...[
                const SectionHeader(
                  'Birth date',
                  subtitle: 'Set once. Needed to sell and to request payouts.',
                ),
                LilyPanel(
                  child: BirthDateField(
                    value: _birthDate,
                    required: false,
                    onChanged: (date) => setState(() => _birthDate = date),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save changes'),
              ),
              const SizedBox(height: 8),
              Text(
                'Your email and student number come from your UM Google '
                'account and cannot be changed here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
