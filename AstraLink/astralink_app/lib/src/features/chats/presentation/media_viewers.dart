import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../models.dart';

class ChatPhotoViewerPage extends StatelessWidget {
  final MessageAttachmentItem attachment;
  final String imageUrl;

  const ChatPhotoViewerPage({
    super.key,
    required this.attachment,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final title = attachment.fileName.trim().isEmpty
        ? 'Photo'
        : attachment.fileName.trim();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.75,
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.contain,
                    progressIndicatorBuilder: (context, url, progress) {
                      return Center(
                        child: CircularProgressIndicator(
                          value: progress.progress,
                          color: Colors.white,
                        ),
                      );
                    },
                    errorWidget: (context, url, error) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 44,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Text(
                    _buildPhotoMeta(attachment),
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildPhotoMeta(MessageAttachmentItem attachment) {
    final parts = <String>[];
    if (attachment.width != null && attachment.height != null) {
      parts.add('${attachment.width}x${attachment.height}');
    }
    parts.add(_formatBytes(attachment.sizeBytes));
    return parts.join(' • ');
  }
}

class ChatVideoViewerPage extends StatefulWidget {
  final MessageAttachmentItem attachment;
  final String videoUrl;

  const ChatVideoViewerPage({
    super.key,
    required this.attachment,
    required this.videoUrl,
  });

  @override
  State<ChatVideoViewerPage> createState() => _ChatVideoViewerPageState();
}

class _ChatVideoViewerPageState extends State<ChatVideoViewerPage> {
  late final VideoPlayerController _controller;
  late final Future<void> _initializeFuture;
  Timer? _overlayHideTimer;
  bool _showChrome = true;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    _initializeFuture = _controller.initialize().then((_) {
      _controller.setLooping(false);
      if (mounted) {
        setState(() {});
      }
    });
    _controller.addListener(_onControllerTick);
    _scheduleChromeAutoHide();
  }

  @override
  void dispose() {
    _overlayHideTimer?.cancel();
    _controller.removeListener(_onControllerTick);
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onControllerTick() {
    if (!mounted) return;
    setState(() {});
  }

  void _togglePlayback() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    _showChromeTemporarily();
  }

  void _toggleChrome() {
    setState(() => _showChrome = !_showChrome);
    if (_showChrome) {
      _scheduleChromeAutoHide();
    } else {
      _overlayHideTimer?.cancel();
    }
  }

  void _showChromeTemporarily() {
    if (!_showChrome && mounted) {
      setState(() => _showChrome = true);
    }
    _scheduleChromeAutoHide();
  }

  void _scheduleChromeAutoHide() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_controller.value.isPlaying) return;
      setState(() => _showChrome = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initializeFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const _MediaErrorState(label: 'Could not open video');
          }
          if (snapshot.connectionState != ConnectionState.done ||
              !_controller.value.isInitialized) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          final position = _controller.value.position;
          final duration = _controller.value.duration;
          final safeDuration = duration.inMilliseconds <= 0
              ? 1.0
              : duration.inMilliseconds.toDouble();
          final progress =
              (position.inMilliseconds / safeDuration).clamp(0.0, 1.0);

          return GestureDetector(
            onTap: _toggleChrome,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: _showChrome ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: IgnorePointer(
                      ignoring: !_showChrome,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.6),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.72),
                            ],
                          ),
                        ),
                        child: SafeArea(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: () => Navigator.of(context).pop(),
                                      icon: const Icon(
                                        Icons.arrow_back_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        widget.attachment.displayLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              Center(
                                child: IconButton.filled(
                                  style: IconButton.styleFrom(
                                    backgroundColor:
                                        Colors.black.withValues(alpha: 0.45),
                                    foregroundColor: Colors.white,
                                    iconSize: 34,
                                    padding: const EdgeInsets.all(16),
                                  ),
                                  onPressed: _togglePlayback,
                                  icon: Icon(
                                    _controller.value.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          _formatDuration(position),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          _formatDuration(duration),
                                          style: const TextStyle(
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6,
                                        ),
                                        overlayShape: SliderComponentShape.noOverlay,
                                      ),
                                      child: Slider(
                                        value: progress,
                                        onChanged: (value) {
                                          final target = Duration(
                                            milliseconds: (duration.inMilliseconds * value)
                                                .round(),
                                          );
                                          _controller.seekTo(target);
                                          _showChromeTemporarily();
                                        },
                                      ),
                                    ),
                                    Text(
                                      _buildVideoMeta(widget.attachment),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _buildVideoMeta(MessageAttachmentItem attachment) {
    final parts = <String>[];
    if (attachment.width != null && attachment.height != null) {
      parts.add('${attachment.width}x${attachment.height}');
    }
    if (attachment.durationSeconds != null) {
      parts.add(_formatDuration(Duration(seconds: attachment.durationSeconds!)));
    }
    parts.add(_formatBytes(attachment.sizeBytes));
    return parts.join(' • ');
  }
}

class _MediaErrorState extends StatelessWidget {
  final String label;

  const _MediaErrorState({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Colors.white70,
            size: 42,
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
