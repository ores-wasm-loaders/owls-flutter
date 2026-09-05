import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:owls_interfaces/owls_interfaces.dart';
import 'core.dart';
import 'manifest.dart';

class HttpAssetTransport implements AssetTransport {
  final Duration timeout;
  const HttpAssetTransport({this.timeout = const Duration(seconds: 30)});
  @override
  Future<Uint8List> fetch(WasmAsset asset, Cancellation cancellation) async {
    cancellation.check();
    final client = HttpClient()..connectionTimeout = timeout;
    final unlisten = cancellation.listen(() => client.close(force: true));
    final timer = Timer(timeout, () => client.close(force: true));
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200)
        throw const LoaderException('http', 'Asset request failed');
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in response) {
        cancellation.check();
        if (chunks.length + chunk.length > asset.bytes)
          throw const LoaderException('budget', 'Asset too large');
        chunks.add(chunk);
      }
      return chunks.takeBytes();
    } finally {
      timer.cancel();
      unlisten();
      client.close(force: true);
    }
  }
}

/// Separate from WebView caches. A platform bridge must explicitly serve these bytes.
class FileByteStore implements ByteStore {
  final Directory directory;
  final int maxEntryBytes;
  const FileByteStore(this.directory, {this.maxEntryBytes = 64 * 1024 * 1024});
  File _file(String digest) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))
      throw const LoaderException('integrity', 'Invalid digest key');
    return File('${directory.path}/$digest');
  }

  @override
  Future<Uint8List?> get(String digest) async {
    final file = _file(digest);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) return null;
    final data = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (data.length + chunk.length > maxEntryBytes)
        throw const LoaderException('budget', 'Cached entry too large');
      data.add(chunk);
    }
    return data.takeBytes();
  }

  @override
  Future<void> put(String digest, Uint8List bytes) async {
    if (bytes.length > maxEntryBytes) return;
    final target = _file(digest);
    await directory.create(recursive: true);
    final tempDir = await directory.createTemp('.owls-');
    try {
      final file = File('${tempDir.path}/bytes');
      await file.writeAsBytes(bytes, flush: true);
      await file.rename(target.path);
    } finally {
      await tempDir.delete(recursive: true);
    }
  }
}
