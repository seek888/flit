/// GitHub 加速镜像。
///
/// 工具链与 bootstrap 产物托管在 GitHub Releases，国内直连
/// api.github.com / github.com（资产下载）时通时断、大文件几乎不可用，
/// 因此统一在构造 URL 处加国内代理前缀（API 元数据与资产下载同一前缀，
/// 避免半通半断的组合失败）。
///
/// 单个代理本身也可能被限流/临时不可用，所以这里维护**候选前缀列表**：
/// 下载层按顺序逐个尝试，最后一个候选永远是直连（空前缀）兜底。
/// 「某个代理在别人机器上可用、在这台机器上不可用」是常态，多候选比
/// 写死一个更接近真实网络环境。
///
/// 代理只做传输层转发，SHA-256 摘要仍以 GitHub API 返回值为准，校验不受影响。
///
/// 构建期可用 `--dart-define=FLIT_GH_PROXY=<prefix[,prefix...]>` 覆盖：
/// - 换代理：`FLIT_GH_PROXY=https://ghfast.top/`
/// - 多代理：`FLIT_GH_PROXY=https://gh-proxy.com/,https://ghfast.top/`
/// - 直连：`FLIT_GH_PROXY=`（空值，只直连，不追加内置候选）
class GithubMirror {
  GithubMirror._();

  /// 构建期配置的镜像前缀；空字符串表示只要直连。
  static const String configured = String.fromEnvironment(
    'FLIT_GH_PROXY',
    defaultValue: 'https://gh-proxy.com/',
  );

  /// 国内常用公共前缀：配置里没有的按顺序追加，作为自动回退候选。
  static const List<String> builtInPrefixes = <String>[
    'https://gh-proxy.com/',
    'https://ghfast.top/',
    'https://ghproxy.net/',
  ];

  /// 会被加前缀的主机（其余地址原样返回）。
  static const List<String> githubHosts = <String>[
    'https://github.com/',
    'https://api.github.com/',
    'https://objects.githubusercontent.com/',
    'https://raw.githubusercontent.com/',
    'https://codeload.github.com/',
  ];

  static List<String>? _cachedPrefixes;

  /// 候选前缀（去重、保序；空列表表示直连）。
  ///
  /// 配置为空字符串时只直连（不追加内置候选），便于用户显式关闭镜像。
  static List<String> get prefixes =>
      _cachedPrefixes ??= _parsePrefixes(configured);

  /// 主前缀：候选列表里的第一个非空前缀；没有候选时为空串（直连）。
  static String get prefix {
    for (final candidate in prefixes) {
      if (candidate.isNotEmpty) return candidate;
    }
    return '';
  }

  /// 给 GitHub 的绝对 URL 加主镜像前缀；非 GitHub 地址与已带前缀的地址原样返回。
  static String wrap(String url) => wrapWith(prefix, url);

  /// 用指定前缀包装；[mirrorPrefix] 为空表示直连。
  static String wrapWith(String mirrorPrefix, String url) {
    if (mirrorPrefix.isEmpty || url.isEmpty || url.startsWith(mirrorPrefix)) {
      return url;
    }
    for (final host in githubHosts) {
      if (url.startsWith(host)) return '$mirrorPrefix$url';
    }
    return url;
  }

  /// 同一 URL 的全部候选：各镜像按顺序在前，直连最后；去重保序。
  ///
  /// 非 GitHub 地址只会得到 `[url]`（包装后不变、去重）。
  static List<String> candidates(String url) {
    if (url.isEmpty) return const <String>[];
    final result = <String>[];
    for (final candidate in prefixes) {
      final wrapped = wrapWith(candidate, url);
      if (!result.contains(wrapped)) result.add(wrapped);
    }
    final direct = wrapWith('', url);
    if (!result.contains(direct)) result.add(direct);
    return result;
  }

  /// 单测用：重置缓存（配置本身是编译期常量，只有测试会改缓存）。
  static void resetCacheForTest() => _cachedPrefixes = null;

  static List<String> _parsePrefixes(String raw) {
    if (raw.trim().isEmpty) return const <String>[];
    final parsed = <String>[];
    void add(String value) {
      var normalized = value.trim();
      if (normalized.isEmpty || parsed.contains(normalized)) return;
      parsed.add(normalized);
    }

    for (final part in raw.split(RegExp(r'[,;\s]+'))) {
      add(_normalize(part));
    }
    for (final fallback in builtInPrefixes) {
      add(fallback);
    }
    return List<String>.unmodifiable(parsed);
  }

  static String _normalize(String value) {
    var normalized = value.trim();
    if (normalized.isEmpty) return normalized;
    if (!normalized.endsWith('/')) normalized = '$normalized/';
    return normalized;
  }
}