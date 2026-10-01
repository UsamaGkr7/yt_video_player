import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class VideoClip {
  const VideoClip({required this.start, required this.end, required this.note});

  final Duration start;
  final Duration end;
  final String note;

  Map<String, dynamic> toJson() => {
    'start': start.inMilliseconds,
    'end': end.inMilliseconds,
    'note': note,
  };

  factory VideoClip.fromJson(Map<String, dynamic> json) => VideoClip(
    start: Duration(milliseconds: json['start'] as int),
    end: Duration(milliseconds: json['end'] as int),
    note: json['note'] as String,
  );
}

/// The parts of a video that were actually played, as merged, sorted
/// [start, end) ranges. Unlike "furthest position reached", skipping ahead
/// does not count as watched.
class WatchedRanges {
  WatchedRanges([List<(Duration, Duration)>? ranges]) : _ranges = ranges ?? [];

  final List<(Duration, Duration)> _ranges;

  List<(Duration, Duration)> get ranges => List.unmodifiable(_ranges);

  Duration get total =>
      _ranges.fold(Duration.zero, (sum, range) => sum + (range.$2 - range.$1));

  void add(Duration start, Duration end) {
    if (end <= start) return;
    var newStart = start;
    var newEnd = end;
    // Drop every range that overlaps or touches the new one, widening the
    // new one to cover them, then insert it at its sorted position.
    _ranges.removeWhere((range) {
      if (range.$2 < newStart || range.$1 > newEnd) return false;
      if (range.$1 < newStart) newStart = range.$1;
      if (range.$2 > newEnd) newEnd = range.$2;
      return true;
    });
    final index = _ranges.indexWhere((range) => range.$1 > newStart);
    _ranges.insert(index == -1 ? _ranges.length : index, (newStart, newEnd));
  }

  List<List<int>> toJson() => [
    for (final (start, end) in _ranges)
      [start.inMilliseconds, end.inMilliseconds],
  ];

  factory WatchedRanges.fromJson(List<dynamic> json) => WatchedRanges([
    for (final pair in json)
      (
        Duration(milliseconds: (pair as List)[0] as int),
        Duration(milliseconds: pair[1] as int),
      ),
  ]);
}

/// One row of the watch history: what the user watched, how far they got and
/// when. Stored as a single JSON list so the history screen can load it in
/// one read.
class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.videoId,
    required this.lastWatched,
    this.title,
    this.channelName,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  final String videoId;
  final DateTime lastWatched;
  final String? title;
  final String? channelName;
  final Duration position;
  final Duration duration;

  String get thumbnailUrl =>
      'https://img.youtube.com/vi/$videoId/mqdefault.jpg';

  double? get progress => duration > Duration.zero
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : null;

  WatchHistoryEntry copyWith({
    DateTime? lastWatched,
    String? title,
    String? channelName,
    Duration? position,
    Duration? duration,
  }) => WatchHistoryEntry(
    videoId: videoId,
    lastWatched: lastWatched ?? this.lastWatched,
    title: title ?? this.title,
    channelName: channelName ?? this.channelName,
    position: position ?? this.position,
    duration: duration ?? this.duration,
  );

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'lastWatched': lastWatched.millisecondsSinceEpoch,
    'title': title,
    'channelName': channelName,
    'position': position.inMilliseconds,
    'duration': duration.inMilliseconds,
  };

  factory WatchHistoryEntry.fromJson(Map<String, dynamic> json) =>
      WatchHistoryEntry(
        videoId: json['videoId'] as String,
        lastWatched: DateTime.fromMillisecondsSinceEpoch(
          json['lastWatched'] as int,
        ),
        title: json['title'] as String?,
        channelName: json['channelName'] as String?,
        position: Duration(milliseconds: json['position'] as int? ?? 0),
        duration: Duration(milliseconds: json['duration'] as int? ?? 0),
      );
}

/// Local persistence for everything the player remembers between sessions:
/// bookmarks, resume position/history, view counts and the preferred speed.
class VideoStore {
  static const _historyKey = 'watch_history';
  static const _playbackRateKey = 'playback_rate';
  static const _maxHistoryEntries = 100;

  // History is read-modify-written from several places (periodic position
  // saves, metadata arriving, deletes), so writes are queued to stop two
  // overlapping updates from dropping each other's changes.
  static Future<void> _historyWrites = Future.value();

  static Future<void> _queueHistoryWrite(Future<void> Function() write) {
    final next = _historyWrites.then((_) => write());
    _historyWrites = next.catchError((_) {});
    return next;
  }

  static String _clipsKey(String videoId) => 'clips_$videoId';
  static String _viewCountKey(String videoId) => 'view_count_$videoId';
  static String _watchedKey(String videoId) => 'watched_$videoId';

  static Future<List<VideoClip>> loadClips(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_clipsKey(videoId));
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => VideoClip.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveClips(String videoId, List<VideoClip> clips) async {
    final prefs = await SharedPreferences.getInstance();
    if (clips.isEmpty) {
      await prefs.remove(_clipsKey(videoId));
      return;
    }
    await prefs.setString(
      _clipsKey(videoId),
      jsonEncode(clips.map((c) => c.toJson()).toList()),
    );
  }

  static Future<WatchedRanges> loadWatchedRanges(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_watchedKey(videoId));
    if (raw == null) return WatchedRanges();
    try {
      return WatchedRanges.fromJson(jsonDecode(raw) as List);
    } catch (_) {
      return WatchedRanges();
    }
  }

  static Future<void> saveWatchedRanges(
    String videoId,
    WatchedRanges ranges,
  ) async {
    // Encode before awaiting so later changes to [ranges] are not saved
    // under this call.
    final encoded = jsonEncode(ranges.toJson());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_watchedKey(videoId), encoded);
  }

  static Future<int> clipCount(String videoId) async =>
      (await loadClips(videoId)).length;

  static Future<int> incrementViewCount(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    final newCount = (prefs.getInt(_viewCountKey(videoId)) ?? 0) + 1;
    await prefs.setInt(_viewCountKey(videoId), newCount);
    return newCount;
  }

  static Future<List<WatchHistoryEntry>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return [];
    try {
      final entries = (jsonDecode(raw) as List)
          .map((e) => WatchHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      entries.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
      return entries;
    } catch (_) {
      return [];
    }
  }

  static Future<WatchHistoryEntry?> historyEntry(String videoId) async {
    final history = await loadHistory();
    for (final entry in history) {
      if (entry.videoId == videoId) return entry;
    }
    return null;
  }

  /// Merges [update] into the stored entry for its video (creating it if
  /// needed) and moves it to the top of the history.
  static Future<void> upsertHistory(WatchHistoryEntry update) =>
      _queueHistoryWrite(() async {
        final history = await loadHistory();
        final index = history.indexWhere((e) => e.videoId == update.videoId);
        final merged = index == -1
            ? update
            : history[index].copyWith(
                lastWatched: update.lastWatched,
                title: update.title,
                channelName: update.channelName,
                position: update.position,
                duration: update.duration > Duration.zero
                    ? update.duration
                    : null,
              );
        if (index != -1) history.removeAt(index);
        history.insert(0, merged);
        await _saveHistory(history.take(_maxHistoryEntries).toList());
      });

  static Future<void> removeHistory(String videoId) =>
      _queueHistoryWrite(() async {
        final history = await loadHistory();
        history.removeWhere((e) => e.videoId == videoId);
        await _saveHistory(history);
      });

  static Future<void> clearHistory() =>
      _queueHistoryWrite(() => _saveHistory([]));

  static Future<void> _saveHistory(List<WatchHistoryEntry> history) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  static Future<double> loadPlaybackRate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_playbackRateKey) ?? 1.0;
  }

  static Future<void> savePlaybackRate(double rate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_playbackRateKey, rate);
  }
}

String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}
