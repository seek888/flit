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

  test('wrapWith an empty prefix is the direct connection', () {
    const url = 'https://api.github.com/repos/a/b/releases/latest';
    expect(GithubMirror.wrapWith('', url), url);
  });

  test('candidates keep mirrors first, direct last, and are deduped', () {
    const url = 'https://api.github.com/repos/git-for-windows/git/releases/latest';
    final candidates = GithubMirror.candidates(url);
    expect(candidates, isNotEmpty);
    expect(candidates.toSet().length, candidates.length);
    expect(candidates.last, url, reason: '直连永远是最后兜底');
    if (GithubMirror.prefix.isNotEmpty) {
      expect(candidates.first, '${GithubMirror.prefix}$url');
      expect(candidates.length, greaterThan(1));
    } else {
      expect(candidates, <String>[url]);
    }
  });

  test('candidates leave non-GitHub URLs alone', () {
    const url = 'https://dl.google.com/android/repository/repository2-3.xml';
    expect(GithubMirror.candidates(url), <String>[url]);
    expect(GithubMirror.candidates(''), isEmpty);
  });

  test('all built-in candidates are https and slash-terminated', () {
    for (final candidate in GithubMirror.prefixes) {
      expect(candidate, startsWith('https://'));
      expect(candidate.endsWith('/'), isTrue, reason: candidate);
      final uri = Uri.tryParse(candidate);
      expect(uri, isNotNull, reason: candidate);
    }
  });
}
