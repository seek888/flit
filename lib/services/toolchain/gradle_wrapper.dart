import 'dart:io';

import 'archive.dart';
import 'download.dart';
import 'errors.dart';
import 'layout.dart';
import 'md5.dart';
import 'process.dart';

/// `gradle-wrapper.properties` 的关键字段（其余行原样忽略）。
typedef GradleWrapperProperties = ({
  String distributionUrl,
  String? distributionSha256Sum,
});

/// Gradle Wrapper 发行版缓存：把「Gradle 本体」也做成国内镜像可下载。
///
/// 背景：`flutter build apk` 会由工程自带的 `gradlew` 启动 Gradle，而
/// `gradlew` 只认 `distributionUrl`（默认 `services.gradle.org`）。国内这台
/// 机器上该域名经常连不上，表现为 `flutter build apk` 立刻失败在下载 Gradle。
///
/// Gradle Wrapper 的缓存布局是可以预置的（无需改工程文件）：
///
/// ```text
/// <GRADLE_USER_HOME>/wrapper/dists/<zip 文件名去后缀>/<base36(MD5(url))>/
///   ├── gradle-<版本>/        ← 解压后的发行版
///   └── <zip 文件名>.ok       ← 0 字节完成标记（缺它就会重新下载）
/// ```
///
/// 这里复刻同一套规则：从国内镜像下载 zip → 解压到该目录 → 写 `.ok`，
/// 之后 `gradlew` 直接命中缓存，完全不碰 `services.gradle.org`。
class GradleWrapperCache {
  GradleWrapperCache({
    required this.layout,
    Downloader? downloader,
    ArchiveExtractor? archive,
    ToolchainProcessGateway? process,
    String? mirrorBaseUrl,
    List<String>? fallbackBaseUrls,
  }) : downloader = downloader ?? Downloader(),
       archive =
           archive ??
           ArchiveExtractor(
             process: process ?? const SystemToolchainProcess(),
             windows: layout.windows,
           ),
       mirrorBaseUrl = mirrorBaseUrl ?? defaultMirrorBase,
       fallbackBaseUrls = fallbackBaseUrls ?? defaultFallbackBases;

  final ToolchainLayout layout;
  final Downloader downloader;
  final ArchiveExtractor archive;

  /// Gradle 发行版的国内镜像根（腾讯云镜像保留官方文件名）。
  final String mirrorBaseUrl;

  /// 备用镜像（腾讯镜像缺该版本时再试）。
  final List<String> fallbackBaseUrls;

  static const String defaultMirrorBase = String.fromEnvironment(
    'FLIT_GRADLE_MIRROR_BASE',
    defaultValue: 'https://mirrors.cloud.tencent.com/gradle',
  );

  static const List<String> defaultFallbackBases = <String>[
    'https://mirrors.aliyun.com/macports/distfiles/gradle',
  ];

  static const List<String> wrapperPropertiesCandidates = <String>[
    'android/gradle/wrapper/gradle-wrapper.properties',
    'gradle/wrapper/gradle-wrapper.properties',
  ];

  /// 工程里的 wrapper 配置；没有 wrapper（非 Gradle 工程）返回 null。
  File? wrapperPropertiesFile(String projectPath) {
    for (final relative in wrapperPropertiesCandidates) {
      final file = File(layout.join(projectPath, relative.replaceAll('/', _sep)));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// 解析 `key=value`（`java.util.Properties` 的转义规则：`\:`、`\=`、`\\`）。
  static GradleWrapperProperties? parseProperties(String text) {
    String? url;
    String? sha;
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
        continue;
      }
      final index = line.indexOf('=');
      if (index <= 0) continue;
      final key = line.substring(0, index).trim();
      final value = _unescape(line.substring(index + 1).trim());
      if (key == 'distributionUrl' && value.isNotEmpty) url = value;
      if (key == 'distributionSha256Sum' && value.isNotEmpty) sha = value;
    }
    if (url == null) return null;
    return (distributionUrl: url, distributionSha256Sum: sha);
  }

  /// 目标缓存目录（与 Gradle Wrapper 的算法逐位一致）。
  String distributionDir(String distributionUrl) {
    final stem = _distributionStem(_distributionFileName(distributionUrl));
    return layout.join(
      layout.join(
        layout.join(layout.gradleHome, 'wrapper/dists'.replaceAll('/', _sep)),
        stem,
      ),
      md5Base36(distributionUrl),
    );
  }

  /// 已就绪：解压目录 + `<zip 文件名>.ok` 标记都在（缺 `.ok` 会被当成没装）。
  bool isReady(String distributionUrl) {
    final dir = Directory(distributionDir(distributionUrl));
    if (!dir.existsSync()) return false;
    final zipName = _distributionFileName(distributionUrl);
    if (!File(layout.join(dir.path, '$zipName.ok')).existsSync()) return false;
    try {
      return dir.listSync().any((entity) => entity is Directory);
    } catch (_) {
      return false;
    }
  }

  /// 确保工程需要的 Gradle 发行版已在私有 `gradle-home` 里；返回给终端的日志。
  Stream<String> ensure(String projectPath) async* {
    final file = wrapperPropertiesFile(projectPath);
    if (file == null) {
      yield '工程没有 Gradle Wrapper，跳过 Gradle 发行版准备';
      return;
    }
    final properties = parseProperties(file.readAsStringSync());
    if (properties == null) {
      yield 'Gradle Wrapper 配置缺少 distributionUrl，跳过';
      return;
    }
    final url = properties.distributionUrl;
    if (!url.startsWith('http')) {
      yield '不支持的 Gradle distributionUrl（仅处理 http/https）：$url';
      return;
    }
    final zipName = _distributionFileName(url);
    final stem = _distributionStem(zipName);
    final version = _distributionVersion(stem);
    if (isReady(url)) {
      yield 'Gradle $version 已就绪（$zipName），跳过下载';
      return;
    }

    final target = distributionDir(url);
    final candidates = <String>[
      if (mirrorBaseUrl.isNotEmpty) '${_trimSlash(mirrorBaseUrl)}/$zipName',
      for (final base in fallbackBaseUrls)
        if (base.isNotEmpty) '${_trimSlash(base)}/$zipName',
      url,
    ];
    yield 'Gradle $version 发行版未缓存，从国内镜像下载 $zipName ...';
    final archivePath = layout.cacheFile(zipName);
    final result = await downloader.downloadFirst(
      candidates,
      archivePath,
      sha256: properties.distributionSha256Sum,
      label: 'Gradle $version',
    );
    yield 'Gradle $version 下载完成（来源 ${result.url}）';

    yield '解压 Gradle $version ...';
    final temp = layout.cacheFile('$zipName-extract');
    await archive.extract(archivePath, temp);
    // Wrapper 的缓存目录里必须是「解压后的发行版目录」，例如
    // `<hash>/gradle-9.3.1/`，不能把 gradle-9.3.1 的内容直接摊在 hash 目录下。
    final directory = Directory(target);
    if (directory.existsSync()) {
      // 目标已存在但缺 `.ok`（半装/旧版本）：替换它。Windows 上如果 Gradle
      // 守护进程还占着 jar，删除会共享冲突——给出可执行的处置建议。
      try {
        directory.deleteSync(recursive: true);
      } catch (error) {
        throw ToolchainException(
          'Gradle $version 缓存目录被占用，无法替换：$target。'
          '请先在工程里运行 gradlew --stop 停止 Gradle 守护进程后重试。',
          cause: error,
        );
      }
    }
    directory.createSync(recursive: true);
    for (final entity in Directory(temp).listSync()) {
      final leaf = entity.path.split(RegExp(r'[/\\]')).last;
      entity.renameSync(layout.join(target, leaf));
    }
    // marker 名带 `.zip`：wrapper 用 `new File(distDir, zipFileName + ".ok")`。
    File(layout.join(target, '$zipName.ok')).writeAsStringSync('');
    _deleteQuietly(temp);
    if (!isReady(url)) {
      throw ToolchainException(
        'Gradle $version 预置后校验未通过：$target（缺少解压目录或 .ok 标记）',
      );
    }
    yield 'Gradle $version 已缓存到 ${layout.gradleHome}，构建不再直连 services.gradle.org';
  }

  String get _sep => layout.windows ? '\\' : '/';

  /// `java.util.Properties` 的转义：`\:`→`:`、`\=`→`=`、`\\`→`\`。
  static String _unescape(String value) {
    if (!value.contains('\\')) return value;
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char == '\\' && i + 1 < value.length) {
        final next = value[++i];
        if (next == 't') {
          buffer.write('\t');
        } else if (next == 'n') {
          buffer.write('\n');
        } else if (next == 'r') {
          buffer.write('\r');
        } else if (next == 'u' && i + 4 < value.length) {
          final code = int.tryParse(value.substring(i + 1, i + 5), radix: 16);
          if (code != null) {
            buffer.writeCharCode(code);
            i += 4;
          } else {
            buffer.write(next);
          }
        } else {
          buffer.write(next);
        }
        continue;
      }
      buffer.write(char);
    }
    return buffer.toString();
  }

  static String _trimSlash(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  /// `distributionUrl` 的最后一段，保留 `.zip`（wrapper 的 `.ok` 标记用它）。
  static String _distributionFileName(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final leaf = path
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    if (leaf == null || leaf.isEmpty) {
      throw ToolchainException('无法从 distributionUrl 解析文件名：$url');
    }
    return leaf;
  }

  /// `gradle-9.3.1-all.zip` → `gradle-9.3.1-all`（缓存目录名）。
  static String _distributionStem(String zipName) =>
      zipName.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');

  /// `gradle-9.3.1-all` → `9.3.1`（仅用于日志）。
  static String _distributionVersion(String stem) {
    final match = RegExp(r'gradle-(\d[^-]*)').firstMatch(stem);
    return match?.group(1) ?? stem;
  }

  void _deleteQuietly(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        return;
      }
    } catch (_) {}
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}