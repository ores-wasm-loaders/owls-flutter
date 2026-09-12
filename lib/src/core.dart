import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:owls_interfaces/owls_interfaces.dart';
import 'manifest.dart';

class Cancellation {
  bool _cancelled = false;
  String? _reason;
  final _listeners = <void Function()>[];
  bool get isCancelled => _cancelled;
  String? get reason => _reason;
  void check() {
    if (_cancelled) {
      final code = _reason ?? 'cancelled';
      throw LoaderException(
          code, code == 'timeout' ? 'Timed out' : 'Cancelled');
    }
  }

  void Function() listen(void Function() listener) {
    if (_cancelled) {
      try {
        listener();
      } catch (_) {
        // A late listener cannot prevent the caller from observing cancellation.
      }
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void cancel([String reason = 'cancelled']) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final listener in List.of(_listeners)) {
      try {
        listener();
      } catch (_) {
        // Cancellation must reach every listener even if one cleanup hook fails.
      }
    }
    _listeners.clear();
  }
}

class LoaderPolicy {
  final List<String> origins;
  final int maxPrepareBytes, maxAssetBytes;
  final bool allowPreparation;
  final Duration timeout, activationJoin;
  LoaderPolicy(
      {required List<String> origins,
      this.maxPrepareBytes = 8 * 1024 * 1024,
      this.maxAssetBytes = 64 * 1024 * 1024,
      this.allowPreparation = true,
      this.timeout = const Duration(seconds: 30),
      Duration? activationJoin})
      : origins = List.unmodifiable(origins),
        activationJoin =
            (activationJoin ?? const Duration(milliseconds: 50)) > timeout
                ? timeout
                : (activationJoin ?? const Duration(milliseconds: 50)) {
    if (maxPrepareBytes < 1 ||
        maxAssetBytes < 1 ||
        timeout <= Duration.zero ||
        this.activationJoin < Duration.zero) {
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
  MemoryStore({this.maxBytes = 64 * 1024 * 1024}) {
    if (maxBytes < 1) {
      throw const LoaderException('budget', 'Invalid cache limit');
    }
  }
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

/// Optional lifecycle half for adapters that retain framework/runtime resources.
abstract interface class WasmDeactivator<T> {
  Future<void> deactivate(T instance);
}

void verifyBytes(WasmAsset asset, Uint8List bytes) {
  if (bytes.length != asset.bytes ||
      sha256.convert(bytes).toString() != asset.sha256) {
    throw const LoaderException('integrity', 'Asset size or SHA-256 mismatch');
  }
}

class PreparationOutcome {
  final String status;
  final List<String> prepared, skipped;
  final int bytes;
  final String? reason;
  PreparationOutcome(
      {required this.status,
      required List<String> prepared,
      required List<String> skipped,
      required this.bytes,
      this.reason})
      : prepared = List.unmodifiable(prepared),
        skipped = List.unmodifiable(skipped);
}

class PreparationLease {
  final Future<PreparationOutcome> future;
  final void Function() _release;
  bool _released = false;
  PreparationLease(this.future, this._release);
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _PreparationJob {
  final Cancellation cancellation;
  final leases = <Object>{};
  late Future<PreparationOutcome> future;
  bool claimed = false, settled = false;
  _PreparationJob(this.cancellation);
}

/// One immutable release per host. Keep the host alive to retain activation.
class WasmHost {
  final WasmRelease release;
  final LoaderPolicy policy;
  final AssetTransport transport;
  final ByteStore store;
  _PreparationJob? _preparing;
  Future<Object?>? _active;
  Object? _adapter;
  Future<void> Function(Object?)? _cleanup;
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
        if (e.code == 'cancelled' || e.code == 'timeout') rethrow;
      }
    }
    final data = await transport
        .fetch(asset, cancellation)
        .timeout(policy.timeout, onTimeout: () {
      cancellation.cancel('timeout');
      throw const LoaderException('timeout', 'Asset timed out');
    });
    cancellation.check();
    verifyBytes(asset, data);
    try {
      await store.put(asset.sha256, data);
    } catch (_) {/* cache is optional */}
    return Uint8List.fromList(data);
  }

  PreparationLease prepare({Cancellation? cancellation}) {
    if (!policy.allowPreparation) {
      return PreparationLease(
          Future.value(PreparationOutcome(
              status: 'skipped',
              prepared: const [],
              skipped: release.assets
                  .where((a) => a.prepare)
                  .map((a) => a.id)
                  .toList(),
              bytes: 0,
              reason: 'policy-declined')),
          () {});
    }
    final assets = release.assets.where((a) => a.prepare).toList();
    if (assets.fold<int>(0, (n, a) => n + a.bytes) > policy.maxPrepareBytes ||
        assets.any((a) => a.bytes > policy.maxAssetBytes)) {
      throw const LoaderException('budget', 'Preparation exceeds budget');
    }
    final job = _preparing ?? _newPreparation();
    final leaseKey = Object();
    job.leases.add(leaseKey);
    var released = false;
    void Function()? unlisten;
    void releaseLease() {
      if (released) return;
      released = true;
      job.leases.remove(leaseKey);
      unlisten?.call();
      if (!job.settled && !job.claimed && job.leases.isEmpty) {
        job.cancellation.cancel();
      }
    }

    if (cancellation != null) unlisten = cancellation.listen(releaseLease);
    return PreparationLease(job.future, releaseLease);
  }

  Future<PreparationOutcome> prefetch({Cancellation? cancellation}) {
    try {
      final lease = prepare(cancellation: cancellation);
      return lease.future
          .then((outcome) => cancellation?.isCancelled == true
              ? PreparationOutcome(
                  status: 'cancelled',
                  prepared: outcome.prepared,
                  skipped: outcome.skipped,
                  bytes: outcome.bytes,
                  reason: 'caller-aborted')
              : outcome)
          .whenComplete(lease.release);
    } catch (error) {
      return Future.error(error);
    }
  }

  /// Fetch, verify and cache one explicit asset dependency closure.
  ///
  /// Explicit intent may include lazy/prepare:false assets, but it does not
  /// execute framework or application code. Ambient [prepare] remains governed
  /// solely by the manifest's `prepare` flags.
  Future<PreparationOutcome> prefetchAsset(String id,
      {Cancellation? cancellation}) async {
    final assets = dependencyClosure(release, id);
    if (!policy.allowPreparation) {
      return _outcome(
          'skipped', assets, const <String>[], 'policy-declined');
    }
    if (assets.fold<int>(0, (n, asset) => n + asset.bytes) >
            policy.maxPrepareBytes ||
        assets.any((asset) => asset.bytes > policy.maxAssetBytes)) {
      throw const LoaderException('budget', 'Preparation exceeds budget');
    }

    final token = cancellation ?? Cancellation();
    final timer = Timer(policy.timeout, () => token.cancel('timeout'));
    final prepared = <String>[];
    try {
      token.check();
      for (final asset in assets) {
        await bytes(asset.id, token);
        prepared.add(asset.id);
      }
      return _outcome('warmed', assets, prepared, null);
    } catch (error) {
      final cancelled = token.isCancelled;
      return _outcome(cancelled ? 'cancelled' : 'failed', assets, prepared,
          token.reason ?? _reasonOf(error));
    } finally {
      timer.cancel();
    }
  }

  _PreparationJob _newPreparation() {
    final job = _PreparationJob(Cancellation());
    _preparing = job;
    final timer =
        Timer(policy.timeout, () => job.cancellation.cancel('timeout'));
    job.future = _runPreparation(job).whenComplete(() {
      timer.cancel();
      job.settled = true;
      if (identical(_preparing, job)) _preparing = null;
    });
    return job;
  }

  Future<PreparationOutcome> _runPreparation(_PreparationJob job) async {
    final assets = release.assets.where((a) => a.prepare).toList();
    final prepared = <String>[];
    try {
      for (final asset in assets) {
        await bytes(asset.id, job.cancellation);
        prepared.add(asset.id);
      }
      return _outcome('warmed', assets, prepared, null);
    } catch (error) {
      final cancelled = job.cancellation.isCancelled;
      return _outcome(cancelled ? 'cancelled' : 'failed', assets, prepared,
          job.cancellation.reason ?? _reasonOf(error));
    }
  }

  PreparationOutcome _outcome(String status, List<WasmAsset> assets,
      List<String> prepared, String? reason) {
    final preparedSet = prepared.toSet();
    return PreparationOutcome(
        status: status,
        prepared: prepared,
        skipped: assets
            .where((asset) => !preparedSet.contains(asset.id))
            .map((asset) => asset.id)
            .toList(),
        bytes: assets
            .where((asset) => preparedSet.contains(asset.id))
            .fold<int>(0, (n, asset) => n + asset.bytes),
        reason: reason);
  }

  Future<void> _joinPreparation(_PreparationJob job) async {
    if (job.settled) return;
    if (policy.activationJoin == Duration.zero) {
      job.cancellation.cancel();
      return;
    }
    try {
      await job.future.timeout(policy.activationJoin);
    } on TimeoutException {
      job.cancellation.cancel();
    } catch (_) {
      // Preparation outcomes are normally values; activation still owns retry.
    }
    if (!job.settled) job.cancellation.cancel();
  }

  Future<T> activate<T>(WasmAdapter<T> adapter) {
    if (_active != null) {
      if (!identical(adapter, _adapter))
        return Future.error(const LoaderException(
            'adapter-conflict', 'Activation already has an owner'));
      return _active!.then((v) => v as T);
    }
    final preparation = _preparing;
    if (preparation != null) preparation.claimed = true;
    _adapter = adapter;
    _cleanup = null;
    final token = Cancellation();
    final future = (() async {
      if (preparation != null) await _joinPreparation(preparation);
      final instance =
          await adapter.activate(release, (id) => bytes(id, token), token);
      if (adapter is WasmDeactivator<T>) {
        final deactivator = adapter as WasmDeactivator<T>;
        _cleanup = (value) => deactivator.deactivate(value as T);
      }
      return instance;
    })()
        .timeout(policy.timeout, onTimeout: () {
      token.cancel('timeout');
      throw const LoaderException('timeout', 'Activation timed out');
    });
    _active = future;
    return future;
  }

  /// Release a retained activation; a later activate call is then deliberate.
  Future<bool> deactivate() async {
    final active = _active;
    if (active == null) return false;
    try {
      final instance = await active;
      await _cleanup?.call(instance);
    } finally {
      _active = null;
      _adapter = null;
      _cleanup = null;
    }
    return true;
  }
}

String _reasonOf(Object error) {
  if (error is LoaderException) return error.code;
  if (error is TimeoutException) return 'timeout';
  return 'error';
}
