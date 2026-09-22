import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

const _brandGreen = Color(0xFF33A052);

void main() {
  runApp(const MyApp());
}

class VideoClip {
  const VideoClip({required this.start, required this.end, required this.note});

  final Duration start;
  final Duration end;
  final String note;
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

String _playerStateLabel(PlayerState state) {
  switch (state) {
    case PlayerState.playing:
      return 'Playing';
    case PlayerState.paused:
      return 'Paused';
    case PlayerState.buffering:
      return 'Buffering';
    case PlayerState.ended:
      return 'Finished';
    case PlayerState.cued:
      return 'Ready';
    case PlayerState.unStarted:
    case PlayerState.unknown:
      return 'Not started';
  }
}

IconData _playerStateIcon(PlayerState state) {
  switch (state) {
    case PlayerState.playing:
      return Icons.play_circle_fill;
    case PlayerState.paused:
      return Icons.pause_circle_filled;
    case PlayerState.buffering:
      return Icons.hourglass_bottom;
    case PlayerState.ended:
      return Icons.check_circle;
    case PlayerState.cued:
    case PlayerState.unStarted:
    case PlayerState.unknown:
      return Icons.radio_button_unchecked;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _brandGreen,
      primary: _brandGreen,
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'EwayPrint Video Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF0F0F0F),
          elevation: 0,
          scrolledUnderElevation: 1,
          surfaceTintColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        extensions: const [
          YoutubePlayerTheme(
            progressBarActiveColor: _brandGreen,
            progressBarBufferedColor: Color(0x6633A052),
          ),
        ],
      ),
      home: const YoutubePlayerScreen(),
    );
  }
}

class YoutubePlayerScreen extends StatefulWidget {
  const YoutubePlayerScreen({super.key});

  @override
  State<YoutubePlayerScreen> createState() => _YoutubePlayerScreenState();
}

class _YoutubePlayerScreenState extends State<YoutubePlayerScreen> {
  final TextEditingController _urlController = TextEditingController();
  YoutubePlayerController? _playerController;
  String? _errorText;

  String? _activeVideoId;
  String? _videoTitle;
  String? _channelName;
  bool _isLoadingMetadata = false;
  bool _metadataError = false;

  final List<VideoClip> _clips = [];
  double? _clipStartSeconds;
  double? _pendingClipStartSeconds;
  double? _pendingClipEndSeconds;
  final TextEditingController _noteController = TextEditingController();

  StreamSubscription<YoutubePlayerValue>? _valueSubscription;
  StreamSubscription<YoutubeVideoState>? _videoStateSubscription;
  PlayerState _playerState = PlayerState.unknown;
  bool _hasStartedPlaying = false;
  int _playCount = 0;
  Duration _furthestWatched = Duration.zero;
  Duration _videoDuration = Duration.zero;
  int _viewCount = 0;

  void _loadVideo() {
    final url = _urlController.text.trim();
    final videoId = YoutubePlayerController.convertUrlToId(url);

    _valueSubscription?.cancel();
    _videoStateSubscription?.cancel();

    if (videoId == null) {
      setState(() {
        _errorText = 'Please enter a valid YouTube URL';
        _playerController?.close();
        _playerController = null;
        _activeVideoId = null;
        _videoTitle = null;
        _channelName = null;
        _isLoadingMetadata = false;
        _metadataError = false;
        _clips.clear();
        _clipStartSeconds = null;
        _pendingClipStartSeconds = null;
        _pendingClipEndSeconds = null;
        _playerState = PlayerState.unknown;
        _hasStartedPlaying = false;
        _playCount = 0;
        _furthestWatched = Duration.zero;
        _videoDuration = Duration.zero;
        _viewCount = 0;
      });
      return;
    }

    _playerController?.close();
    final controller = YoutubePlayerController.fromVideoId(
      videoId: videoId,
      autoPlay: true,
    );
    setState(() {
      _errorText = null;
      _playerController = controller;
      _activeVideoId = videoId;
      _videoTitle = null;
      _channelName = null;
      _isLoadingMetadata = true;
      _metadataError = false;
      _clips.clear();
      _clipStartSeconds = null;
      _pendingClipStartSeconds = null;
      _pendingClipEndSeconds = null;
      _playerState = PlayerState.unknown;
      _hasStartedPlaying = false;
      _playCount = 0;
      _furthestWatched = Duration.zero;
      _videoDuration = Duration.zero;
      _viewCount = 0;
    });

    _valueSubscription = controller.stream.listen(_onPlayerValueChanged);
    _videoStateSubscription = controller.videoStateStream.listen(
      _onVideoStateChanged,
    );

    _fetchMetadata(videoId);
    _recordView(videoId);
  }

  // Persists how many times each video has been opened (per videoId) across
  // app restarts, so re-opening a video days later continues the same count
  // instead of starting over.
  Future<void> _recordView(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'view_count_$videoId';
    final newCount = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setInt(key, newCount);

    if (!mounted || videoId != _activeVideoId) return;
    setState(() => _viewCount = newCount);
  }

  // Tracks basic engagement: whether/how many times playback started, the
  // furthest point reached, and the total video length -- all in memory for
  // this session only (no backend yet).
  void _onPlayerValueChanged(YoutubePlayerValue value) {
    if (!mounted) return;
    final isNewlyPlaying =
        value.playerState == PlayerState.playing &&
        _playerState != PlayerState.playing;
    setState(() {
      _playerState = value.playerState;
      if (value.metaData.duration > Duration.zero) {
        _videoDuration = value.metaData.duration;
      }
      if (isNewlyPlaying) {
        _hasStartedPlaying = true;
        _playCount++;
      }
    });
  }

  void _onVideoStateChanged(YoutubeVideoState state) {
    if (!mounted) return;
    if (state.position > _furthestWatched) {
      setState(() => _furthestWatched = state.position);
    }
  }

  Future<void> _startClip() async {
    final controller = _playerController;
    if (controller == null) return;

    final seconds = await controller.currentTime;
    if (!mounted) return;
    setState(() => _clipStartSeconds = seconds);
  }

  Future<void> _stopClip() async {
    final controller = _playerController;
    final startSeconds = _clipStartSeconds;
    if (controller == null || startSeconds == null) return;

    final endSeconds = await controller.currentTime;
    if (!mounted) return;

    if (endSeconds <= startSeconds) {
      setState(() => _clipStartSeconds = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stop must be after the start point.')),
      );
      return;
    }

    _noteController.clear();
    setState(() {
      _clipStartSeconds = null;
      _pendingClipStartSeconds = startSeconds;
      _pendingClipEndSeconds = endSeconds;
    });
  }

  // The note entry lives inline in the page (not a showDialog overlay)
  // because on web the YouTube player is a real <iframe> that always
  // captures clicks at the browser level, even when a Flutter dialog is
  // drawn visually on top of it. Keeping this panel below the player
  // avoids overlapping the iframe's pixels entirely.
  void _saveClipNote() {
    final start = _pendingClipStartSeconds;
    final end = _pendingClipEndSeconds;
    if (start == null || end == null) return;

    final text = _noteController.text.trim();
    setState(() {
      _clips.add(
        VideoClip(
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(milliseconds: (end * 1000).round()),
          note: text.isEmpty ? 'Untitled clip' : text,
        ),
      );
      _pendingClipStartSeconds = null;
      _pendingClipEndSeconds = null;
    });
  }

  void _cancelClipNote() {
    setState(() {
      _pendingClipStartSeconds = null;
      _pendingClipEndSeconds = null;
    });
  }

  Future<void> _playClip(VideoClip clip) async {
    final controller = _playerController;
    final videoId = _activeVideoId;
    if (controller == null || videoId == null) return;

    // seekTo() sends two positional JS arguments, but on web that call is
    // relayed through a postMessage bridge whose handler only supports a
    // single JSON argument -- it silently fails there (works fine on
    // mobile/desktop, which run the JS directly). loadVideoById() sends a
    // single JSON object instead, so it works everywhere.
    await controller.loadVideoById(
      videoId: videoId,
      startSeconds: clip.start.inMilliseconds / 1000,
    );
  }

  void _deleteClip(VideoClip clip) {
    setState(() => _clips.remove(clip));
  }

  void _editClipNote(VideoClip clip, String newNote) {
    final index = _clips.indexOf(clip);
    if (index == -1) return;
    final trimmed = newNote.trim();
    setState(() {
      _clips[index] = VideoClip(
        start: clip.start,
        end: clip.end,
        note: trimmed.isEmpty ? 'Untitled clip' : trimmed,
      );
    });
  }

  // YouTube's oEmbed endpoint needs no API key but only exposes title and
  // channel name -- it has no description field.
  Future<void> _fetchMetadata(String videoId) async {
    final oEmbedUri = Uri.https('www.youtube.com', '/oembed', {
      'url': 'https://www.youtube.com/watch?v=$videoId',
      'format': 'json',
    });

    String? title;
    String? channelName;
    var hasError = false;

    try {
      final response = await http
          .get(oEmbedUri)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        title = data['title'] as String?;
        channelName = data['author_name'] as String?;
      } else {
        hasError = true;
      }
    } catch (_) {
      hasError = true;
    }

    if (!mounted || videoId != _activeVideoId) return;
    setState(() {
      _videoTitle = title;
      _channelName = channelName;
      _isLoadingMetadata = false;
      _metadataError = hasError;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _noteController.dispose();
    _valueSubscription?.cancel();
    _videoStateSubscription?.cancel();
    _playerController?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Image.asset('assets/images/logo.png', height: 32),
            const SizedBox(width: 10),
            const Text(
              'Video Player',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E5E5)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          hintText: 'Paste a YouTube video URL',
                          errorText: _errorText,
                          filled: true,
                          fillColor: const Color(0xFFF1F1F1),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: const BorderSide(
                              color: _brandGreen,
                              width: 1.5,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _loadVideo(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Material(
                      color: _brandGreen,
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: _loadVideo,
                        icon: const Icon(Icons.play_arrow, color: Colors.white),
                        tooltip: 'Load Video',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_playerController != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: YoutubePlayer(controller: _playerController!),
                  ),
                  const SizedBox(height: 12),
                  _VideoMetadata(
                    isLoading: _isLoadingMetadata,
                    hasError: _metadataError,
                    title: _videoTitle,
                    channelName: _channelName,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 180,
                        child: _StatCard(
                          icon: _playerStateIcon(_playerState),
                          label: 'Status',
                          value: _playerStateLabel(_playerState),
                        ),
                      ),
                      SizedBox(
                        width: 180,
                        child: _StatCard(
                          icon: Icons.play_arrow,
                          label: 'Play button clicks',
                          value: '$_playCount',
                          subtitle: _hasStartedPlaying
                              ? 'Started watching'
                              : 'Not played yet',
                        ),
                      ),
                      SizedBox(
                        width: 180,
                        child: _StatCard(
                          icon: Icons.visibility,
                          label: 'Views',
                          value: '$_viewCount',
                          subtitle: _viewCount > 1
                              ? 'Watched before'
                              : 'First time watching',
                        ),
                      ),
                      SizedBox(
                        width: 200,
                        child: _StatCard(
                          icon: Icons.bar_chart,
                          label: 'Watched',
                          value: _videoDuration > Duration.zero
                              ? '${_formatDuration(_furthestWatched)} / ${_formatDuration(_videoDuration)}'
                              : _formatDuration(_furthestWatched),
                          subtitle: _videoDuration > Duration.zero
                              ? '${(_furthestWatched.inMilliseconds / _videoDuration.inMilliseconds * 100).clamp(0, 100).round()}% complete'
                              : 'Duration not available yet',
                          progress: _videoDuration > Duration.zero
                              ? (_furthestWatched.inMilliseconds /
                                        _videoDuration.inMilliseconds)
                                    .clamp(0.0, 1.0)
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _clipStartSeconds == null &&
                                  _pendingClipStartSeconds == null
                              ? _startClip
                              : null,
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('Mark start'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _brandGreen,
                            side: const BorderSide(color: _brandGreen),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _clipStartSeconds != null
                              ? _stopClip
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Mark stop & save'),
                        ),
                      ),
                    ],
                  ),
                  if (_clipStartSeconds != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Recording clip from ${_formatDuration(Duration(milliseconds: (_clipStartSeconds! * 1000).round()))}...',
                      style: const TextStyle(
                        color: _brandGreen,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (_pendingClipStartSeconds != null &&
                      _pendingClipEndSeconds != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F1F1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Clip ${_formatDuration(Duration(milliseconds: (_pendingClipStartSeconds! * 1000).round()))} - ${_formatDuration(Duration(milliseconds: (_pendingClipEndSeconds! * 1000).round()))}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F0F0F),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _noteController,
                            autofocus: true,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              hintText: 'What happens in this clip?',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: _cancelClipNote,
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _saveClipNote,
                                child: const Text('Save bookmark'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_clips.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text(
                      'Bookmarks',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F0F0F),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._clips.map(
                      (clip) => _ClipTile(
                        clip: clip,
                        onPlay: () => _playClip(clip),
                        onDelete: () => _deleteClip(clip),
                        onEdit: (newNote) => _editClipNote(clip, newNote),
                      ),
                    ),
                  ],
                ] else
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F1F1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'No video loaded yet.',
                      style: TextStyle(color: Color(0xFF606060)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoMetadata extends StatelessWidget {
  const _VideoMetadata({
    required this.isLoading,
    required this.hasError,
    required this.title,
    required this.channelName,
  });

  final bool isLoading;
  final bool hasError;
  final String? title;
  final String? channelName;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Loading title...', style: TextStyle(color: Color(0xFF606060))),
        ],
      );
    }

    if (hasError || title == null) {
      return const Text(
        'Title unavailable',
        style: TextStyle(color: Color(0xFF606060), fontStyle: FontStyle.italic),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F0F0F),
          ),
        ),
        if (channelName != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(
                Icons.account_circle,
                size: 16,
                color: Color(0xFF606060),
              ),
              const SizedBox(width: 6),
              Text(
                channelName!,
                style: const TextStyle(color: Color(0xFF606060)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ClipTile extends StatelessWidget {
  const _ClipTile({
    required this.clip,
    required this.onPlay,
    required this.onDelete,
    required this.onEdit,
  });

  final VideoClip clip;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
  final ValueChanged<String> onEdit;

  Future<void> _openDetail(BuildContext context) async {
    final controller = TextEditingController(text: clip.note);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Clip ${_formatDuration(clip.start)} - ${_formatDuration(clip.end)}',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'What happens in this clip?',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) onEdit(result);
  }

  @override
  Widget build(BuildContext context) {
    final firstLine = clip.note.split('\n').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: ListTile(
        onTap: () => _openDetail(context),
        leading: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPlay,
          child: const CircleAvatar(
            backgroundColor: _brandGreen,
            foregroundColor: Colors.white,
            child: Icon(Icons.play_arrow),
          ),
        ),
        title: Text(
          firstLine.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF0F0F0F),
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          '${_formatDuration(clip.start)} - ${_formatDuration(clip.end)}',
          style: const TextStyle(
            fontWeight: FontWeight.w400,
            color: Color(0xFF0F0F0F),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () => _openDetail(context),
              icon: const Icon(
                Icons.visibility_outlined,
                color: Color(0xFF606060),
              ),
              tooltip: 'View full note',
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, color: Color(0xFF606060)),
              tooltip: 'Delete bookmark',
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.subtitle,
    this.progress,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? subtitle;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: _brandGreen),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF606060),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F0F0F),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: const TextStyle(color: Color(0xFF606060), fontSize: 12),
            ),
          ],
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: const Color(0xFFE5E5E5),
                valueColor: const AlwaysStoppedAnimation<Color>(_brandGreen),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
