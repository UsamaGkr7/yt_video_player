import 'dart:async';

import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'notes_pdf.dart';
import 'video_store.dart';

const _brandGreen = Color(0xFF33A052);

class _QueuedClip {
  const _QueuedClip({
    required this.video,
    required this.videoNumber,
    required this.clip,
  });

  final VideoNotes video;
  final int videoNumber;
  final VideoClip clip;
}

/// Plays the bookmarks of several videos back to back, in the order the
/// videos were picked, switching videos automatically between bookmarks.
class BookmarkPlaylistScreen extends StatefulWidget {
  const BookmarkPlaylistScreen({super.key, required this.videos});

  final List<VideoNotes> videos;

  @override
  State<BookmarkPlaylistScreen> createState() => _BookmarkPlaylistScreenState();
}

class _BookmarkPlaylistScreenState extends State<BookmarkPlaylistScreen> {
  late final List<_QueuedClip> _queue = [
    for (final (index, video) in widget.videos.indexed)
      for (final clip in video.sortedClips)
        _QueuedClip(video: video, videoNumber: index + 1, clip: clip),
  ];

  late final YoutubePlayerController _controller;
  StreamSubscription<YoutubePlayerValue>? _valueSubscription;
  StreamSubscription<YoutubeVideoState>? _videoStateSubscription;

  int _index = 0;
  PlayerState _playerState = PlayerState.unknown;
  double _playbackRate = 1.0;
  bool _finished = false;
  bool _isAdvancing = false;
  bool _isExporting = false;
  // After jumping to a bookmark, position updates can still come from the
  // previous video or position for a moment; ignore end checks until the
  // jump has landed inside the new bookmark.
  bool _seekLanded = false;

  @override
  void initState() {
    super.initState();
    final first = _queue.first;
    _controller = YoutubePlayerController.fromVideoId(
      videoId: first.video.videoId,
      autoPlay: true,
      startSeconds: first.clip.start.inMilliseconds / 1000,
    );
    _valueSubscription = _controller.stream.listen(_onPlayerValueChanged);
    _videoStateSubscription = _controller.videoStateStream.listen(
      _onVideoStateChanged,
    );
    VideoStore.loadPlaybackRate().then((rate) => _playbackRate = rate);
  }

  @override
  void dispose() {
    _valueSubscription?.cancel();
    _videoStateSubscription?.cancel();
    _controller.close();
    super.dispose();
  }

  _QueuedClip get _current => _queue[_index];

  void _onPlayerValueChanged(YoutubePlayerValue value) {
    if (!mounted) return;
    final isNewlyPlaying =
        value.playerState == PlayerState.playing &&
        _playerState != PlayerState.playing;
    setState(() => _playerState = value.playerState);
    // Loading another video can reset the speed, so re-apply the user's
    // chosen speed whenever playback (re)starts.
    if (isNewlyPlaying) _controller.setPlaybackRate(_playbackRate);
  }

  void _onVideoStateChanged(YoutubeVideoState state) {
    if (!mounted || _finished) return;
    final current = _current;
    final loadedVideoId = _controller.value.metaData.videoId;
    final isRightVideo =
        loadedVideoId.isEmpty || loadedVideoId == current.video.videoId;

    if (!_seekLanded &&
        isRightVideo &&
        state.position >= current.clip.start - const Duration(seconds: 1) &&
        state.position < current.clip.end) {
      _seekLanded = true;
    }
    if (_seekLanded && state.position >= current.clip.end) {
      _advance();
    }
  }

  Future<void> _advance() async {
    if (_isAdvancing) return;
    _isAdvancing = true;
    try {
      if (_index + 1 >= _queue.length) {
        setState(() => _finished = true);
        await _controller.pauseVideo();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Finished playing all bookmarks.')),
        );
        return;
      }
      await _playAt(_index + 1);
    } finally {
      _isAdvancing = false;
    }
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    setState(() {
      _index = index;
      _finished = false;
      _seekLanded = false;
    });
    final item = _queue[index];
    // loadVideoById works on every platform (seekTo silently fails on web)
    // and also switches videos when the next bookmark is in another one.
    await _controller.loadVideoById(
      videoId: item.video.videoId,
      startSeconds: item.clip.start.inMilliseconds / 1000,
    );
  }

  Future<void> _export({required bool print}) async {
    if (_isExporting) return;
    if (_playerState == PlayerState.playing) _controller.pauseVideo();
    setState(() => _isExporting = true);
    try {
      await printOrShareNotes(widget.videos, print: print);
    } catch (error, stackTrace) {
      debugPrint('Notes PDF export failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the PDF: $error')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final noteLines = current.clip.note.split('\n');
    final noteBody = noteLines.skip(1).join('\n').trim();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Bookmark playlist',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        actions: [
          if (_isExporting)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            // IconButton(
            //   onPressed: () => _export(print: true),
            //   icon: const Icon(Icons.print_outlined, color: _brandGreen),
            //   tooltip: 'Print combined notes',
            // ),
            IconButton(
              onPressed: () => _export(print: false),
              icon: const Icon(
                Icons.picture_as_pdf_outlined,
                color: _brandGreen,
              ),
              tooltip: 'Save combined notes as PDF',
            ),
          ],
          const SizedBox(width: 8),
        ],
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: YoutubePlayer(controller: _controller),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F8F3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _finished
                            ? 'Finished · ${_queue.length} bookmarks'
                            : 'Bookmark ${_index + 1} of ${_queue.length} · '
                                  'Video ${current.videoNumber} of '
                                  '${widget.videos.length}',
                        style: const TextStyle(
                          color: _brandGreen,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        current.video.title ?? 'Untitled video',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F0F0F),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${formatDuration(current.clip.start)} - '
                        '${formatDuration(current.clip.end)}  ·  '
                        '${noteLines.first}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F0F0F),
                        ),
                      ),
                      if (noteBody.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          noteBody,
                          style: const TextStyle(color: Color(0xFF606060)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.outlined(
                      onPressed: _index > 0 ? () => _playAt(_index - 1) : null,
                      icon: const Icon(Icons.skip_previous),
                      tooltip: 'Previous bookmark',
                      color: _brandGreen,
                    ),
                    const SizedBox(width: 12),
                    IconButton.outlined(
                      onPressed: () => _playAt(_index),
                      icon: const Icon(Icons.replay),
                      tooltip: 'Replay this bookmark',
                      color: _brandGreen,
                    ),
                    const SizedBox(width: 12),
                    IconButton.outlined(
                      onPressed: _index + 1 < _queue.length
                          ? () => _playAt(_index + 1)
                          : null,
                      icon: const Icon(Icons.skip_next),
                      tooltip: 'Next bookmark',
                      color: _brandGreen,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                for (final (videoIndex, video) in widget.videos.indexed) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Text(
                      '${videoIndex + 1}. ${video.title ?? 'Untitled video'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F0F0F),
                      ),
                    ),
                  ),
                  for (final (queueIndex, item) in _queue.indexed)
                    if (identical(item.video, video))
                      _QueueTile(
                        item: item,
                        number: queueIndex + 1,
                        isCurrent: queueIndex == _index && !_finished,
                        onTap: () => _playAt(queueIndex),
                      ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.item,
    required this.number,
    required this.isCurrent,
    required this.onTap,
  });

  final _QueuedClip item;
  final int number;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isCurrent ? const Color(0xFFF1F8F3) : const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCurrent ? _brandGreen : const Color(0xFFE5E5E5),
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: isCurrent ? _brandGreen : const Color(0xFFE5E5E5),
          foregroundColor: isCurrent ? Colors.white : const Color(0xFF0F0F0F),
          child: isCurrent
              ? const Icon(Icons.play_arrow)
              : Text(
                  '$number',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
        title: Text(
          item.clip.note.split('\n').first,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF0F0F0F),
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          '${formatDuration(item.clip.start)} - '
          '${formatDuration(item.clip.end)}',
        ),
      ),
    );
  }
}
