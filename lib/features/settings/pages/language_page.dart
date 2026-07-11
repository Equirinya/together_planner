import 'package:flutter/material.dart';

import 'package:couple_planner/core/language.dart';
import 'package:couple_planner/core/restart_widget.dart';

/// Lets the user follow the device language or override it with any language.
/// App strings stay English for now; the choice is the language sent alongside
/// backend operations.
class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final service = LanguageService.instance;
    final device = languageOptionFor(service.deviceCode);
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? [
            languageOptionFor('en')!,
            ...kLanguages.where((l) => l.code != 'en'),
          ]
        : kLanguages
            .where((l) =>
                l.name.toLowerCase().contains(q) ||
                l.english.toLowerCase().contains(q) ||
                l.code == q)
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Language')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              hintText: 'Search languages',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (q.isEmpty)
                  ListTile(
                    title: const Text('System default'),
                    subtitle: Text(device == null
                        ? service.deviceCode
                        : 'Follows your device (${device.name})'),
                    trailing: service.isFollowingDevice ? const Icon(Icons.check) : null,
                    onTap: () => _select(null),
                  ),
                for (final l in matches)
                  ListTile(
                    title: Text(l.name),
                    subtitle: l.name == l.english ? null : Text(l.english),
                    trailing: service.override == l.code ? const Icon(Icons.check) : null,
                    onTap: () => _select(l.code),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _select(String? code) async {
    await LanguageService.instance.setOverride(code);
    if (!mounted) return;
    Navigator.of(context).pop();
    RestartWidget.restartApp(context);
  }
}
