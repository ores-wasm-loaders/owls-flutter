import 'dart:convert';
import 'package:json_schema/json_schema.dart';
import 'package:owls_interfaces/owls_interfaces.dart';
import 'release_schema.dart';

class LoaderException implements Exception {
  final String code;
  final String message;
  const LoaderException(this.code, this.message);
  @override
  String toString() => 'LoaderException($code): $message';
}

const _compositionKeywords = {
  'allOf',
  'anyOf',
  'oneOf',
  'not',
  'if',
  'then',
  'else',
  'dependentSchemas',
};

Object? _draft7Node(
  Object? value,
  Set<String> definitions, {
  required bool isRoot,
}) {
  if (value is List) {
    return value
        .map((entry) => _draft7Node(entry, definitions, isRoot: false))
        .toList(growable: false);
  }
  if (value is! Map) return value;

  final source = Map<String, dynamic>.from(value);
  if (source.containsKey('unevaluatedProperties')) {
    if (source.containsKey('additionalProperties') ||
        _compositionKeywords.any(source.containsKey)) {
      throw StateError(
          'Cannot lower unevaluatedProperties to Draft 7 without changing semantics');
    }
  }

  final result = <String, dynamic>{};
  for (final entry in source.entries) {
    var key = entry.key;
    var child = entry.value;
    if (key == r'$schema') {
      if (!isRoot) continue;
      if (child == 'https://json-schema.org/draft/2020-12/schema') {
        child = 'http://json-schema.org/draft-07/schema#';
      }
    } else if (key == r'$id' && !isRoot) {
      // Draft 2020-12 allows each $defs entry to be its own resource. After
      // lowering bare resource references to local Draft 7 definitions, those
      // nested IDs would change the base URI and make #/definitions/... point
      // at the wrong resource. The root ID remains intact for diagnostics.
      continue;
    } else if (key == r'$defs') {
      key = 'definitions';
    } else if (key == 'unevaluatedProperties') {
      key = 'additionalProperties';
    } else if (key == r'$ref' && child is String) {
      if (child.startsWith(r'#/$defs/')) {
        child = '#/definitions/${child.substring(r'#/$defs/'.length)}';
      } else if (definitions.contains(child)) {
        child = '#/definitions/$child';
      }
    }
    result[key] = _draft7Node(child, definitions, isRoot: false);
  }
  return result;
}

/// Lower the supported OWLS Draft 2020-12 subset into the validator's Draft 7
/// representation. Refuse constructs for which `unevaluatedProperties` cannot
/// be represented by `additionalProperties` without changing semantics.
Map<String, dynamic> _draft7() {
  final decoded = jsonDecode(releaseSchemaJson);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('Release Schema A root must be an object');
  }
  final definitions = decoded[r'$defs'];
  final names = definitions is Map
      ? definitions.keys.whereType<String>().toSet()
      : <String>{};
  return _draft7Node(decoded, names, isRoot: true) as Map<String, dynamic>;
}

final _validator = JsonSchema.create(_draft7());

int _jsonInteger(Object? value, String path) {
  if (value is int) return value;
  if (value is double &&
      value.isFinite &&
      value.abs() <= 9007199254740991 &&
      value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw LoaderException('manifest', '$path must be an integer-valued number');
}

/// Detach and normalize only fields declared as JSON Schema integers.
/// JSON Schema accepts 1.0 as an integer; the strict Dart projection intentionally
/// accepts only `int` after this boundary conversion.
Map<String, dynamic> _normalizeJsonIntegers(Map<String, dynamic> value) {
  final release = Map<String, dynamic>.from(value);
  release['schemaVersion'] =
      _jsonInteger(release['schemaVersion'], r'$.schemaVersion');
  final assets = release['assets'];
  if (assets is List) {
    release['assets'] = List<dynamic>.generate(assets.length, (index) {
      final entry = assets[index];
      if (entry is! Map) return entry;
      final asset = Map<String, dynamic>.from(entry);
      asset['bytes'] = _jsonInteger(asset['bytes'], r'$.assets[].bytes');
      return asset;
    }, growable: false);
  }
  final budget = release['prepareBudget'];
  if (budget is Map) {
    final normalized = Map<String, dynamic>.from(budget);
    for (final field in const ['maxBytes', 'maxConcurrency']) {
      if (normalized.containsKey(field)) {
        normalized[field] =
            _jsonInteger(normalized[field], r'$.prepareBudget.' + field);
      }
    }
    release['prepareBudget'] = normalized;
  }
  return release;
}

/// Return a dependency-first, duplicate-free closure ending with [assetId].
///
/// This is consumer behavior over the TJSV-admitted wire projection, not a
/// third contract authority.
List<WasmAsset> dependencyClosure(WasmRelease release, String assetId) {
  final assets = <String, WasmAsset>{
    for (final asset in release.assets) asset.id: asset,
  };
  if (!assets.containsKey(assetId)) {
    throw const LoaderException('asset', 'Unknown dependency root');
  }
  final visiting = <String>{};
  final visited = <String>{};
  final ordered = <WasmAsset>[];

  void visit(String id) {
    if (visited.contains(id)) return;
    if (!visiting.add(id)) {
      throw LoaderException(
          'manifest', 'Asset dependency cycle encountered at `$id`');
    }
    final asset = assets[id];
    if (asset == null) {
      throw LoaderException(
          'manifest', 'Dependency references missing asset `$id`');
    }
    for (final dependency in asset.dependencies ?? const <String>[]) {
      visit(dependency);
    }
    visiting.remove(id);
    visited.add(id);
    ordered.add(asset);
  }

  visit(assetId);
  return List.unmodifiable(ordered);
}

WasmRelease parseRelease(Object? value, List<String> origins) {
  if (origins.isEmpty || origins.any((origin) => !_canonicalOrigin(origin))) {
    throw const LoaderException('origin', 'Canonical HTTPS origins required');
  }
  if (!_validator.validate(value).isValid) {
    throw const LoaderException('manifest', 'Release JSON Schema mismatch');
  }
  final r = WasmRelease.fromJson(
      _normalizeJsonIntegers(value as Map<String, dynamic>));
  final ids = <String>{}, urls = <String>{};
  for (final a in r.assets) {
    // A schema-valid string can still fail to parse; keep that failure inside
    // the declared LoaderException boundary.
    final u = Uri.tryParse(a.url);
    final canonicalUrl = u != null &&
        u.scheme == 'https' &&
        u.userInfo.isEmpty &&
        u.hasQuery == false &&
        u.hasFragment == false &&
        u.host.isNotEmpty &&
        u.toString() == a.url &&
        a.url.startsWith('https://') &&
        (a.url == u.origin || a.url.startsWith('${u.origin}/')) &&
        origins.contains(u.origin);
    if (!canonicalUrl) {
      throw const LoaderException(
          'origin', 'Canonical HTTPS allowlist required');
    }
    if (!ids.add(a.id) || !urls.add(a.url)) {
      throw const LoaderException('duplicate', 'Duplicate asset');
    }
  }

  for (final asset in r.assets) {
    final dependencies = <String>{};
    for (final dependency in asset.dependencies ?? const <String>[]) {
      if (dependency == asset.id) {
        throw LoaderException(
            'manifest', 'Asset `${asset.id}` cannot depend on itself');
      }
      if (!ids.contains(dependency)) {
        throw LoaderException('manifest',
            'Asset `${asset.id}` depends on missing asset `$dependency`');
      }
      if (!dependencies.add(dependency)) {
        throw LoaderException('manifest',
            'Asset `${asset.id}` repeats dependency `$dependency`');
      }
    }
  }
  // Traversing every root proves the bounded admitted graph is acyclic.
  for (final id in ids) {
    dependencyClosure(r, id);
  }

  final expected = switch (r.runtime) {
    'raw-wasm' => 'wasm',
    'wasm-bindgen' => 'module',
    _ => 'script'
  };
  if (!r.assets.any((a) => a.id == r.entrypoint && a.kind == expected)) {
    throw const LoaderException('entrypoint', 'Invalid entrypoint');
  }
  return r;
}

bool _canonicalOrigin(String value) {
  final u = Uri.tryParse(value);
  return u != null &&
      u.scheme == 'https' &&
      u.host.isNotEmpty &&
      u.host == u.host.toLowerCase() &&
      u.userInfo.isEmpty &&
      u.hasQuery == false &&
      u.hasFragment == false &&
      u.origin == value;
}
