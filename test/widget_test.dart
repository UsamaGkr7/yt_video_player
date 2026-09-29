import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'package:ytvideoplayer/main.dart';
import 'package:ytvideoplayer/video_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('YoutubePlayerController.convertUrlToId', () {
    test('extracts video id from watch URL', () {
      expect(
        YoutubePlayerController.convertUrlToId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
    });

    test('extracts video id from youtu.be short URL', () {
      expect(
        YoutubePlayerController.convertUrlToId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('returns null for a non-YouTube URL', () {
      expect(
        YoutubePlayerController.convertUrlToId('https://example.com'),
        isNull,
      );
    });

    test('returns null for plain invalid text', () {
      expect(YoutubePlayerController.convertUrlToId('not a url'), isNull);
    });
  });

  testWidgets('shows an error when an invalid URL is submitted', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.tap(find.byTooltip('Load Video'));
    await tester.pump();

    expect(find.text('Please enter a valid YouTube URL'), findsOneWidget);
    expect(find.byType(YoutubePlayer), findsNothing);
  });

  group('VideoStore', () {
    test('bookmarks survive a round trip per video', () async {
      const clips = [
        VideoClip(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          note: 'Intro',
        ),
        VideoClip(
          start: Duration(seconds: 8),
          end: Duration(seconds: 10),
          note: 'Key point',
        ),
      ];
      await VideoStore.saveClips('abc', clips);

      final loaded = await VideoStore.loadClips('abc');
      expect(loaded.map((c) => c.note), ['Intro', 'Key point']);
      expect(loaded.last.start, const Duration(seconds: 8));
      expect(await VideoStore.loadClips('other'), isEmpty);
    });

    test('history keeps newest first and merges updates', () async {
      await VideoStore.upsertHistory(
        WatchHistoryEntry(
          videoId: 'a',
          lastWatched: DateTime(2026, 1, 1),
          title: 'Video A',
          duration: const Duration(minutes: 10),
        ),
      );
      await VideoStore.upsertHistory(
        WatchHistoryEntry(videoId: 'b', lastWatched: DateTime(2026, 1, 2)),
      );
      // A later position update without title/duration keeps the old ones.
      await VideoStore.upsertHistory(
        WatchHistoryEntry(
          videoId: 'a',
          lastWatched: DateTime(2026, 1, 3),
          position: const Duration(minutes: 4),
        ),
      );

      final history = await VideoStore.loadHistory();
      expect(history.map((e) => e.videoId), ['a', 'b']);
      expect(history.first.title, 'Video A');
      expect(history.first.position, const Duration(minutes: 4));
      expect(history.first.duration, const Duration(minutes: 10));
      expect(history.first.progress, closeTo(0.4, 0.001));

      await VideoStore.removeHistory('a');
      expect((await VideoStore.loadHistory()).map((e) => e.videoId), ['b']);
    });

    test('playback speed preference defaults to 1x', () async {
      expect(await VideoStore.loadPlaybackRate(), 1.0);
      await VideoStore.savePlaybackRate(1.5);
      expect(await VideoStore.loadPlaybackRate(), 1.5);
    });
  });

  testWidgets('shows recently watched videos on the start screen', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'watch_history':
          '[{"videoId":"dQw4w9WgXcQ","lastWatched":0,"title":"Saved video",'
          '"channelName":"Channel","position":60000,"duration":120000}]',
    });

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Saved video'), findsOneWidget);
    expect(find.text('1:00 / 2:00'), findsOneWidget);
  });
}
