import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'teleprompter_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  List<String> _scriptHistory = [];
  static const _historyKey = 'script_history';
  static const _maxHistory = 5;

  final _sampleScript = '''Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, and dedicated to the proposition that all men are created equal.

Now we are engaged in a great civil war, testing whether that nation, or any nation so conceived and so dedicated, can long endure. We are met on a great battle-field of that war. We have come to dedicate a portion of that field, as a final resting place for those who here gave their lives that that nation might live. It is altogether fitting and proper that we should do this.

But, in a larger sense, we can not dedicate — we can not consecrate — we can not hallow — this ground. The brave men, living and dead, who struggled here, have consecrated it, far above our poor power to add or detract.''';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_historyKey) ?? [];
    setState(() {
      _scriptHistory = history;
      if (_scriptHistory.isNotEmpty) {
        _controller.text = _scriptHistory.first;
      }
    });
  }

  Future<void> _saveToHistory(String text) async {
    _scriptHistory.remove(text);
    _scriptHistory.insert(0, text);
    if (_scriptHistory.length > _maxHistory) {
      _scriptHistory = _scriptHistory.sublist(0, _maxHistory);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, _scriptHistory);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startPrompter() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _saveToHistory(text);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TeleprompterScreen(scriptText: text),
      ),
    );
  }

  void _showHistory() {
    if (_scriptHistory.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Recent Scripts',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              ...List.generate(_scriptHistory.length, (i) {
                final script = _scriptHistory[i];
                final preview = script.length > 80
                    ? '${script.substring(0, 80)}...'
                    : script;
                return ListTile(
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.white12,
                    child: Text('${i + 1}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
                  ),
                  title: Text(
                    preview.replaceAll('\n', ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  onTap: () {
                    _controller.text = script;
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PromptPad',
                            style: Theme.of(context)
                                .textTheme
                                .headlineLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Paste your script, then speak naturally.',
                            style:
                                Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Colors.white54,
                                    ),
                          ),
                        ],
                      ),
                    ),
                    if (_scriptHistory.isNotEmpty)
                      IconButton(
                        onPressed: _showHistory,
                        icon: const Icon(Icons.history_rounded),
                        tooltip: 'Recent scripts',
                        color: Colors.white54,
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Script input area
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 16, height: 1.6),
                    decoration: InputDecoration(
                      hintText: 'Paste your script here...',
                      hintStyle: const TextStyle(color: Colors.white24),
                      filled: true,
                      fillColor: const Color(0xFF1A1A1A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(20),
                    ),
                  ),
                ),
              ),

              // Bottom action bar
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => _controller.text = _sampleScript,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                        side: BorderSide(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withAlpha(128),
                        ),
                      ),
                      child: const Text('Sample'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _startPrompter,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Start Prompter'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
