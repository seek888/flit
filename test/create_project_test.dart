import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/projects/clone_project_page.dart';
import 'package:flit/features/projects/create_project_page.dart';

void main() {
  const base = CreateProjectParams(
    type: 'flutter',
    name: 'my_app',
    org: 'com.example',
    platforms: ['android'],
    empty: false,
    androidLang: 'kotlin',
    description: '',
    projectRoot: '/home/projects',
  );

  test('默认参数', () {
    final cmd = buildFlutterCreateCommand(base);
    expect(cmd, contains('--platforms=android'));
    expect(cmd, contains("--org 'com.example'"));
    expect(cmd, contains("'my_app'"));
    expect(cmd, isNot(contains('echo')));
    expect(cmd, isNot(contains('--empty')));
    expect(cmd, isNot(contains('-a java')));
  });

  test('project creation commands use the chosen project root', () {
    const project = CreateProjectParams(
      type: 'dart',
      name: 'private_app',
      org: 'com.example',
      platforms: [],
      empty: false,
      androidLang: 'kotlin',
      description: '',
      projectRoot: '/data/app/home/projects',
    );
    expect(
      buildDartCreateCommand(project),
      contains("cd '/data/app/home/projects'"),
    );
    expect(
      buildFlutterCreateCommand(
        const CreateProjectParams(
          type: 'flutter',
          name: 'private_app',
          org: 'com.example',
          platforms: ['android'],
          empty: false,
          androidLang: 'kotlin',
          description: '',
          projectRoot: '/data/app/home/projects',
        ),
      ),
      contains("cd '/data/app/home/projects'"),
    );
  });

  test('空项目 + java + 多平台 + 描述单引号转义', () {
    final cmd = buildFlutterCreateCommand(
      const CreateProjectParams(
        type: 'flutter',
        name: 'demo',
        org: 'com.a.b',
        platforms: ['android', 'ios'],
        empty: true,
        androidLang: 'java',
        description: "it's fine",
        projectRoot: '/home/projects',
      ),
    );
    expect(cmd, contains('--empty'));
    expect(cmd, contains('-a java'));
    expect(cmd, contains('--platforms=android,ios'));
    expect(cmd, contains(r"'\''"));
    expect(cmd, contains('--description'));
  });

  group('桌面端 create 参数化', () {
    test('flutter create 参数数组（不含 shell 包装）', () {
      expect(flutterCreateArgs(base), [
        'create',
        '--no-pub',
        '--platforms=android',
        '--org',
        'com.example',
        'my_app',
      ]);
      final command = buildDesktopCreateCommand(base);
      expect(
        command,
        'flutter create --no-pub --platforms=android '
        '--org com.example my_app',
      );
      expect(command, isNot(contains('mkdir -p')));
      expect(command, isNot(contains('cd ')));
      expect(command, isNot(contains('bash')));
    });

    test('多平台 + empty + java + 中文/空格描述都进 argv 并被正确引用', () {
      final params = const CreateProjectParams(
        type: 'flutter',
        name: 'demo',
        org: 'com.a.b',
        platforms: ['android', 'ios'],
        empty: true,
        androidLang: 'java',
        description: "it's fine",
        projectRoot: '/home/projects',
      );
      expect(flutterCreateArgs(params), [
        'create',
        '--no-pub',
        '--platforms=android,ios',
        '--org',
        'com.a.b',
        '--empty',
        '-a',
        'java',
        '--description',
        "it's fine",
        'demo',
      ]);
      expect(
        buildDesktopCreateCommand(params),
        'flutter create --no-pub --platforms=android,ios --org com.a.b '
        '--empty -a java --description "it\'s fine" demo',
      );
    });

    test('dart create 参数数组', () {
      const params = CreateProjectParams(
        type: 'dart',
        name: 'private_app',
        org: 'com.example',
        platforms: [],
        empty: false,
        androidLang: 'kotlin',
        description: '',
        projectRoot: '/home/projects',
      );
      expect(dartCreateArgs(params), [
        'create',
        '--no-pub',
        '--template',
        'console',
        'private_app',
      ]);
      expect(
        buildDesktopCreateCommand(params),
        'dart create --no-pub --template console private_app',
      );
    });

    test('Windows 路径里含空格/& 的工程名会被 cmd 引号保护', () {
      const params = CreateProjectParams(
        type: 'flutter',
        name: 'my_app',
        org: 'com.example',
        platforms: ['windows'],
        empty: false,
        androidLang: 'kotlin',
        description: 'a & b',
        projectRoot: r'C:\Users\me\My Projects',
      );
      final command = buildDesktopCreateCommand(params);
      expect(command, contains('--description "a & b"'));
    });
  });

  group('buildGitCloneCommand', () {
    test('默认克隆', () {
      final cmd = buildGitCloneCommand(
        const CloneProjectParams(
          url: 'https://github.com/u/repo.git',
          dirName: 'repo',
          branch: '',
          shallow: false,
          targetDir: '/home/projects',
        ),
      );
      expect(cmd, contains("cd '/home/projects'"));
      expect(cmd, contains("git clone 'https://github.com/u/repo.git' 'repo'"));
      expect(cmd, isNot(contains('echo')));
      expect(cmd, isNot(contains('--depth')));
      expect(cmd, isNot(contains('--branch')));
    });

    test('分支 + 浅克隆', () {
      final cmd = buildGitCloneCommand(
        const CloneProjectParams(
          url: 'https://github.com/u/repo.git',
          dirName: 'repo',
          branch: 'dev',
          shallow: true,
          targetDir: '/home/projects',
        ),
      );
      expect(cmd, contains("--branch 'dev'"));
      expect(cmd, contains('--depth 1'));
    });

    test('repoNameFromUrl 三种形态', () {
      expect(repoNameFromUrl('https://github.com/u/repo.git'), 'repo');
      expect(repoNameFromUrl('git@github.com:u/repo.git'), 'repo');
      expect(repoNameFromUrl('https://github.com/u/repo/'), 'repo');
    });
  });
}
