import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owls_flutter/owls_native.dart';
import 'package:owls_flutter/src/release_schema.dart';

final wasm = Uint8List.fromList([0, 97, 115, 109, 1, 0, 0, 0]);
Map<String, dynamic> manifest() => {
      'schemaVersion': 1,
      'appId': 'demo',
      'release': 'r1',
      'runtime': 'raw-wasm',
      'entrypoint': 'main',
      'assets': [
        {
          'id': 'main',
          'url': 'https://assets.example/main.wasm',
          'kind': 'wasm',
          'bytes': wasm.length,
          'sha256': sha256.convert(wasm).toString(),
          'prepare': true
        }
      ]
    };

class Fetch implements AssetTransport {
  int calls = 0;
  Uint8List value = wasm;
  @override
  Future<Uint8List> fetch(WasmAsset asset, Cancellation cancellation) async {
    calls++;
    return value;
  }
}

class SlowFetch extends Fetch {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Uint8List> fetch(WasmAsset asset, Cancellation cancellation) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await release.future;
    return value;
  }
}

class Adapter implements WasmAdapter<int> {
  int starts = 0;
  @override
  Future<int> activate(
      WasmRelease release, ReadAsset bytes, Cancellation cancellation) async {
    starts++;
    return (await bytes(release.entrypoint)).length;
  }
}

LoaderPolicy policy({int maxPrepareBytes = 1000}) => LoaderPolicy(
    origins: ['https://assets.example'], maxPrepareBytes: maxPrepareBytes);

class HangingAdapter implements WasmAdapter<int> {
  int starts = 0;
  @override
  Future<int> activate(
      WasmRelease release, ReadAsset bytes, Cancellation token) {
    starts++;
    return Completer<int>().future;
  }
}

class NoopAdapter implements WasmAdapter<int> {
  @override
  Future<int> activate(
      WasmRelease release, ReadAsset bytes, Cancellation cancellation) async {
    return 1;
  }
}

class CleanupAdapter implements WasmAdapter<int>, WasmDeactivator<int> {
  int starts = 0, stops = 0;
  @override
  Future<int> activate(
      WasmRelease release, ReadAsset bytes, Cancellation cancellation) async {
    starts++;
    return starts;
  }

  @override
  Future<void> deactivate(int instance) async {
    stops++;
  }
}

void main() {
  test('activation timeout is terminal and does not replay partial startup',
      () async {
    final adapter = HangingAdapter();
    final host = WasmHost(manifest(),
        policy: LoaderPolicy(
            origins: ['https://assets.example'],
            timeout: const Duration(milliseconds: 10)),
        transport: Fetch());
    await expectLater(host.activate(adapter), throwsA(isA<LoaderException>()));
    await expectLater(host.activate(adapter), throwsA(isA<LoaderException>()));
    expect(adapter.starts, 1);
  });
  test(
      'JSON integer-valued numbers and extension configuration survive parsing',
      () {
    final r = manifest()..['schemaVersion'] = 1.0;
    r['assets'][0]['bytes'] = 8.0;
    r['extensions'] = {
      'tenant': {'mode': 'fast'}
    };
    final parsed = parseRelease(r, ['https://assets.example']);
    expect(parsed.assets.first.bytes, 8);
    expect((parsed.extensions['tenant'] as Map)['mode'], 'fast');
    expect(() => (parsed.extensions['tenant'] as Map)['mode'] = 'slow',
        throwsUnsupportedError);
  });
  test('pinned schema is embedded byte-for-byte', () {
    expect(
        releaseSchemaJson,
        File('zed_modules/ores-wasm-loaders/owls-interfaces/schemas/release.schema.json')
            .readAsStringSync());
  });
  test('warmup is fetch-only and activation is shared', () async {
    final fetch = Fetch(), adapter = Adapter();
    final host = WasmHost(manifest(), policy: policy(), transport: fetch);
    await Future.wait([host.prefetch(), host.prefetch()]);
    expect(adapter.starts, 0);
    expect(await Future.wait([host.activate(adapter), host.activate(adapter)]),
        [8, 8]);
    expect(adapter.starts, 1);
    expect(fetch.calls, 1);
  });
  test('bad warmup does not poison activation', () async {
    final fetch = Fetch()..value = Uint8List(8);
    final host = WasmHost(manifest(), policy: policy(), transport: fetch);
    final outcome = await host.prefetch();
    expect(outcome.status, 'failed');
    fetch.value = wasm;
    expect(await host.activate(Adapter()), 8);
  });
  test('budget and cancellation reject before transport', () async {
    final fetch = Fetch(),
        host = WasmHost(manifest(),
            policy: policy(maxPrepareBytes: 1), transport: Fetch());
    await expectLater(host.prefetch(), throwsA(isA<LoaderException>()));
    final token = Cancellation()..cancel();
    await expectLater(
        WasmHost(manifest(), policy: policy(), transport: fetch)
            .bytes('main', token),
        throwsA(isA<LoaderException>()));
    expect(fetch.calls, 0);
  });
  test('schema, origins, entrypoints and duplicate assets are rejected', () {
    final edits = <void Function(Map<String, dynamic>)>[
      (r) => r['extra'] = true,
      (r) => r['entrypoint'] = 'missing',
      (r) => r['assets'][0]['bytes'] = 0,
      (r) => r['assets'][0]['url'] = 'https://evil.example/a',
      (r) => (r['assets'] as List).add(r['assets'][0]),
    ];
    for (final edit in edits) {
      final r = manifest();
      edit(r);
      expect(() => parseRelease(r, ['https://assets.example']),
          throwsA(isA<LoaderException>()));
    }
    expect(() => parseRelease(manifest(), ['https://assets.example/']),
        throwsA(isA<LoaderException>()));
    final uppercase = manifest();
    uppercase['assets'][0]['url'] = 'https://ASSETS.example/main.wasm';
    expect(() => parseRelease(uppercase, ['https://assets.example']),
        throwsA(isA<LoaderException>()));
  });
  test('native file bytes survive a new cache instance', () async {
    final dir = await Directory.systemTemp.createTemp('owls-test-');
    try {
      final key = sha256.convert(wasm).toString();
      await FileByteStore(dir).put(key, wasm);
      expect(await FileByteStore(dir).get(key), wasm);
      expect(() => FileByteStore(dir).get('../outside'),
          throwsA(isA<LoaderException>()));
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('untrusted mutation cannot change parsed release assets', () {
    final r = manifest();
    final host = WasmHost(r, policy: policy(), transport: Fetch());
    r['assets'][0]['url'] = 'https://evil.example/a';
    expect(host.release.assets.first.url, 'https://assets.example/main.wasm');
    expect(jsonDecode(releaseSchemaJson)['schemaVersion'], isNull);
  });
  test('preparation leases share one job and release independently', () async {
    final fetch = SlowFetch();
    final host = WasmHost(manifest(), policy: policy(), transport: fetch);
    final one = host.prepare(), two = host.prepare();
    await fetch.started.future;
    one.release();
    expect(two.future, isA<Future<PreparationOutcome>>());
    fetch.release.complete();
    expect((await two.future).status, 'warmed');
    expect(fetch.calls, 1);
  });
  test('activation only gives speculative preparation a bounded join',
      () async {
    final fetch = SlowFetch();
    final host = WasmHost(manifest(),
        policy: LoaderPolicy(
            origins: ['https://assets.example'],
            timeout: const Duration(seconds: 1),
            activationJoin: const Duration(milliseconds: 10)),
        transport: fetch);
    final preparation = host.prefetch();
    await fetch.started.future;
    final watch = Stopwatch()..start();
    expect(await host.activate(NoopAdapter()), 1);
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)));
    fetch.release.complete();
    expect((await preparation).status, 'cancelled');
  });
  test('deactivate calls an optional adapter cleanup and permits restart',
      () async {
    final host = WasmHost(manifest(), policy: policy(), transport: Fetch());
    final adapter = CleanupAdapter();
    expect(await host.activate(adapter), 1);
    expect(await host.deactivate(), isTrue);
    expect(adapter.stops, 1);
    expect(await host.deactivate(), isFalse);
    expect(await host.activate(adapter), 2);
  });
  test('native transport MIME checks match manifest asset kinds', () {
    final asset =
        parseRelease(manifest(), ['https://assets.example']).assets.first;
    expect(responseContentTypeAllowed(asset, 'application/wasm'), isTrue);
    expect(responseContentTypeAllowed(asset, 'text/html'), isFalse);
    expect(responseContentTypeAllowed(asset, null), isFalse);
  });
  test(
      'a schema-shaped but unparseable asset URL raises a declared LoaderException',
      () {
    final r = manifest();
    r['assets'][0]['url'] = 'https://[/acme/engine.wasm';
    expect(
        () => WasmHost(r, policy: policy(), transport: Fetch()),
        throwsA(
            isA<LoaderException>().having((e) => e.code, 'code', 'origin')));
  });
}
