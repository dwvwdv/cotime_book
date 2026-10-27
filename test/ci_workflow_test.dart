import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `paths:` filter in [workflow], in the order they appear.
List<List<String>> _workflowPaths(String workflow) {
  final lines = File(workflow).readAsLinesSync();
  final lists = <List<String>>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() != 'paths:') continue;
    final paths = <String>[];
    for (final line in lines.skip(i + 1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final match = RegExp(r"^- '([^']+)'$").firstMatch(trimmed);
      if (match == null) break;
      paths.add(match.group(1)!);
    }
    lists.add(paths);
  }
  return lists;
}

/// The `paths:` filter of the pull_request trigger in build-check.yml.
List<String> _buildCheckPaths() {
  final lists = _workflowPaths('.github/workflows/build-check.yml');
  expect(lists, isNotEmpty, reason: 'build-check.yml must filter by paths');
  return lists.first;
}

bool _covered(List<String> filters, String path) =>
    filters.any((filter) => _matches(filter, path));

/// GitHub's glob, reduced to the forms these workflows use: an exact path,
/// `dir/**`, and a `*` within the last segment.
bool _matches(String filter, String path) {
  if (filter == path) return true;
  if (filter.endsWith('/**')) {
    return path.startsWith(filter.substring(0, filter.length - 2));
  }
  if (filter.contains('*')) {
    final pattern = RegExp(
      '^${filter.split('*').map(RegExp.escape).join('[^/]*')}\$',
    );
    return pattern.hasMatch(path);
  }
  return false;
}

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

  // check.js lays the book out in Chromium on two devices (issue #20); unit
  // tests never run a WebView, so this workflow is the only CI that notices
  // the devices' pages drifting apart. It has to run for every source the
  // check reads, on pushes and pull requests alike.
  test('Shared Page Check runs for every source check.js reads', () {
    const workflow = '.github/workflows/shared-page-check.yml';
    final lists = _workflowPaths(workflow);
    expect(lists, hasLength(2), reason: 'push and pull_request filters');
    expect(lists.last, lists.first,
        reason: 'push and pull_request must watch the same paths');
    for (final path in [
      'assets/reader/shared_page.js',
      'assets/fonts/literata/literata-latin-400-normal.woff2',
      'lib/services/shared_page_style.dart',
      'lib/services/txt_book.dart',
      'lib/services/gb18030.dart',
      'lib/providers/reading_preferences_provider.dart',
      'tool/shared_page_check/check.js',
      'tool/shared_page_check/make_txt_book_test.dart',
      'tool/shared_page_check/make_epub.py',
      'tool/shared_page_check/dump_rules_test.dart',
      'pubspec.yaml',
      'pubspec.lock',
      workflow,
    ]) {
      expect(_covered(lists.first, path), isTrue,
          reason: '$path is not in $workflow paths');
    }
    // A change elsewhere in lib/ must not pay for Chromium and the fonts.
    expect(_covered(lists.first, 'lib/services/realtime_service.dart'),
        isFalse);

    final text = File(workflow).readAsStringSync();
    expect(text, contains('workflow_dispatch:'));
    expect(text, contains('node tool/shared_page_check/check.js'));
  });

  // A branch name, PR title or commit message is chosen by whoever pushes;
  // written into a `run:` script as `${{ ... }}` it is run as shell (#46).
  // Such values go in through `env:` and are quoted in the script.
  test('no workflow writes text someone else chose into a shell script', () {
    final untrusted = RegExp(
      r'\$\{\{[^}]*(github\.head_ref|github\.event\.(pull_request|issue|'
      r'comment|review|head_commit|commits))',
    );
    final runKey = RegExp(r'^(\s*)(- )?run:\s*(.*)$');
    final workflows = Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.yml'));
    for (final workflow in workflows) {
      final lines = workflow.readAsLinesSync();
      // The indentation of the `run:` key whose script the line is in.
      int? script;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final indent = line.length - line.trimLeft().length;
        if (script != null && line.trim().isNotEmpty && indent <= script) {
          script = null;
        }
        final run = runKey.firstMatch(line);
        if (run != null) {
          script = run.group(1)!.length;
          if (!untrusted.hasMatch(run.group(3)!)) continue;
        } else if (script == null || !untrusted.hasMatch(line)) {
          continue;
        }
        fail('${workflow.path}:${i + 1} puts an untrusted value in a '
            'script; pass it through env: instead');
      }
    }
  });
}
