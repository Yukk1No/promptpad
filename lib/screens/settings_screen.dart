import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import '../services/debug_log.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _localeKey = 'speech_locale';
  static const _onDeviceKey = 'on_device';
  static const _algorithmKey = 'tracking_algorithm';
  static const _fontSizeKey = 'default_font_size';

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
  String _algorithm = 'classic';
  double _fontSize = 42;
  bool _loaded = false;
  String _appVersion = '';
  bool _debugMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _locale = prefs.getString(_localeKey) ?? 'en-US';
      _onDevice = prefs.getBool(_onDeviceKey) ?? true;
      _algorithm = prefs.getString(_algorithmKey) ?? 'classic';
      _fontSize = prefs.getDouble(_fontSizeKey) ?? 42;
      _appVersion = info.version;
      _debugMode = DebugLog.enabled;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, _locale);
    await prefs.setBool(_onDeviceKey, _onDevice);
    await prefs.setString(_algorithmKey, _algorithm);
    await prefs.setDouble(_fontSizeKey, _fontSize);
  }

  Future<void> _exportCalibrationLog() async {
    if (DebugLog.bufferedLineCount == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Log is empty — start a teleprompter session with debug mode '
            'on, talk for 60–90s with 2–3 silence pauses, then come back.',
          ),
        ),
      );
      return;
    }
    try {
      final path = await DebugLog.writeToTempFile();
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'PromptPad calibration log',
        text: 'PromptPad calibration log — '
            '${DebugLog.bufferedLineCount} events. '
            'Pipe through benchmark/cadence/calibrate.py.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
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

                // Tracking algorithm
                const Text(
                  'Tracking',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _algorithm,
                  decoration: InputDecoration(
                    labelText: 'Tracking Algorithm',
                    filled: true,
                    fillColor: const Color(0xFF1A1A1A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'classic',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Classic'),
                          Text(
                            'Simple dual-strategy matching. Fast, lower resource usage.',
                            style: TextStyle(fontSize: 11, color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'advanced',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Advanced (Beta)'),
                          Text(
                            'Beam search with drift recovery. More robust, slightly higher resource usage.',
                            style: TextStyle(fontSize: 11, color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'v5',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Smart Recovery (V5)'),
                          Text(
                            'Discrimination-gated recovery. 2–5× more accurate than Advanced under noise; '
                            'commits a recovery jump only when the matched sentence is clearly the best fit.',
                            style: TextStyle(fontSize: 11, color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _algorithm = value);
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
                const SizedBox(height: 24),

                // Default font size
                const Text(
                  'Display',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Default Font Size'),
                    const Spacer(),
                    Text(
                      '${_fontSize.round()}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _fontSize,
                  min: 28,
                  max: 56,
                  divisions: 7,
                  label: '${_fontSize.round()}',
                  onChanged: (value) {
                    setState(() => _fontSize = value);
                    _save();
                  },
                ),
                const Text(
                  'Initial font size when entering the teleprompter. '
                  'You can still adjust it during playback.',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
                const SizedBox(height: 32),

                // Debug — calibration log capture for matcher tuning.
                // Hidden footprint: just a toggle until enabled, so it
                // stays out of regular users' way.
                const Text(
                  'Debug',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  title: const Text('Debug mode'),
                  subtitle: const Text(
                    'Capture speech-recognition cadence + confidence into '
                    'an in-memory log. Used for matcher calibration; '
                    'leave off for normal use.',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                  value: _debugMode,
                  onChanged: (value) async {
                    await DebugLog.setEnabled(value);
                    if (!mounted) return;
                    setState(() => _debugMode = value);
                  },
                  contentPadding: EdgeInsets.zero,
                ),
                if (_debugMode) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _exportCalibrationLog,
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: Text(
                              'Export calibration log (${DebugLog.bufferedLineCount} events)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () {
                          DebugLog.clear();
                          if (!mounted) return;
                          setState(() {});
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),

                // About
                const Divider(color: Colors.white12),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline, color: Colors.white54),
                  title: const Text('About PromptPad'),
                  subtitle: Text(
                    'Version $_appVersion',
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                  trailing: const Icon(Icons.open_in_new, size: 18, color: Colors.white38),
                  onTap: () => launchUrl(
                    Uri.parse('https://github.com/Yukk1No/promptpad'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
    );
  }
}
