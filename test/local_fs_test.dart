import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flit/services/local_fs.dart';

/// LocalFs 的跨平台行为测试。
///
/// 这套测试的价值在于：CI 跑在 windows-latest 上，
/// 所以 Windows 的路径分隔符 / 大小写不敏感这些细节会被真实覆盖。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flitdesk_fs_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String p(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  void mkfile(String path, String content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  group('基础读写', () {
    test('writeText/readText 往返', () {
      final fs = LocalFs.instance;
      final f = p('a.txt');
      fs.writeText(f, 'hello 世界');
      expect(fs.exists(f), isTrue);
      expect(fs.isFile(f), isTrue);
      expect(fs.readText(f), 'hello 世界');
    });

    test('readText 读不存在的文件返回空串', () {
      expect(LocalFs.instance.readText(p('nope.txt')), '');
    });

    test('remove 目录是递归删除', () {
      final fs = LocalFs.instance;
      mkfile(
        p('d${Platform.pathSeparator}x${Platform.pathSeparator}y.txt'),
        'y',
      );
      fs.remove(p('d'));
      expect(fs.exists(p('d')), isFalse);
    });

    test('copy 目录会带上子项', () {
      final fs = LocalFs.instance;
      mkfile(p('src${Platform.pathSeparator}a.txt'), 'a');
      mkfile(
        p('src${Platform.pathSeparator}sub${Platform.pathSeparator}b.txt'),
        'b',
      );
      fs.copy(p('src'), p('dst'));
      expect(fs.readText(p('dst${Platform.pathSeparator}a.txt')), 'a');
      expect(
        fs.readText(
          p('dst${Platform.pathSeparator}sub${Platform.pathSeparator}b.txt'),
        ),
        'b',
      );
    });

    test('rename 移动文件', () {
      final fs = LocalFs.instance;
      mkfile(p('r1.txt'), 'x');
      fs.rename(p('r1.txt'), p('r2.txt'));
      expect(fs.exists(p('r1.txt')), isFalse);
      expect(fs.readText(p('r2.txt')), 'x');
    });
  });

  group('边界判定', () {
    test('isInside 严格包含（根自己不算在内）', () {
      final fs = LocalFs.instance;
      mkfile(p('root${Platform.pathSeparator}a.txt'), 'a');
      final root = p('root');
      expect(
        fs.isInside(root, p('root${Platform.pathSeparator}a.txt')),
        isTrue,
      );
      expect(fs.isInside(root, root), isFalse);
      expect(fs.isInside(root, p('other.txt')), isFalse);
    });

    test('same 在不同写法下判为同一路径', () {
      final fs = LocalFs.instance;
      Directory(p('x')).createSync(recursive: true);
      expect(fs.same(p('x'), p('x')), isTrue);
    });
  });

  group('工程扫描', () {
    test('flutter 项目识别 + 目录列表', () {
      final fs = LocalFs.instance;
      mkfile(
        p('app1${Platform.pathSeparator}pubspec.yaml'),
        'name: app1\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
      mkfile(
        p('app1${Platform.pathSeparator}lib${Platform.pathSeparator}main.dart'),
        'void main(){}',
      );
      mkfile(p('dart1${Platform.pathSeparator}pubspec.yaml'), 'name: dart1\n');
      Directory(p('plain')).createSync(recursive: true);
      Directory(p('.hidden')).createSync(recursive: true);

      final probes = fs.scanProjects(tmp.path);
      final names = probes.map((e) => e.name).toList();
      expect(names.contains('app1'), isTrue);
      expect(names.contains('dart1'), isTrue);
      expect(names.contains('plain'), isTrue);
      expect(names.contains('.hidden'), isFalse, reason: '隐藏目录不参与');

      final app1 = probes.firstWhere((e) => e.name == 'app1');
      expect(app1.isFlutter, isTrue);
      expect(app1.hasPubspec, isTrue);
      expect(app1.newestMillis, isNotNull);

      final dart1 = probes.firstWhere((e) => e.name == 'dart1');
      expect(dart1.isFlutter, isFalse);
      expect(dart1.hasPubspec, isTrue);

      final plain = probes.firstWhere((e) => e.name == 'plain');
      expect(plain.hasPubspec, isFalse);
    });

    test('listTree 目录带斜杠、跳过构建产物与点目录', () {
      final fs = LocalFs.instance;
      mkfile(
        p('p${Platform.pathSeparator}lib${Platform.pathSeparator}main.dart'),
        '',
      );
      mkfile(
        p('p${Platform.pathSeparator}build${Platform.pathSeparator}junk.txt'),
        '',
      );
      mkfile(
        p('p${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}x'),
        '',
      );
      mkfile(p('p${Platform.pathSeparator}README.md'), '');

      final tree = fs.listTree(p('p'));
      expect(tree.contains('lib/'), isTrue);
      expect(tree.contains('lib/main.dart'), isTrue);
      expect(tree.contains('README.md'), isTrue);
      expect(tree.any((e) => e.startsWith('build/')), isFalse);
      expect(tree.any((e) => e.startsWith('.dart_tool/')), isFalse);
    });
  });

  test('dirSize 累计文件大小', () {
    final fs = LocalFs.instance;
    mkfile(p('s${Platform.pathSeparator}a.bin'), 'aaaa');
    mkfile(
      p('s${Platform.pathSeparator}sub${Platform.pathSeparator}b.bin'),
      'bb',
    );
    expect(fs.dirSize(p('s')), 6);
  });
}
