# Contributing to PromptPad

Thanks for your interest in contributing!

## Development Setup

```bash
git clone https://github.com/Yukk1No/promptpad.git
cd promptpad
flutter pub get
flutter run
```

## Before Submitting a PR

1. Run `flutter analyze` — no lint warnings
2. Run `flutter test` — all tests pass
3. Test on at least one platform (iOS or Android)

## Code Style

- Follow [flutter_lints](https://pub.dev/packages/flutter_lints) rules (configured in `analysis_options.yaml`)
- Prefer `const` constructors and declarations

## Pull Request Guidelines

- Create a feature branch from `main`
- Keep PRs focused — one feature or fix per PR
- Write a clear description of what changed and why

## Reporting Issues

- Include device/OS version and Flutter version (`flutter doctor`)
- Steps to reproduce
- Expected vs. actual behavior

## Architecture

See [CLAUDE.md](CLAUDE.md) for a detailed architecture overview.
