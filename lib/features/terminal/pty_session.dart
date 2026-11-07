import 'dart:io';

import '../../services/shell.dart';
import 'console_session.dart';

/// A user-controlled shell. Automated tasks always use their own console.
class PtySession extends ConsoleSession {
  PtySession({
    this.workingDirectory,
    super.title = 'bash',
    required super.launcher,
  }) : super(kind: SessionKind.shell);

  final String? workingDirectory;
  Future<void>? _ensuring;

  Future<void> ensure() {
    if (alive || disposed) return Future.value();
    return _ensuring ??= _ensure().whenComplete(() => _ensuring = null);
  }

  Future<void> _ensure() async {
    // 桌面端没有 Termux 的 $PREFIX/bin/bash：pty_launcher 会用 cmd.exe(/bin/sh)
    // 直接开一个交互会话，所以门禁只对 Android 有意义。
    if (isDesktopPlatform) {
      if (disposed) return;
      await start(workingDirectory: workingDirectory);
      return;
    }
    final status = await Shell.instance.bootstrapStatus();
    final prefix = status['prefix'] as String? ?? '';
    if (!File('$prefix/bin/bash').existsSync() || disposed) return;
    await start(workingDirectory: workingDirectory);
  }
}
