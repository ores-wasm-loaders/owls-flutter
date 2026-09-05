// Generated from the pinned owls-interfaces release schema.
const releaseSchemaJson = r'''{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://ores-wasm-loaders.github.io/schemas/release-v1.json",
  "title": "WASM application release",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "appId",
    "release",
    "runtime",
    "entrypoint",
    "assets"
  ],
  "properties": {
    "schemaVersion": {
      "const": 1
    },
    "appId": {
      "type": "string",
      "pattern": "^[a-z0-9][a-z0-9-]{0,63}$"
    },
    "release": {
      "type": "string",
      "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
    },
    "runtime": {
      "enum": [
        "raw-wasm",
        "wasm-bindgen",
        "flutter-web"
      ]
    },
    "entrypoint": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128
    },
    "assets": {
      "type": "array",
      "minItems": 1,
      "maxItems": 512,
      "items": {
        "$ref": "#/$defs/asset"
      }
    },
    "extensions": {
      "type": "object"
    }
  },
  "$defs": {
    "asset": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "url",
        "kind",
        "bytes",
        "sha256",
        "prepare"
      ],
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        },
        "url": {
          "type": "string",
          "pattern": "^https://[^\\s]+$",
          "maxLength": 4096
        },
        "kind": {
          "enum": [
            "wasm",
            "module",
            "script",
            "data",
            "font"
          ]
        },
        "bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 268435456
        },
        "sha256": {
          "type": "string",
          "pattern": "^[0-9a-f]{64}$"
        },
        "prepare": {
          "type": "boolean"
        }
      }
    }
  }
}
''';
