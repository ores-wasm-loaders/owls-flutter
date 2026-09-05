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
  if (!_validator.validate(value).isValid) {
    throw const LoaderException('manifest', 'Release JSON Schema mismatch');
  }
  final r = WasmRelease.fromJson(value as Map<String, dynamic>);
  final ids = <String>{}, urls = <String>{};
  for (final a in r.assets) {
    final u = Uri.parse(a.url);
    if (u.scheme != 'https' ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        u.host.isEmpty ||
        u.toString() != a.url ||
        !origins.contains(u.origin)) {
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
