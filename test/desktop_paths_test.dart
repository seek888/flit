import 'dart:io';

import 'package:flit/core/host_platform.dart';
import 'package:flit/services/local_fs.dart';
import 'package:flit/services/paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨平台路径工具测试：Windows 绝对路径不能让 baseName/相对化逻辑失效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => setHostPlatform(null));

  group('baseName', () {
    test('两种分隔符与尾分隔符', () {
      expect(baseName(r'C:\a\b'), 'b');
      expect(baseName('C:/a/b'), 'b');
      expect(baseName('C:/a/b/'), 'b');
      expect(baseName(r'C:\a\b\'), 'b');
      expect(baseName('name'), 'name');
    });

    test('根路径与空串返回空', () {
      expect(baseName('/'), '');
      expect(baseName(r'\'), '');
      expect(baseName(''), '');
    });

    test('工程名不再返回整条 Windows 路径', () {
      expect(
        baseName(r'C:\Users\me\AppData\Local\FlitDesk\projects\my_app'),
        'my_app',
      );
    });
  });

  group('dirName', () {
    test('保留原分隔符风格', () {
      expect(dirName(r'C:\a\b'), r'C:\a');
      expect(dirName('/a/b'), '/a');
      expect(dirName('a/b'), 'a');
      expect(dirName('/a'), '');
      expect(dirName('C:'), '');
    });

    test('盘符根', () {
      expect(dirName(r'C:\a'), r'C:\');
      expect(dirName('C:/a'), 'C:/');
    });

    test('尾分隔符先去掉', () {
      expect(dirName('/a/b/'), '/a');
    });
  });

  group('joinPath', () {
    final sep = Platform.pathSeparator;

    test('相对路径里的 / 归一成宿主分隔符', () {
      expect(joinPath('root', 'a/b'), 'root${sep}a${sep}b');
      expect(joinPath('root', 'lib/main.dart'), 'root${sep}lib${sep}main.dart');
    });

    test('根带尾分隔符不会产生双分隔符', () {
      expect(joinPath('root$sep', 'a'), 'root${sep}a');
      expect(joinPath('C:\\root\\', 'lib/x'), 'C:\\root${sep}lib${sep}x');
    });

    test('绝对相对路径原样（只归一化分隔符）', () {
      expect(joinPath('root', '/abs/x'), '/abs/x'.replaceAll('/', sep));
    });

    test('空相对路径返回根本身', () {
      expect(joinPath('root', ''), 'root');
    });
  });

  group('relativeInside', () {
    test('Windows: 分隔符与大小写都不影响相对化', () {
      setHostPlatform(HostPlatform.windows);
      expect(
        relativeInside(r'C:\proj', r'C:\proj\lib\main.dart'),
        'lib/main.dart',
      );
      expect(
        relativeInside(r'C:\proj', 'C:/proj/lib/main.dart'),
        'lib/main.dart',
      );
      expect(relativeInside('C:/Proj', r'c:\proj\A.dart'), 'A.dart');
      expect(relativeInside('C:\\proj\\', r'C:\proj\a'), 'a');
    });

    test('Windows: 根自身/越界/前缀相同的兄弟目录都拒绝', () {
      setHostPlatform(HostPlatform.windows);
      expect(relativeInside(r'C:\proj', r'C:\proj'), isNull);
      expect(relativeInside(r'C:\proj', r'C:\proj2\a'), isNull);
      expect(relativeInside(r'C:\proj', r'D:\proj\a'), isNull);
    });

    test('Linux: 大小写敏感', () {
      setHostPlatform(HostPlatform.linux);
      expect(relativeInside('/proj', '/proj/lib/main.dart'), 'lib/main.dart');
      expect(relativeInside('/proj', '/Proj/lib/main.dart'), isNull);
      expect(relativeInside('/proj', '/proj'), isNull);
    });
  });

  group('samePath', () {
    test('Windows/macOS 大小写不敏感、分隔符不敏感', () {
      setHostPlatform(HostPlatform.windows);
      expect(samePath(r'C:\A\b.dart', 'c:/a/B.dart'), isTrue);
      expect(samePath(r'C:\a\x.dart', r'C:\a\y.dart'), isFalse);
      setHostPlatform(HostPlatform.macos);
      expect(samePath('/A/b', '/a/B'), isTrue);
    });

    test('Linux 大小写敏感', () {
      setHostPlatform(HostPlatform.linux);
      expect(samePath('/a/b', '/A/B'), isFalse);
      expect(samePath('/a/./b', '/a/b'), isTrue);
    });
  });

  test('LocalFs.listTree 保留 dotfile，只 prune 构建/缓存/版本库', () async {
    final dir = await Directory.systemTemp.createTemp('flit-paths-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await Directory('${dir.path}/lib').create();
    await Directory('${dir.path}/build').create();
    await Directory('${dir.path}/.dart_tool').create();
    await Directory('${dir.path}/.git').create();
    await File('${dir.path}/.gitignore').writeAsString('/build\n');
    await File('${dir.path}/.metadata').writeAsString('x');
    await File('${dir.path}/lib/main.dart').writeAsString('void main() {}');
    await File('${dir.path}/build/out.bin').writeAsString('x');
    await File('${dir.path}/.dart_tool/x').writeAsString('x');

    final tree = LocalFs.instance.listTree(dir.path);
    expect(tree, contains('.gitignore'));
    expect(tree, contains('.metadata'));
    expect(tree, contains('lib/main.dart'));
    expect(tree.any((entry) => entry.startsWith('build')), isFalse);
    expect(tree.any((entry) => entry.startsWith('.dart_tool')), isFalse);
    expect(tree.any((entry) => entry == '.git' || entry.startsWith('.git/')), isFalse);
  });

  test('LocalFs.writeText 保留 POSIX 可执行位（桌面原子保存）', () async {
    if (Platform.isWindows) return; // Windows 没有 POSIX 权限位
    final dir = await Directory.systemTemp.createTemp('flit-mode-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final script = File('${dir.path}/tool.sh');
    await script.writeAsString('old');
    await Process.run('chmod', ['755', script.path]);
    LocalFs.instance.writeText(script.path, 'new');
    expect(await script.readAsString(), 'new');
    expect((await script.stat()).mode & 511, 493);
  });
}
