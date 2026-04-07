import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

class PromptPadApp extends StatelessWidget {
  const PromptPadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PromptPad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF03DAC6),
          surface: Color(0xFF121212),
        ),
        fontFamily: '.SF Pro Text',
      ),
      home: const HomeScreen(),
    );
  }
}
