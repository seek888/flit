/// GitHub 加速镜像。
///
/// 工具链与 bootstrap 产物托管在 GitHub Releases，国内直连
/// api.github.com / github.com（资产下载）时通时断、大文件几乎不可用，
/// 因此统一在构造 URL 处加国内代理前缀（API 元数据与资产下载同一前缀，
/// 避免半通半断的组合失败）。
///
/// 代理只做传输层转发，SHA-256 摘要仍以 GitHub API 返回值为准，校验不受影响。
///
/// 构建期可用 `--dart-define=FLIT_GH_PROXY=<prefix>` 覆盖：
/// - 换代理：`FLIT_GH_PROXY=https://ghfast.top/`
/// - 直连：`FLIT_GH_PROXY=`（空值）
class GithubMirror {
  GithubMirror._();

  /// 镜像前缀，须以 `/` 结尾；空字符串表示直连。
  static const String prefix = String.fromEnvironment(
    'FLIT_GH_PROXY',
    defaultValue: 'https://gh-proxy.com/',
  );

  /// 给 GitHub 的绝对 URL 加镜像前缀；非 GitHub 地址与已带前缀的地址原样返回。
  static String wrap(String url) {
    if (prefix.isEmpty || url.isEmpty || url.startsWith(prefix)) {
      return url;
    }
    const hosts = [
      'https://github.com/',
      'https://api.github.com/',
      'https://objects.githubusercontent.com/',
    ];
    for (final host in hosts) {
      if (url.startsWith(host)) return '$prefix$url';
    }
    return url;
  }
}
