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

/// Our schema uses only Draft-7-compatible validation keywords.
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
WasmRelease parseRelease(Object? value, List<String> origins) {
  if (origins.isEmpty || origins.any((origin) => !_canonicalOrigin(origin))) {
    throw const LoaderException('origin', 'Canonical HTTPS origins required');
  }
  if (!_validator.validate(value).isValid) {
    throw const LoaderException('manifest', 'Release JSON Schema mismatch');
  }
  final r = WasmRelease.fromJson(value as Map<String, dynamic>);
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
