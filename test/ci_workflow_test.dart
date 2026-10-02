import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `paths:` filter of the pull_request trigger in build-check.yml.
List<String> _buildCheckPaths() {
  final lines =
      File('.github/workflows/build-check.yml').readAsLinesSync();
  final start = lines.indexWhere((l) => l.trim() == 'paths:');
  expect(start, isNot(-1), reason: 'build-check.yml must filter by paths');
  final paths = <String>[];
  for (final line in lines.skip(start + 1)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final match = RegExp(r"^- '([^']+)'$").firstMatch(trimmed);
    if (match == null) break;
    paths.add(match.group(1)!);
  }
  return paths;
}

bool _covered(List<String> filters, String path) => filters.any((filter) =>
    filter == path ||
    (filter.endsWith('/**') &&
        path.startsWith(filter.substring(0, filter.length - 2))));

void main() {
  // A PR that only touches an unlisted path never triggers Build Check, and
  // shows up as "no checks" instead of red. assets/ used to be missing, so a
  // change to the shared page script (issue #20) skipped CI entirely.
  test('Build Check runs for every change that reaches the app or its tests',
      () {
    final filters = _buildCheckPaths();
    for (final path in [
      'lib/main.dart',
      'test/widget_test.dart',
      'assets/reader/shared_page.js',
      'android/app/build.gradle',
      'supabase/migrations/x.sql',
      'pubspec.yaml',
      'pubspec.lock',
      'analysis_options.yaml',
      '.github/workflows/release-apk.yml',
    ]) {
      expect(_covered(filters, path), isTrue,
          reason: '$path is not in build-check.yml paths');
    }

    // Every asset bundled into the APK, as declared in pubspec.yaml.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final assets = RegExp(r'^\s+- (assets/\S+)', multiLine: true)
        .allMatches(pubspec)
        .map((m) => m.group(1)!);
    expect(assets, isNotEmpty);
    for (final asset in assets) {
      expect(_covered(filters, asset), isTrue,
          reason: '$asset is bundled but not in build-check.yml paths');
    }
  });

  // A different SDK reports different lints: analyze would be clean in the
  // Claude Code session and red in CI, or the other way round.
  test('every workflow and the session hook use the same Flutter', () {
    final versions = <String, String>{};
    for (final file in Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))) {
      for (final match in RegExp(r"flutter-version:\s*'([^']+)'")
          .allMatches(file.readAsStringSync())) {
        versions[file.path] = match.group(1)!;
      }
    }
    final hook = RegExp(r'^FLUTTER_VERSION="([^"]+)"', multiLine: true)
        .firstMatch(
            File('.claude/hooks/session-start.sh').readAsStringSync());
    expect(hook, isNotNull);
    versions['.claude/hooks/session-start.sh'] = hook!.group(1)!;

    expect(versions.length, greaterThan(1));
    expect(versions.values.toSet(), hasLength(1), reason: '$versions');
  });
}
