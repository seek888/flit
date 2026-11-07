import 'package:flit/core/host_platform.dart';
import 'package:flit/services/console_command.dart';
import 'package:flutter_test/flutter_test.dart';

/// 纯函数测试：POSIX 命令 → cmd.exe 的翻译与引号转义。
///
/// 桌面端无法上真机跑 cmd，所以这里把"形状"钉死：mkdir/cd 前缀、单引号参数、
/// `;`/多行/`</dev/null`/`stty`、以及 `%`/`!`/`"` 的转义。真实执行由 CI 的
/// Windows 构建 + 各调用方的 Process/argv 分支保证。
void main() {
  group('normalizeConsoleCommand (windows)', () {
    String windows(String command) =>
        normalizeConsoleCommand(command, platform: HostPlatform.windows);

    test('mkdir -p + cd 前缀翻译成 cmd 写法', () {
      const input =
          r"""mkdir -p 'C:\tools\projects' && cd 'C:\tools\projects' && """
          r"""flutter create --no-pub --org 'com.example' my_app""";
      expect(
        windows(input),
        r'if not exist "C:\tools\projects" mkdir "C:\tools\projects" & '
        r'cd /d "C:\tools\projects" && '
        r'flutter create --no-pub --org "com.example" my_app',
      );
    });

    test('只有 mkdir -p 没有 cd 的变体', () {
      expect(
        windows(r"mkdir -p '/home/projects' && dart create --no-pub 'x'"),
        r'if not exist "/home/projects" mkdir "/home/projects" && '
        r'dart create --no-pub "x"',
      );
    });

    test('只有 cd 的变体', () {
      expect(
        windows(r"cd '/tmp/work' && ls -la"),
        r'cd /d "/tmp/work" && ls -la',
      );
    });

    test("shQuote 内部单引号 (it's) 还原成字面单引号", () {
      expect(
        windows(r"""flutter --description 'it'\''s fine' run"""),
        r"""flutter --description "it's fine" run""",
      );
    });

    test('引号内的分号保持字面，引号外的分号变 &', () {
      expect(windows("echo 'a;b'; echo done"), r'echo "a;b" & echo done');
      expect(windows('echo "a;b"; echo done'), r'echo "a;b" & echo done');
    });

    test('</dev/null 被去掉', () {
      expect(windows('gh auth status </dev/null'), 'gh auth status');
    });

    test('stty -echo 被去掉（ConPTY 没有这个命令）', () {
      expect(
        windows('stty -echo; flutter run --machine'),
        'flutter run --machine',
      );
    });

    test('多行脚本用 & 串成一条 cmd 命令', () {
      expect(
        windows('flutter pub get\nflutter build web'),
        'flutter pub get & flutter build web',
      );
    });

    test('2>&1 与 && / || 运算符保持原样', () {
      const input = 'flutter run --machine --no-devtools 2>&1';
      expect(windows(input), input);
      expect(
        windows('echo a && echo b || echo c'),
        'echo a && echo b || echo c',
      );
    });

    test('android_build.sh 的 bash 包装被剥掉', () {
      expect(
        windows(
          r'bash "/data/app/assets/scripts/android_build.sh" assembleDebug',
        ),
        'assembleDebug',
      );
    });

    test('已经是 cmd 写法的命令再归一一次不变（幂等）', () {
      const input = r"""mkdir -p 'C:\a' && cd 'C:\a' && echo 'x y'; date""";
      final once = windows(input);
      expect(windows(once), once);
    });

    test('空命令原样返回', () {
      expect(windows('   '), '');
    });
  });

  group('normalizeConsoleCommand (linux/macos desktop)', () {
    String posix(String command) =>
        normalizeConsoleCommand(command, platform: HostPlatform.linux);

    test('去掉 Android 的 env.sh source 前缀', () {
      const input =
          r'''if [ -f "$HOME/.flit/env.sh" ]; then . "$HOME/.flit/env.sh" || exit $?; fi; flutter --version''';
      expect(posix(input), 'flutter --version');
    });

    test('去掉 </dev/null，保留 POSIX 引号', () {
      expect(
        posix(r"git clone 'https://github.com/a/b.git' </dev/null"),
        r"git clone 'https://github.com/a/b.git'",
      );
    });
  });

  group('normalizeConsoleCommand (android)', () {
    test('Android 原样返回（仍需要 bash 包装）', () {
      const input =
          r'''if [ -f "$HOME/.flit/env.sh" ]; then . "$HOME/.flit/env.sh" || exit $?; fi; '''
          r"""mkdir -p '/data/home/projects' && cd '/data/home/projects' && """
          r"""flutter create --no-pub 'my_app'""";
      expect(
        normalizeConsoleCommand(input, platform: HostPlatform.android),
        input,
      );
    });
  });

  group('quoteForCmd', () {
    test('包上双引号并转义 %/!/内层双引号', () {
      expect(quoteForCmd('100% a!b "c"'), r'"100^% a^!b \"c\""');
    });

    test('引号内的 & | < > ^ 是字面量，不需要转义', () {
      expect(quoteForCmd('a&b|c<d>e^f'), r'"a&b|c<d>e^f"');
    });

    test('普通路径不加多余转义', () {
      expect(
        quoteForCmd(r'C:\Users\me\AppData\Local\FlitDesk'),
        r'"C:\Users\me\AppData\Local\FlitDesk"',
      );
      expect(quoteForCmd('/home/me/projects'), '"/home/me/projects"');
    });
  });

  group('escapeCmdToken', () {
    test('裸 token 的 cmd 元字符逐个 ^ 转义', () {
      expect(escapeCmdToken('a&b|c<d>e^f'), r'a^&b^|c^<d^>e^^f');
      expect(escapeCmdToken('100% done!'), r'100^% done^!');
    });

    test('普通文本不变', () {
      expect(escapeCmdToken('plain-token'), 'plain-token');
    });
  });
}
