/// 桌面安装阶段事件：由 `DesktopSetupRunner` 产出，`EnvironmentController`
/// 消费。类型化事件与 Android 的 `__STAGE__` / `__VER__` 文本协议等价，
/// 因此 `_onPtyText` 的解析路径保持不变。
sealed class SetupEvent {
  const SetupEvent();
}

/// 子任务状态变化（RUNNING/DONE/FAILED/BLOCKED/…），对应
/// `__STAGE__<id>:<state>`。
class StageEvent extends SetupEvent {
  const StageEvent(this.id, this.state);

  final String id;
  final String state;

  String get marker => '__STAGE__$id:$state';
}

/// 版本/附加信息，对应 `__VER__<id>:<text>`。
class VersionEvent extends SetupEvent {
  const VersionEvent(this.id, this.version);

  final String id;
  final String version;

  String get marker => '__VER__$id:$version';
}

/// 普通日志行。
class LogEvent extends SetupEvent {
  const LogEvent(this.line);

  final String line;
}

/// 进度行（终端里用 `\r` 原地刷新，不刷满屏）。
class ProgressEvent extends SetupEvent {
  const ProgressEvent(this.text);

  final String text;
}
