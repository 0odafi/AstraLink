import 'update_downloader_stub.dart'
    if (dart.library.io) 'update_downloader_io.dart' as impl;

Future<String> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  void Function(double progress)? onProgress,
}) {
  return impl.downloadUpdatePackage(
    downloadUrl: downloadUrl,
    fileName: fileName,
    onProgress: onProgress,
  );
}
