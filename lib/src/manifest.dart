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

/// Our released schema uses only Draft-7-compatible validation keywords.
/// Rewrite definition pointers; do not silently discard validation keywords.
Map<String, dynamic> _draft7() {
  final text = releaseSchemaJson
      .replaceAll('https://json-schema.org/draft/2020-12/schema',
          'http://json-schema.org/draft-07/schema#')
      .replaceAll(r'"$defs"', '"definitions"')
      .replaceAll(r'#/$defs/', '#/definitions/');
  return jsonDecode(text) as Map<String, dynamic>;
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

/// Detach and normalize only the release-v1 fields declared as JSON Schema integers.
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
      asset['bytes'] =
          _jsonInteger(asset['bytes'], r'$.assets[].bytes');
      return asset;
    }, growable: false);
  }
  return release;
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
