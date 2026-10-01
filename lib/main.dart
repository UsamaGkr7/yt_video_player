import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'history_screen.dart';
import 'notes_pdf.dart';
import 'video_store.dart';

const _brandGreen = Color(0xFF33A052);

const _playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

// Resuming a few seconds in, or a few seconds before the end, is more
// annoying than useful, so those positions start from the beginning instead.
const _resumeMargin = Duration(seconds: 10);
const _progressSaveInterval = Duration(seconds: 5);
// Consecutive position updates further apart than this are treated as a
// seek rather than playback, so skipped parts don't count as watched.
const _maxPlaybackStep = Duration(seconds: 3);

void main() {
  runApp(const MyApp());
}

String _formatRate(double rate) =>
    rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';

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
  late final AppLifecycleListener _lifecycleListener;
  YoutubePlayerController? _playerController;
  String? _errorText;

  String? _activeVideoId;
  String? _videoTitle;
  String? _channelName;
  bool _isLoadingMetadata = false;
  bool _metadataError = false;
  int _loadToken = 0;

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
  WatchedRanges _watched = WatchedRanges();
  Duration? _lastPlaybackSample;
  Duration _videoDuration = Duration.zero;
  int _viewCount = 0;

  Duration _currentPosition = Duration.zero;
  Duration _lastSavedPosition = Duration.zero;
  double _playbackRate = 1.0;
  double? _reportedPlaybackRate;
  bool _showShortcuts = false;
  bool _isExporting = false;

  List<WatchHistoryEntry> _recentHistory = [];
  Map<String, int> _recentClipCounts = {};

  List<VideoClip> _bookmarkPlaybackOrder = [];
  int _bookmarkPlaybackIndex = -1;
  bool _isPlayingBookmarks = false;
  bool _isAdvancingBookmark = false;
  // After jumping to the next bookmark, position updates can still report
  // the old position for a moment; ignore end checks until the jump lands.
  bool _bookmarkSeekLanded = false;

  bool get _canMarkStart =>
      _clipStartSeconds == null &&
      _pendingClipStartSeconds == null &&
      !_isPlayingBookmarks;

  bool get _canMarkStop => _clipStartSeconds != null;

  Duration get _watchedTotal {
    final total = _watched.total;
    return _videoDuration > Duration.zero && total > _videoDuration
        ? _videoDuration
        : total;
  }

  double? get _watchedFraction => _videoDuration > Duration.zero
      ? (_watchedTotal.inMilliseconds / _videoDuration.inMilliseconds).clamp(
          0.0,
          1.0,
        )
      : null;

  @override
  void initState() {
    super.initState();
    // Save the resume position when the app is backgrounded or the browser
    // tab is hidden, since dispose() is not guaranteed to run in either case.
    _lifecycleListener = AppLifecycleListener(onHide: _saveProgress);
    HardwareKeyboard.instance.addHandler(_handleShortcut);
    _loadPreferences();
    _refreshRecentHistory();
  }

  Future<void> _loadPreferences() async {
    final rate = await VideoStore.loadPlaybackRate();
    if (!mounted) return;
    setState(() => _playbackRate = rate);
  }

  Future<void> _refreshRecentHistory() async {
    final history = (await VideoStore.loadHistory()).take(5).toList();
    final counts = <String, int>{
      for (final entry in history)
        entry.videoId: await VideoStore.clipCount(entry.videoId),
    };
    if (!mounted) return;
    setState(() {
      _recentHistory = history;
      _recentClipCounts = counts;
    });
  }

  void _closePlayer() {
    _valueSubscription?.cancel();
    _videoStateSubscription?.cancel();
    _playerController?.close();
  }

  // Must be called inside setState.
  void _resetVideoState() {
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
    _watched = WatchedRanges();
    _lastPlaybackSample = null;
    _videoDuration = Duration.zero;
    _viewCount = 0;
    _currentPosition = Duration.zero;
    _lastSavedPosition = Duration.zero;
    _reportedPlaybackRate = null;
    _bookmarkPlaybackOrder = [];
    _bookmarkPlaybackIndex = -1;
    _isPlayingBookmarks = false;
  }

  void _loadVideo() {
    final url = _urlController.text.trim();
    final videoId = YoutubePlayerController.convertUrlToId(url);

    if (videoId == null) {
      _saveProgress();
      _closePlayer();
      _loadToken++;
      setState(() {
        _resetVideoState();
        _errorText = 'Please enter a valid YouTube URL';
      });
      _refreshRecentHistory();
      return;
    }

    _openVideo(videoId);
  }

  Future<void> _openVideo(String videoId) async {
    _saveProgress();
    final token = ++_loadToken;

    final (entry, clips, watched) = await (
      VideoStore.historyEntry(videoId),
      VideoStore.loadClips(videoId),
      VideoStore.loadWatchedRanges(videoId),
    ).wait;
    // A newer load started while we were reading storage.
    if (!mounted || token != _loadToken) return;

    final resumeAt = _resumePositionFor(entry);
    _closePlayer();
    final controller = YoutubePlayerController.fromVideoId(
      videoId: videoId,
      autoPlay: true,
      startSeconds: resumeAt == null ? null : resumeAt.inMilliseconds / 1000,
    );
    setState(() {
      _resetVideoState();
      _errorText = null;
      _playerController = controller;
      _activeVideoId = videoId;
      _videoTitle = entry?.title;
      _channelName = entry?.channelName;
      _isLoadingMetadata = true;
      _videoDuration = entry?.duration ?? Duration.zero;
      _currentPosition = resumeAt ?? Duration.zero;
      _lastSavedPosition = _currentPosition;
      _clips
        ..addAll(clips)
        ..sort(_compareClips);
      _watched = watched;
    });

    _valueSubscription = controller.stream.listen(_onPlayerValueChanged);
    _videoStateSubscription = controller.videoStateStream.listen(
      _onVideoStateChanged,
    );
    // Leave the URL field so keyboard shortcuts work straight away.
    FocusManager.instance.primaryFocus?.unfocus();

    _writeHistory();
    _fetchMetadata(videoId);
    _recordView(videoId);

    if (resumeAt != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Resumed at ${formatDuration(resumeAt)}'),
            action: SnackBarAction(label: 'Start over', onPressed: _startOver),
          ),
        );
    }
  }

  Duration? _resumePositionFor(WatchHistoryEntry? entry) {
    if (entry == null || entry.position < _resumeMargin) return null;
    if (entry.duration > Duration.zero &&
        entry.duration - entry.position < _resumeMargin) {
      return null;
    }
    return entry.position;
  }

  Future<void> _startOver() async {
    final controller = _playerController;
    final videoId = _activeVideoId;
    if (controller == null || videoId == null) return;
    await controller.loadVideoById(videoId: videoId, startSeconds: 0);
  }

  // Persists how many times each video has been opened (per videoId) across
  // app restarts, so re-opening a video days later continues the same count
  // instead of starting over.
  Future<void> _recordView(String videoId) async {
    final newCount = await VideoStore.incrementViewCount(videoId);
    if (!mounted || videoId != _activeVideoId) return;
    setState(() => _viewCount = newCount);
  }

  void _writeHistory() {
    final videoId = _activeVideoId;
    if (videoId == null) return;
    _lastSavedPosition = _currentPosition;
    VideoStore.saveWatchedRanges(videoId, _watched);
    VideoStore.upsertHistory(
      WatchHistoryEntry(
        videoId: videoId,
        lastWatched: DateTime.now(),
        title: _videoTitle,
        channelName: _channelName,
        position: _currentPosition,
        duration: _videoDuration,
      ),
    );
  }

  // Positions reported before playback actually starts can be a stale 0
  // (before the resume seek lands), so only save once the video has played.
  void _saveProgress() {
    if (_hasStartedPlaying) _writeHistory();
  }

  void _persistClips() {
    final videoId = _activeVideoId;
    if (videoId == null) return;
    VideoStore.saveClips(videoId, List.of(_clips));
  }

  // Tracks basic engagement: whether/how many times playback started, the
  // furthest point reached, and the total video length. Play counts and
  // furthest point are per session; the resume position is persisted.
  void _onPlayerValueChanged(YoutubePlayerValue value) {
    if (!mounted) return;
    final isNewlyPlaying =
        value.playerState == PlayerState.playing &&
        _playerState != PlayerState.playing;
    final previousState = _playerState;
    final rateChangedInPlayer =
        _reportedPlaybackRate != null &&
        value.playbackRate != _reportedPlaybackRate &&
        !isNewlyPlaying;
    _reportedPlaybackRate = value.playbackRate;

    setState(() {
      _playerState = value.playerState;
      if (value.metaData.duration > Duration.zero) {
        _videoDuration = value.metaData.duration;
      }
      if (isNewlyPlaying) {
        _hasStartedPlaying = true;
        _playCount++;
      }
      if (value.playerState == PlayerState.ended) {
        _currentPosition = _videoDuration;
      }
      // Speed changed from YouTube's own settings menu: follow it.
      if (rateChangedInPlayer && _playbackRates.contains(value.playbackRate)) {
        _playbackRate = value.playbackRate;
      }
    });

    // loadVideoById (used for seeking and bookmarks) can reset the speed, so
    // re-apply the chosen speed every time playback (re)starts.
    if (isNewlyPlaying) {
      _playerController?.setPlaybackRate(_playbackRate);
    }
    if (previousState != value.playerState &&
        (value.playerState == PlayerState.paused ||
            value.playerState == PlayerState.ended)) {
      _saveProgress();
    }
  }

  void _onVideoStateChanged(YoutubeVideoState state) {
    if (!mounted) return;
    final lastSample = _lastPlaybackSample;
    _lastPlaybackSample = state.position;
    if (lastSample != null && _playerState == PlayerState.playing) {
      final step = state.position - lastSample;
      if (step > Duration.zero && step <= _maxPlaybackStep) {
        setState(() => _watched.add(lastSample, state.position));
      }
    }
    if (_hasStartedPlaying) {
      _currentPosition = state.position;
      if ((_currentPosition - _lastSavedPosition).abs() >=
          _progressSaveInterval) {
        _saveProgress();
      }
    }
    if (_isPlayingBookmarks &&
        _bookmarkPlaybackIndex >= 0 &&
        _bookmarkPlaybackIndex < _bookmarkPlaybackOrder.length) {
      final clip = _bookmarkPlaybackOrder[_bookmarkPlaybackIndex];
      if (!_bookmarkSeekLanded &&
          state.position >= clip.start - const Duration(seconds: 1) &&
          state.position < clip.end) {
        _bookmarkSeekLanded = true;
      }
      if (_bookmarkSeekLanded && state.position >= clip.end) {
        _advanceBookmarkPlayback();
      }
    }
  }

  Future<void> _togglePlayPause() async {
    final controller = _playerController;
    if (controller == null) return;
    if (_playerState == PlayerState.playing) {
      await controller.pauseVideo();
    } else {
      await controller.playVideo();
    }
  }

  Future<void> _skip(Duration offset) async {
    final controller = _playerController;
    final videoId = _activeVideoId;
    if (controller == null || videoId == null) return;

    final current = await controller.currentTime;
    var target = current + offset.inMilliseconds / 1000;
    if (target < 0) target = 0;
    if (_videoDuration > Duration.zero) {
      final max = _videoDuration.inMilliseconds / 1000 - 1;
      if (target > max) target = max;
    }

    // See _playClip: seekTo() silently fails on web, so use loadVideoById
    // there. Elsewhere seekTo() is preferred because it keeps a paused
    // video paused.
    if (kIsWeb) {
      await controller.loadVideoById(videoId: videoId, startSeconds: target);
    } else {
      await controller.seekTo(seconds: target, allowSeekAhead: true);
    }
  }

  Future<void> _setPlaybackRate(double rate) async {
    setState(() => _playbackRate = rate);
    VideoStore.savePlaybackRate(rate);
    await _playerController?.setPlaybackRate(rate);
  }

  void _stepPlaybackRate(int direction) {
    final index = _playbackRates.indexOf(_playbackRate);
    final next =
        (index == -1 ? _playbackRates.indexOf(1.0) : index) + direction;
    if (next < 0 || next >= _playbackRates.length) return;
    _setPlaybackRate(_playbackRates[next]);
  }

  Future<void> _openHistory() async {
    _saveProgress();
    if (_playerState == PlayerState.playing) _playerController?.pauseVideo();

    final videoId = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const HistoryScreen()));
    if (!mounted) return;
    _refreshRecentHistory();
    if (videoId != null) _openHistoryVideo(videoId);
  }

  void _openHistoryVideo(String videoId) {
    _urlController.text = 'https://www.youtube.com/watch?v=$videoId';
    _openVideo(videoId);
  }

  // A global handler rather than a Focus widget, because clicking empty
  // space (especially on web) can leave focus above this screen's widgets.
  // Shortcuts are ignored while another route or dialog is on top, while
  // typing in a text field and when a modifier is held, so they never
  // swallow text entry or browser/OS shortcuts. On web, keys pressed while
  // the YouTube iframe itself has focus go to YouTube's own shortcuts.
  // Returns true when the key was handled.
  bool _handleShortcut(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (_playerController == null) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return false;
    }

    final key = event.logicalKey;
    final isRepeat = event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowLeft) {
      _skip(const Duration(seconds: -5));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _skip(const Duration(seconds: 5));
    } else if (isRepeat) {
      return false;
    } else {
      switch (event.character?.toLowerCase()) {
        case ' ':
        case 'k':
          _togglePlayPause();
        case 'j':
          _skip(const Duration(seconds: -10));
        case 'l':
          _skip(const Duration(seconds: 10));
        case '[':
          if (_canMarkStart) _startClip();
        case ']':
          if (_canMarkStop) _stopClip();
        case '<':
          _stepPlaybackRate(-1);
        case '>':
          _stepPlaybackRate(1);
        case 'b':
          if (_clips.isNotEmpty) {
            _isPlayingBookmarks
                ? _stopBookmarkPlayback()
                : _startBookmarkPlayback();
          }
        case '?':
          setState(() => _showShortcuts = !_showShortcuts);
        default:
          return false;
      }
    }
    return true;
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
      _clips
        ..add(
          VideoClip(
            start: Duration(milliseconds: (start * 1000).round()),
            end: Duration(milliseconds: (end * 1000).round()),
            note: text.isEmpty ? 'Untitled clip' : text,
          ),
        )
        ..sort(_compareClips);
      _pendingClipStartSeconds = null;
      _pendingClipEndSeconds = null;
    });
    _persistClips();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _cancelClipNote() {
    setState(() {
      _pendingClipStartSeconds = null;
      _pendingClipEndSeconds = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _playClip(VideoClip clip) async {
    final controller = _playerController;
    final videoId = _activeVideoId;
    if (controller == null || videoId == null) return;

    if (_isPlayingBookmarks) {
      setState(() {
        _isPlayingBookmarks = false;
        _bookmarkPlaybackIndex = -1;
      });
    }

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

  // Plays every saved bookmark back to back (1-3, then 8-10, ...), skipping
  // everything in between. Bookmarks may be added in any order and may
  // overlap; they are played in order of their start time.
  Future<void> _startBookmarkPlayback() async {
    if (_clips.isEmpty) return;
    final ordered = List<VideoClip>.from(_clips)
      ..sort((a, b) => a.start.compareTo(b.start));
    setState(() {
      _bookmarkPlaybackOrder = ordered;
      _isPlayingBookmarks = true;
      _bookmarkPlaybackIndex = 0;
    });
    await _seekToBookmark(0);
  }

  Future<void> _stopBookmarkPlayback() async {
    setState(() {
      _isPlayingBookmarks = false;
      _bookmarkPlaybackIndex = -1;
    });
    await _playerController?.pauseVideo();
  }

  Future<void> _seekToBookmark(int index) async {
    final controller = _playerController;
    final videoId = _activeVideoId;
    if (controller == null || videoId == null) return;
    if (index < 0 || index >= _bookmarkPlaybackOrder.length) return;

    final clip = _bookmarkPlaybackOrder[index];
    _bookmarkSeekLanded = false;
    await controller.loadVideoById(
      videoId: videoId,
      startSeconds: clip.start.inMilliseconds / 1000,
    );
  }

  Future<void> _advanceBookmarkPlayback() async {
    if (_isAdvancingBookmark) return;
    _isAdvancingBookmark = true;
    try {
      final nextIndex = _bookmarkPlaybackIndex + 1;
      if (nextIndex >= _bookmarkPlaybackOrder.length) {
        setState(() {
          _isPlayingBookmarks = false;
          _bookmarkPlaybackIndex = -1;
        });
        await _playerController?.pauseVideo();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Finished playing all bookmarks.')),
        );
        return;
      }
      setState(() => _bookmarkPlaybackIndex = nextIndex);
      await _seekToBookmark(nextIndex);
    } finally {
      _isAdvancingBookmark = false;
    }
  }

  static int _compareClips(VideoClip a, VideoClip b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.end.compareTo(b.end);
  }

  Future<void> _exportNotes({required bool print}) async {
    final videoId = _activeVideoId;
    if (videoId == null || _clips.isEmpty || _isExporting) return;
    if (_playerState == PlayerState.playing) _playerController?.pauseVideo();

    setState(() => _isExporting = true);
    try {
      await printOrShareNotes([
        VideoNotes(
          videoId: videoId,
          title: _videoTitle,
          channelName: _channelName,
          clips: List.of(_clips),
        ),
      ], print: print);
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

  void _deleteClip(VideoClip clip) {
    setState(() => _clips.remove(clip));
    _persistClips();
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
    _persistClips();
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
    // Fall back to the title saved in history (e.g. when offline).
    setState(() {
      _videoTitle = title ?? _videoTitle;
      _channelName = channelName ?? _channelName;
      _isLoadingMetadata = false;
      _metadataError = hasError && _videoTitle == null;
    });
    if (title != null) _writeHistory();
  }

  @override
  void dispose() {
    _saveProgress();
    _lifecycleListener.dispose();
    HardwareKeyboard.instance.removeHandler(_handleShortcut);
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
        actions: [
          IconButton(
            onPressed: () => setState(() => _showShortcuts = !_showShortcuts),
            icon: const Icon(Icons.keyboard_outlined),
            tooltip: 'Keyboard shortcuts (?)',
          ),
          IconButton(
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
            tooltip: 'Watch history',
          ),
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
                  const SizedBox(height: 16),
                  _PlaybackControls(
                    playbackRate: _playbackRate,
                    onRateChanged: _setPlaybackRate,
                    onSkip: _skip,
                  ),
                  if (_showShortcuts) ...[
                    const SizedBox(height: 12),
                    _ShortcutsPanel(
                      onClose: () => setState(() => _showShortcuts = false),
                    ),
                  ],
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
                              ? '${formatDuration(_watchedTotal)} / ${formatDuration(_videoDuration)}'
                              : formatDuration(_watchedTotal),
                          subtitle: _watchedFraction != null
                              ? '${(_watchedFraction! * 100).round()}% actually watched'
                              : 'Duration not available yet',
                          progress: _watchedFraction,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _canMarkStart ? _startClip : null,
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
                          onPressed: _canMarkStop ? _stopClip : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Mark stop & save'),
                        ),
                      ),
                    ],
                  ),
                  if (_clipStartSeconds != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Recording clip from ${formatDuration(Duration(milliseconds: (_clipStartSeconds! * 1000).round()))}...',
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
                            'Clip ${formatDuration(Duration(milliseconds: (_pendingClipStartSeconds! * 1000).round()))} - ${formatDuration(Duration(milliseconds: (_pendingClipEndSeconds! * 1000).round()))}',
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            'Bookmarks',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F0F0F),
                            ),
                          ),
                        ),
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
                          //   onPressed: () => _exportNotes(print: true),
                          //   icon: const Icon(
                          //     Icons.print_outlined,
                          //     color: _brandGreen,
                          //   ),
                          //   tooltip: 'Print notes',
                          // ),
                          IconButton(
                            onPressed: () => _exportNotes(print: false),
                            icon: const Icon(
                              Icons.picture_as_pdf_outlined,
                              color: _brandGreen,
                            ),
                            tooltip: 'Save notes as PDF',
                          ),
                        ],
                        TextButton.icon(
                          onPressed: _isPlayingBookmarks
                              ? _stopBookmarkPlayback
                              : _startBookmarkPlayback,
                          icon: Icon(
                            _isPlayingBookmarks
                                ? Icons.stop_circle_outlined
                                : Icons.playlist_play,
                          ),
                          label: Text(
                            _isPlayingBookmarks
                                ? 'Stop (${_bookmarkPlaybackIndex + 1}/${_bookmarkPlaybackOrder.length})'
                                : 'Play bookmarks',
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: _brandGreen,
                          ),
                        ),
                      ],
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
                ] else if (_recentHistory.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Continue watching',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F0F0F),
                        ),
                      ),
                      TextButton(
                        onPressed: _openHistory,
                        style: TextButton.styleFrom(
                          foregroundColor: _brandGreen,
                        ),
                        child: const Text('See all'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ..._recentHistory.map(
                    (entry) => HistoryTile(
                      entry: entry,
                      clipCount: _recentClipCounts[entry.videoId] ?? 0,
                      onTap: () => _openHistoryVideo(entry.videoId),
                    ),
                  ),
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

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.playbackRate,
    required this.onRateChanged,
    required this.onSkip,
  });

  final double playbackRate;
  final ValueChanged<double> onRateChanged;
  final ValueChanged<Duration> onSkip;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.outlined(
          onPressed: () => onSkip(const Duration(seconds: -10)),
          icon: const Icon(Icons.replay_10),
          tooltip: 'Back 10 seconds (J)',
          color: _brandGreen,
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          onPressed: () => onSkip(const Duration(seconds: 10)),
          icon: const Icon(Icons.forward_10),
          tooltip: 'Forward 10 seconds (L)',
          color: _brandGreen,
        ),
        const SizedBox(width: 16),
        const Icon(Icons.speed, size: 18, color: Color(0xFF606060)),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final rate in _playbackRates)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(_formatRate(rate)),
                      selected: rate == playbackRate,
                      onSelected: (_) => onRateChanged(rate),
                      selectedColor: _brandGreen,
                      labelStyle: TextStyle(
                        color: rate == playbackRate
                            ? Colors.white
                            : const Color(0xFF0F0F0F),
                        fontWeight: FontWeight.w600,
                      ),
                      checkmarkColor: Colors.white,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// Shown inline rather than as a dialog for the same reason as the clip note
// panel: on web the YouTube iframe swallows clicks on anything drawn over it.
class _ShortcutsPanel extends StatelessWidget {
  const _ShortcutsPanel({required this.onClose});

  final VoidCallback onClose;

  static const _shortcuts = [
    ('Space / K', 'Play or pause'),
    ('← / →', 'Back / forward 5 seconds'),
    ('J / L', 'Back / forward 10 seconds'),
    ('[', 'Mark bookmark start'),
    (']', 'Mark bookmark stop'),
    ('< / >', 'Slower / faster'),
    ('B', 'Play or stop bookmarks'),
    ('?', 'Show or hide this list'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Keyboard shortcuts',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0F0F0F),
                  ),
                ),
              ),
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Close',
              ),
            ],
          ),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              for (final (keys, action) in _shortcuts)
                SizedBox(
                  width: 250,
                  child: Row(
                    children: [
                      Container(
                        constraints: const BoxConstraints(minWidth: 72),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE5E5E5)),
                        ),
                        child: Text(
                          keys,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          action,
                          style: const TextStyle(
                            color: Color(0xFF606060),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Click outside the video first — keys pressed while the video '
            'itself has focus go to YouTube.',
            style: TextStyle(color: Color(0xFF606060), fontSize: 12),
          ),
        ],
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
          'Clip ${formatDuration(clip.start)} - ${formatDuration(clip.end)}',
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
          '${formatDuration(clip.start)} - ${formatDuration(clip.end)}',
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
