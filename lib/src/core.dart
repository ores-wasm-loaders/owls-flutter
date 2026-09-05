import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:owls_interfaces/owls_interfaces.dart';
import 'manifest.dart';

class Cancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  bool get isCancelled => _cancelled;
  void check() {
    if (_cancelled) throw const LoaderException('cancelled', 'Cancelled');
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

class LoaderPolicy {
  final List<String> origins;
  final int maxPrepareBytes, maxAssetBytes;
  final bool allowPreparation;
  final Duration timeout;
  LoaderPolicy(
      {required List<String> origins,
      this.maxPrepareBytes = 8 * 1024 * 1024,
      this.maxAssetBytes = 64 * 1024 * 1024,
      this.allowPreparation = true,
      this.timeout = const Duration(seconds: 30)})
      : origins = List.unmodifiable(origins) {
    if (maxPrepareBytes < 1 || maxAssetBytes < 1 || timeout <= Duration.zero) {
      throw const LoaderException('budget', 'Invalid policy');
    }
  }
}

abstract interface class AssetTransport {
  Future<Uint8List> fetch(WasmAsset asset, Cancellation cancellation);
}

abstract interface class ByteStore {
  Future<Uint8List?> get(String digest);
  Future<void> put(String digest, Uint8List bytes);
}

class MemoryStore implements ByteStore {
  final int maxBytes;
  final _values = LinkedHashMap<String, Uint8List>();
  int _size = 0;
  MemoryStore({this.maxBytes = 64 * 1024 * 1024});
  @override
  Future<Uint8List?> get(String digest) async {
    final bytes = _values.remove(digest);
    if (bytes != null) _values[digest] = bytes;
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<void> put(String digest, Uint8List bytes) async {
    if (bytes.length > maxBytes) return;
    _size -= _values.remove(digest)?.length ?? 0;
    while (_size + bytes.length > maxBytes) {
      _size -= _values.remove(_values.keys.first)!.length;
    }
    _values[digest] = Uint8List.fromList(bytes);
    _size += bytes.length;
  }
}

typedef ReadAsset = Future<Uint8List> Function(String id);

abstract interface class WasmAdapter<T> {
  Future<T> activate(
      WasmRelease release, ReadAsset bytes, Cancellation cancellation);
}

void verifyBytes(WasmAsset asset, Uint8List bytes) {
  if (bytes.length != asset.bytes ||
      sha256.convert(bytes).toString() != asset.sha256) {
    throw const LoaderException('integrity', 'Asset size or SHA-256 mismatch');
  }
}

/// One immutable release per host. Keep the host alive to retain activation.
class WasmHost {
  final WasmRelease release;
  final LoaderPolicy policy;
  final AssetTransport transport;
  final ByteStore store;
  Future<void>? _preparing;
  Future<Object?>? _active;
  Object? _adapter;
  WasmHost(Object? manifest,
      {required this.policy, required this.transport, ByteStore? store})
      : release = parseRelease(manifest, policy.origins),
        store = store ?? MemoryStore();

  Future<Uint8List> bytes(String id, Cancellation cancellation) async {
    cancellation.check();
    final matches = release.assets.where((a) => a.id == id);
    if (matches.isEmpty) throw const LoaderException('asset', 'Unknown asset');
    final asset = matches.first;
    if (asset.bytes > policy.maxAssetBytes)
      throw const LoaderException('budget', 'Asset exceeds budget');
    Uint8List? cached;
    try {
      cached = await store.get(asset.sha256);
    } catch (_) {/* cache miss */}
    if (cached != null) {
      try {
        verifyBytes(asset, cached);
        cancellation.check();
        return cached;
      } on LoaderException catch (e) {
        if (e.code == 'cancelled') rethrow;
      }
    }
    final data = await transport
        .fetch(asset, cancellation)
        .timeout(policy.timeout, onTimeout: () {
      cancellation.cancel();
      throw const LoaderException('timeout', 'Asset timed out');
    });
    cancellation.check();
    verifyBytes(asset, data);
    try {
      await store.put(asset.sha256, data);
    } catch (_) {/* cache is optional */}
    return Uint8List.fromList(data);
  }

  Future<void> prefetch({Cancellation? cancellation}) {
    if (!policy.allowPreparation) return Future.value();
    if (cancellation == null && _preparing != null) return _preparing!;
    final own = cancellation ?? Cancellation();
    final assets = release.assets.where((a) => a.prepare).toList();
    if (assets.fold<int>(0, (n, a) => n + a.bytes) > policy.maxPrepareBytes ||
        assets.any((a) => a.bytes > policy.maxAssetBytes)) {
      return Future.error(
          const LoaderException('budget', 'Preparation exceeds budget'));
    }
    final timer = Timer(policy.timeout, own.cancel);
    final future = (() async {
      for (final a in assets) {
        await bytes(a.id, own);
      }
    })()
        .whenComplete(() {
      timer.cancel();
      if (cancellation == null) _preparing = null;
    });
    if (cancellation == null) _preparing = future;
    return future;
  }

  Future<T> activate<T>(WasmAdapter<T> adapter) {
    if (_active != null) {
      if (!identical(adapter, _adapter))
        return Future.error(const LoaderException(
            'adapter-conflict', 'Activation already has an owner'));
      return _active!.then((v) => v as T);
    }
    _adapter = adapter;
    final token = Cancellation();
    final future = (() async {
      try {
        await _preparing;
      } catch (_) {/* demand load retries */}
      return adapter.activate(release, (id) => bytes(id, token), token);
    })();
    _active = future;
    return future;
  }
}
