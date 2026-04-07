import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _localeKey = 'speech_locale';
  static const _onDeviceKey = 'on_device';

  static const _supportedLocales = [
    ('en-US', 'English (US)'),
    ('en-GB', 'English (UK)'),
    ('zh-CN', 'Chinese (Simplified)'),
    ('zh-TW', 'Chinese (Traditional)'),
    ('ja-JP', 'Japanese'),
    ('ko-KR', 'Korean'),
    ('es-ES', 'Spanish'),
    ('fr-FR', 'French'),
    ('de-DE', 'German'),
    ('pt-BR', 'Portuguese (Brazil)'),
  ];

  String _locale = 'en-US';
  bool _onDevice = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _locale = prefs.getString(_localeKey) ?? 'en-US';
      _onDevice = prefs.getBool(_onDeviceKey) ?? true;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, _locale);
    await prefs.setBool(_onDeviceKey, _onDevice);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                // Speech locale
                const Text(
                  'Speech Recognition',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _locale,
                  decoration: InputDecoration(
                    labelText: 'Language / Locale',
                    filled: true,
                    fillColor: const Color(0xFF1A1A1A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: _supportedLocales.map((entry) {
                    final (code, label) = entry;
                    return DropdownMenuItem(
                      value: code,
                      child: Text(label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _locale = value);
                    _save();
                  },
                ),
                const SizedBox(height: 24),

                // On-device toggle
                SwitchListTile(
                  title: const Text('On-device recognition'),
                  subtitle: const Text(
                    'Use on-device models when available. '
                    'Faster and works offline, but may be less accurate.',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                  value: _onDevice,
                  onChanged: (value) {
                    setState(() => _onDevice = value);
                    _save();
                  },
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
    );
  }
}
