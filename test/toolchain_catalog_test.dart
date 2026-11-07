import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/environment/toolchain_catalog.dart';
import 'package:flit/services/github_mirror.dart';

Map<String, dynamic> release(
  String tag,
  String published, {
  required List<Map<String, dynamic>> assets,
}) => {
  'tag_name': tag,
  'published_at': published,
  'assets': [
    for (final a in assets)
      {
        'name': a['name'],
        'size': a['size'],
        'browser_download_url':
            'https://github.com/example/toolchain/releases/download/$tag/${a['name']}',
        'digest': a['digest'] == null
            ? null
            : 'sha256:${(a['digest'] as String).padRight(64, '0')}',
      },
  ],
};

void main() {
  late ToolchainCatalog exampleCatalog;
  setUp(() {
    exampleCatalog = ToolchainCatalog(
      sources: {
        for (final entry in ToolchainCatalog.components.entries)
          entry.key: CatalogSource(
            repo: 'example/${entry.value.repo.split('/').last}',
            asset: entry.value.asset,
            install: entry.value.install,
            tagPattern: entry.value.tagPattern,
            defaultTag: entry.value.defaultTag,
          ),
      },
    );
  });
  test(
    'directory shares in-flight requests, caches empty results, and refreshes explicitly',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final catalog =
          ToolchainCatalog(
              sources: {
                'platforms': ToolchainCatalog.components['platforms']!,
                'build-tools': ToolchainCatalog.components['build-tools']!,
              },
            )
            ..fetchJson = (_) {
              calls++;
              return pending.future;
            };
      final first = catalog.collect();
      final concurrent = catalog.collect(forceRefresh: true);
      expect(calls, 1);
      pending.complete([]);
      expect(await first, await concurrent);
      await catalog.collect();
      expect(calls, 1);
      await catalog.collect(forceRefresh: true);
      expect(calls, 2);
    },
  );

  test(
    'failed catalog is not retried on remount and explicit refresh can recover',
    () async {
      var calls = 0;
      final catalog =
          ToolchainCatalog(
              sources: {'platforms': ToolchainCatalog.components['platforms']!},
            )
            ..fetchJson = (_) async {
              calls++;
              throw const HttpExceptionWithCode('offline');
            };
      await catalog.collect();
      await catalog.collect();
      expect(calls, 1);
      expect(catalog.errors['platforms'], contains('offline'));
      catalog.fetchJson = (_) async {
        calls++;
        return [];
      };
      await catalog.collect(forceRefresh: true);
      expect(calls, 2);
      expect(catalog.errors, isEmpty);
    },
  );

  test('exact tags resolve current bundle and minor Platform metadata', () async {
    final urls = <String>[];
    final catalog = ToolchainCatalog()
      ..fetchJson = (url) async {
        urls.add(url);
        final platform = url.endsWith('/platform-36.1');
        return release(
          platform ? 'platform-36.1' : 'sdk-36.0.0',
          '2026-10-30T00:00:00Z',
          assets: [
            {
              'name': platform ? 'platforms.tar.xz' : 'android-sdk.tar.xz',
              'size': 123,
              'digest': 'ab',
            },
          ],
        );
      };
    final sdk = await catalog.resolve('android-sdk');
    final platform = await catalog.resolve('platforms', tag: 'platform-36.1');
    expect(sdk.name, 'android-sdk.tar.xz');
    expect(sdk.sha256, 'ab'.padRight(64, '0'));
    expect(platform.tag, 'platform-36.1');
    expect(urls, [
      GithubMirror.wrap(
        'https://api.github.com/repos/lycstar/android-sdk-custom/releases/tags/sdk-36.0.0',
      ),
      GithubMirror.wrap(
        'https://api.github.com/repos/lycstar/android-sdk-custom/releases/tags/platform-36.1',
      ),
    ]);
  });

  test('resolution rejects missing digests and mismatched releases', () async {
    final catalog = ToolchainCatalog()
      ..fetchJson = (_) async => release(
        'sdk-36.0.0',
        '2026-10-30T00:00:00Z',
        assets: [
          {'name': 'android-sdk.tar.xz', 'size': 1},
        ],
      );
    await expectLater(catalog.resolve('android-sdk'), throwsStateError);
    catalog.fetchJson = (_) async => release('sdk-35.0.0', '', assets: []);
    await expectLater(catalog.resolve('android-sdk'), throwsStateError);
    await expectLater(
      catalog.resolve('android-sdk', tag: 'sdk-36.0.0-linux'),
      throwsStateError,
    );
    catalog.fetchJson = (_) async =>
        throw const HttpExceptionWithCode('HTTP 403');
    await expectLater(
      catalog.resolve('android-sdk'),
      throwsA(isA<HttpExceptionWithCode>()),
    );
  });

  test('SDK parts share paginated requests and filter tag families', () async {
    final calls = <String>[];
    final catalog =
        ToolchainCatalog(
            sources: {
              for (final key in ['android-sdk', 'build-tools', 'platforms'])
                key: ToolchainCatalog.components[key]!,
            },
          )
          ..fetchJson = (url) async {
            calls.add(url);
            if (url.endsWith('page=1')) {
              return List.generate(
                100,
                (i) => release('unrelated-$i', '', assets: []),
              );
            }
            return [
              release(
                'sdk-35.0.0',
                '',
                assets: [
                  {'name': 'android-sdk.tar.xz', 'size': 1, 'digest': 'aa'},
                  {'name': 'build-tools.tar.xz', 'size': 1, 'digest': 'bb'},
                ],
              ),
              release(
                'platform-34',
                '',
                assets: [
                  {'name': 'platforms.tar.xz', 'size': 1, 'digest': 'cc'},
                ],
              ),
              release(
                'sdk-35.0.0-linux',
                '',
                assets: [
                  {'name': 'android-sdk.tar.xz', 'size': 1, 'digest': 'dd'},
                ],
              ),
            ];
          };
    final found = await catalog.collect();
    expect(calls, hasLength(2));
    expect(found['android-sdk']!.single.tag, 'sdk-35.0.0');
    expect(found['build-tools']!.single.name, 'build-tools.tar.xz');
    expect(found['platforms']!.single.tag, 'platform-34');
    catalog.fetchJson = (_) async => [];
    expect(
      (await catalog.collect(
        forceRefresh: true,
      )).values.every((entries) => entries.isEmpty),
      isTrue,
    );
  });

  test('unconfigured repositories do not make network requests', () async {
    final catalog = ToolchainCatalog(
      sources: const {
        'android-sdk': CatalogSource(repo: '', asset: 'sdk', install: 'sdk'),
      },
    )..fetchJson = (_) async => throw StateError('Unexpected request');
    expect(
      (await catalog.collect()).values.every((entries) => entries.isEmpty),
      isTrue,
    );
  });

  test('default catalog points to the published Flit repositories', () {
    expect(ToolchainCatalog().configured, isTrue);
    expect(
      ToolchainCatalog.components['android-sdk']!.repo,
      'lycstar/android-sdk-custom',
    );
  });

  test('only complete SHA-256 asset digests are accepted', () {
    final hash = 'a'.padRight(64, 'b');
    expect(ToolchainCatalog.parseSha256('sha256:$hash'), hash);
    expect(ToolchainCatalog.parseSha256('sha256:${hash.toUpperCase()}'), hash);
    for (final digest in [null, '', 'sha256:', 'sha256:abc', 'sha512:$hash']) {
      expect(ToolchainCatalog.parseSha256(digest), isNull);
    }
  });

  test('asset matching: plain name and star patterns', () {
    expect(
      ToolchainCatalog.matchesAsset(
        'android-ndk-r28c-aarch64-linux-android.tar.xz',
        'android-ndk-*-aarch64-linux-android.tar.xz',
      ),
      isTrue,
    );
    expect(
      ToolchainCatalog.matchesAsset('android-sdk.tar.xz', 'android-sdk.tar.xz'),
      isTrue,
    );
    // 通配符段也不许缺席
    expect(
      ToolchainCatalog.matchesAsset(
        'android-ndk-aarch64-linux-android.tar.xz',
        'android-ndk-*-aarch64-linux-android.tar.xz',
      ),
      isFalse,
    );
    expect(
      ToolchainCatalog.matchesAsset(
        'bootstrap-aarch64.zip.other',
        'bootstrap-aarch64.zip',
      ),
      isFalse,
    );
  });

  test('collect gathers matching assets per component, newest first', () async {
    final catalog = exampleCatalog
      ..fetchJson = (url) async {
        if (url.contains('android-ndk-custom')) {
          return [
            release(
              'ndk-r27d',
              '2026-10-01T00:00:00Z',
              assets: [
                {
                  'name': 'android-ndk-r27d-aarch64-linux-android.tar.xz',
                  'size': 129,
                  'digest': 'aa',
                },
              ],
            ),
          ];
        }
        if (url.contains('android-sdk-custom')) {
          return [
            release(
              'sdk-36.1.0',
              '2026-10-02T00:00:00Z',
              assets: [
                {'name': 'android-sdk.tar.xz', 'size': 156, 'digest': 'bb'},
              ],
            ),
          ];
        }
        if (url.contains('cmake-custom')) {
          return [
            release(
              'cmake-3.31.6',
              '2026-10-02T00:00:00Z',
              assets: [
                {
                  'name': 'cmake-aarch64-linux-android.tar.xz',
                  'size': 14,
                  'digest': 'ee',
                },
              ],
            ),
          ];
        }
        if (url.contains('flutter-sdk-custom')) {
          return [
            release(
              'flutter-3.47.7',
              '2026-10-03T00:00:00Z',
              assets: [
                {
                  'name': 'flutter-3.47.7-aarch64-linux-android.tar.xz',
                  'size': 590,
                  'digest': 'cc',
                },
              ],
            ),
          ];
        }
        return [
          release(
            'bootstrap-2026.10.16-r1+apt.android-7',
            '2026-10-04T00:00:00Z',
            assets: [
              {'name': 'bootstrap-aarch64.zip', 'size': 31, 'digest': 'dd'},
            ],
          ),
        ];
      };

    final result = await catalog.collect();
    // bootstrap 走初始化管线整包安装, 不出现在版本目录
    expect(result.keys, containsAll(['android-sdk', 'ndk', 'flutter-sdk']));
    expect(result.containsKey('bootstrap'), isFalse);
    final ndk = result['ndk']!;
    expect(ndk, hasLength(1));
    expect(ndk.single.tag, 'ndk-r27d');
    expect(ndk.single.sha256, 'aa'.padRight(64, '0'));
    expect(ndk.single.url, contains('releases/download/ndk-r27d/'));
    expect(result['flutter-sdk']!.single.size, 590);
    expect(result['cmake']!.single.tag, 'cmake-3.31.6');
  });

  test(
    'one component failing falls back to its cache, others stay fresh',
    () async {
      final catalog = exampleCatalog;
      catalog.fetchJson = (url) async => [
        release(
          'sdk-36.1.0',
          '2026-10-02T00:00:00Z',
          assets: [
            {'name': 'android-sdk.tar.xz', 'size': 156, 'digest': 'bb'},
          ],
        ),
      ];
      final first = await catalog.collect();
      expect(first['android-sdk']!, isNotEmpty);

      // 之后 SDK 仓持续 500, NDK 恢复: SDK 用上次成功结果, NDK 拿到新数据
      catalog.fetchJson = (url) async {
        if (url.contains('android-sdk-custom')) {
          throw const HttpExceptionWithCode('HTTP 503');
        }
        return [
          release(
            'ndk-r28c',
            '2026-10-05T00:00:00Z',
            assets: [
              {
                'name': 'android-ndk-r28c-aarch64-linux-android.tar.xz',
                'size': 130,
                'digest': 'ee',
              },
            ],
          ),
        ];
      };
      final second = await catalog.collect(forceRefresh: true);
      expect(
        second['android-sdk']!.single.sha256,
        'bb'.padRight(64, '0'),
      ); // lastGood 回退
      expect(second['ndk']!.single.tag, 'ndk-r28c');
      expect(catalog.errors['android-sdk'], contains('503'));
    },
  );
}

class HttpExceptionWithCode implements Exception {
  const HttpExceptionWithCode(this.message);
  final String message;
  @override
  String toString() => message;
}
