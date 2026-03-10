import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AttachmentDownloadEvent {
  final double? progress;
  final File? file;

  const AttachmentDownloadEvent({this.progress, this.file});
}

class AstraAttachmentCache {
  AstraAttachmentCache._();

  static final AstraAttachmentCache instance = AstraAttachmentCache._();

  final BaseCacheManager _cache = CacheManager(
    Config(
      'astralinkAttachmentCache',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 512,
    ),
  );

  Future<File?> getCachedFile(String url) async {
    final cached = await _cache.getFileFromCache(url);
    return cached?.file;
  }

  Stream<AttachmentDownloadEvent> download(String url) async* {
    await for (final response in _cache.getFileStream(
      url,
      withProgress: true,
    )) {
      if (response is DownloadProgress) {
        yield AttachmentDownloadEvent(progress: response.progress);
      } else if (response is FileInfo) {
        yield AttachmentDownloadEvent(file: response.file, progress: 1);
      }
    }
  }

  Future<void> clear() => _cache.emptyCache();
}
