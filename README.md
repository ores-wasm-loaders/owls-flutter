# OWLS Dart and Flutter hosts

Verified public WASM assets and explicit activation for Flutter web, mobile and desktop.

Import owls_flutter.dart for platform-neutral policy, validation, byte storage and WasmHost. Import owls_native.dart for bounded HttpClient fetching and a per-product file cache. Import owls_webview.dart for the webview_flutter bridge (Android, iOS and macOS supported by the selected plugin; other desktop engines can implement the same protocol).

```dart
final host = WasmHost(manifest,
  policy: LoaderPolicy(origins: ['https://assets.example']),
  transport: const HttpAssetTransport(),
  store: FileByteStore(productCacheDirectory));
final warm = await host.prefetch();
// warm.status is warmed, failed, cancelled or skipped.
final app = await host.activate(productAdapter);
```

Implement AssetTransport, ByteStore or WasmAdapter<T>, or compose/subclass WasmHost for product-specific behavior. `prepare` returns a reference-counted `PreparationLease`; `prefetch` is its convenience form. Activation joins speculative preparation only for the bounded `activationJoin` policy (50 ms by default), then follows the normal demand path. Implement `WasmDeactivator<T>` when an adapter owns views or engine resources, and call `deactivate` before a deliberate restart. A WasmAdapter owns execution in a browser bridge, native FFI engine or product runtime. This package itself does not turn Flutter Web WasmGC or browser wasm-bindgen binaries into native Dart modules.

WebViewLoaderBridge sends fixed JSON commands to a retained first-party document using the browser package's createWebViewBridge, and waits for OwlsLoaderResults completion messages. Call attach before sending commands and dispose before discarding the WebView. The host must configure navigation restrictions and JavaScript explicitly. A changed document is rejected; do not expose this bridge to arbitrary web content.

Native files and browser HTTP/CacheStorage are separate caches. Prefetching native bytes does not automatically warm a WebView; either prepare inside its retained document or provide a platform URL/asset transport. HTTP preparation checks the manifest-kind MIME before hashing. FileByteStore limits each entry; the application owns total disk quota and old-release eviction. Flutter native engine startup differs from loading a Flutter Web application.

The pinned JSON Schema is embedded byte-for-byte and validated with a documented Draft-7 keyword-compatible projection for Dart's validator. Product consumers use a root dependency_overrides path to the Zed-installed owls_interfaces package; dependency overrides are application-owned.

Run flutter analyze and flutter test after Zed installation. See owls-docs for the immutable preview registry and external consumer instructions.
