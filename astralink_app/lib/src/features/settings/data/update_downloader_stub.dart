Future<String> downloadUpdatePackage({
  required String downloadUrl,
  required String fileName,
  void Function(double progress)? onProgress,
}) {
  throw UnsupportedError('In-app update download is not supported on this platform');
}
