import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/projects/project_list.dart';
import 'package:flit/services/paths.dart';
import 'package:flit/features/workspace/project_session.dart' show ProjectKind;

void main() {
  test('scan command is rooted at the quoted projects dir', () {
    final cmd = ProjectList.scanCommand("/home/it's/projects");
    expect(cmd, startsWith("mkdir -p '/home/it'\\''s/projects' && cd "));
    expect(cmd, contains('-maxdepth 1 -type d'));
    expect(cmd, contains('pubspec.yaml'));
    // 最近改动排除构建产物/缓存/版本库, 否则一次 build 就把顺序打乱
    for (final pruned in ['build', '.dart_tool', '.git', '.gradle']) {
      expect(cmd, contains('-name $pruned'));
    }
  });

  test('listing parses kinds and sorts by latest change, then name', () {
    final entries = ProjectList.parseListing(
      'zeta\tdart\t1700000100\n'
          'alpha\tflutter\t1700000200\n'
          'notes\tfolder\t\n'
          'junk line without tabs\n'
          'bogus\tunknown\t1\n'
          'beta\tdart\t1700000100\r\n',
      '/home/projects',
    );
    expect(entries.map((e) => e.name), ['alpha', 'beta', 'zeta', 'notes']);
    expect(entries.first.kind, ProjectKind.flutter);
    expect(entries.first.path, joinPath('/home/projects', 'alpha'));
    expect(
      entries.first.modified,
      DateTime.fromMillisecondsSinceEpoch(1700000200 * 1000),
    );
    expect(entries.last.kind, isNull);
    expect(entries.last.isProject, isFalse);
    expect(entries.last.modified, isNull);
    expect(entries.first.kindLabel, 'Flutter 工程');
    expect(entries.last.kindLabel, '文件夹');
  });

  test('relative time buckets', () {
    final now = DateTime(2026, 10, 27, 12, 0);
    expect(
      relativeTime(now.subtract(const Duration(seconds: 30)), now: now),
      '刚刚',
    );
    expect(
      relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
      '5 分钟前',
    );
    expect(
      relativeTime(now.subtract(const Duration(hours: 3)), now: now),
      '3 小时前',
    );
    expect(
      relativeTime(now.subtract(const Duration(days: 2)), now: now),
      '2 天前',
    );
    expect(relativeTime(DateTime(2026, 1, 5), now: now), '2026-01-05');
  });

  test('project name validation rejects separators and dot names', () {
    expect(validateProjectName('  '), isNotNull);
    expect(validateProjectName('a/b'), isNotNull);
    expect(validateProjectName(r'a\b'), isNotNull);
    expect(validateProjectName('.'), isNotNull);
    expect(validateProjectName('..'), isNotNull);
    expect(validateProjectName(' my_app '), isNull);
  });
}
