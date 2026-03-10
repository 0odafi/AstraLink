import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

Future<String> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  void Function(double progress)? onProgress,
}) async {
  final supportDir = await getApplicationSupportDirectory();
  final updatesDir = Directory('${supportDir.path}/updates');
  if (!updatesDir.existsSync()) {
    updatesDir.createSync(recursive: true);
  }

  final target = File('${updatesDir.path}/$fileName');
  if (target.existsSync()) {
    target.deleteSync();
  }

  http.Client? client;
  IOSink? sink;
  try {
    client = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Could not download update (${response.statusCode})');
    }

    sink = target.openWrite();
    final totalBytes = response.contentLength;
    var receivedBytes = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes != null && totalBytes > 0) {
        onProgress?.call(receivedBytes / totalBytes);
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    onProgress?.call(1);
    return target.path;
  } finally {
    await sink?.close();
    client?.close();
  }
}
