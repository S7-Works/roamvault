// TODO(slint): Replace Flutter widget tree with Slint UI once the
// slint-flutter plugin reaches production readiness.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/backup_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyIdCtrl;
  late final TextEditingController _appKeyCtrl;
  late final TextEditingController _bucketCtrl;

  // Backup schedule options in hours
  static const _scheduleOptions = [6, 12, 24, 48, 168]; // 168 = 1 week
  static const _scheduleLabels = ['6 h', '12 h', '24 h', '48 h', '1 week'];

  static const _expiryOptions = [30, 60, 90, 180, 365];
  static const _expiryLabels = [
    '30 days',
    '60 days',
    '90 days',
    '180 days',
    '1 year',
  ];

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _urlCtrl = TextEditingController(text: s.backendUrl);
    _keyIdCtrl = TextEditingController(text: s.b2KeyId);
    _appKeyCtrl = TextEditingController(text: s.b2AppKey);
    _bucketCtrl = TextEditingController(text: s.b2BucketId);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyIdCtrl.dispose();
    _appKeyCtrl.dispose();
    _bucketCtrl.dispose();
    super.dispose();
  }

  void _save() {
    context.read<AppSettings>().update(
          url: _urlCtrl.text.trim(),
          keyId: _keyIdCtrl.text.trim(),
          appKey: _appKeyCtrl.text.trim(),
          bucketId: _bucketCtrl.text.trim(),
        );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Backend ────────────────────────────────────────────────────
          _SectionHeader('Backend'),
          _SettingsTextField(
            label: 'Backend URL',
            hint: 'http://your-server:8080',
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
          ),

          const SizedBox(height: 24),

          // ── Backblaze B2 ───────────────────────────────────────────────
          _SectionHeader('Backblaze B2'),
          _SettingsTextField(
            label: 'Key ID',
            hint: 'xxxxxxxxxxxxxxxxxxxxxxx',
            controller: _keyIdCtrl,
          ),
          const SizedBox(height: 12),
          _SettingsTextField(
            label: 'Application Key',
            hint: '••••••••••••••••••••••',
            controller: _appKeyCtrl,
            obscureText: true,
          ),
          const SizedBox(height: 12),
          _SettingsTextField(
            label: 'Bucket ID',
            hint: 'xxxxxxxxxxxxxxxxxxxxxxx',
            controller: _bucketCtrl,
          ),

          const SizedBox(height: 24),

          // ── Backup schedule ────────────────────────────────────────────
          _SectionHeader('Backup Schedule'),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DropdownButtonFormField<int>(
                value: settings.backupScheduleHours,
                decoration: const InputDecoration(
                  labelText: 'Auto-backup every',
                  border: InputBorder.none,
                ),
                items: List.generate(_scheduleOptions.length, (i) {
                  return DropdownMenuItem(
                    value: _scheduleOptions[i],
                    child: Text(_scheduleLabels[i]),
                  );
                }),
                onChanged: (v) {
                  if (v != null) {
                    settings.update(scheduleHours: v);
                  }
                },
              ),
            ),
          ),

          const SizedBox(height: 24),

          // ── Expiry ─────────────────────────────────────────────────────
          _SectionHeader('Media Expiry'),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DropdownButtonFormField<int>(
                value: settings.expiryDays,
                decoration: const InputDecoration(
                  labelText: 'Delete from cloud after',
                  border: InputBorder.none,
                ),
                items: List.generate(_expiryOptions.length, (i) {
                  return DropdownMenuItem(
                    value: _expiryOptions[i],
                    child: Text(_expiryLabels[i]),
                  );
                }),
                onChanged: (v) {
                  if (v != null) settings.update(expiry: v);
                },
              ),
            ),
          ),

          const SizedBox(height: 32),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text('Save Settings'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _SettingsTextField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final bool obscureText;

  const _SettingsTextField({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboardType = TextInputType.text,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscureText,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }
}
