import 'package:flutter_test/flutter_test.dart';
import 'package:flit/services/github_mirror.dart';

void main() {
  test('mirror prefix is a valid URL form', () {
    if (GithubMirror.prefix.isNotEmpty) {
      final uri = Uri.tryParse(GithubMirror.prefix);
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(GithubMirror.prefix.endsWith('/'), isTrue,
          reason: '前缀须以 / 结尾，拼接才是合法 URL');
    }
  });

  test('wrap prefixes GitHub hosts only', () {
    if (GithubMirror.prefix.isEmpty) return; // 直连构建: wrap 恒等
    const urls = [
      'https://github.com/lycstar/android-sdk-custom/releases/download/sdk-36.0.0/android-sdk.tar.xz',
      'https://api.github.com/repos/lycstar/android-sdk-custom/releases/tags/sdk-36.0.0',
      'https://objects.githubusercontent.com/some/asset',
    ];
    for (final url in urls) {
      expect(GithubMirror.wrap(url), '${GithubMirror.prefix}$url');
    }
  });

  test('wrap leaves non-GitHub and already-prefixed URLs untouched', () {
    const foreign = 'https://example.invalid/sdk.tar.xz';
    expect(GithubMirror.wrap(foreign), foreign);
    expect(GithubMirror.wrap(''), '');
    if (GithubMirror.prefix.isNotEmpty) {
      final prefixed = '${GithubMirror.prefix}$foreign';
      expect(GithubMirror.wrap(prefixed), prefixed);
    }
  });
}
