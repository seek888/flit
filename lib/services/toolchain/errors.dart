/// 工具链层的可读错误。
///
/// 安装/下载/解压/组件管理失败都必须抛本类（或子类）：界面把 `message`
/// 原样展示给用户，不允许把 `ProcessException`/`SocketException` 之类的
/// 原始异常直接冒到 UI。
class ToolchainException implements Exception {
  const ToolchainException(this.message, {this.cause});

  /// 面向用户的中文说明（包含下一步建议）。
  final String message;

  /// 原始异常，便于日志排查；`toString()` 只在存在时追加。
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message（$cause）';
}

/// 下载失败：HTTP 错误、超时、大小不符、SHA-256 不匹配、用户取消。
class DownloadException extends ToolchainException {
  const DownloadException(super.message, {super.cause});
}

/// 解压失败：tar.exe / PowerShell / unzip 都不可用或返回非 0。
class ArchiveException extends ToolchainException {
  const ArchiveException(super.message, {super.cause});
}

/// sdkmanager 调用失败：JDK/cmdline-tools 缺失、许可未接受、退出码非 0。
class SdkManagerException extends ToolchainException {
  const SdkManagerException(super.message, {super.cause});
}
