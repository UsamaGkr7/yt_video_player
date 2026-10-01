import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'package:ytvideoplayer/history_screen.dart';
import 'package:ytvideoplayer/main.dart';
import 'package:ytvideoplayer/notes_pdf.dart';
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

  group('WatchedRanges', () {
    Duration s(int seconds) => Duration(seconds: seconds);

    test('merges overlapping and touching ranges', () {
      final ranges = WatchedRanges()
        ..add(s(0), s(10))
        ..add(s(30), s(40))
        ..add(s(10), s(12))
        ..add(s(35), s(50))
        ..add(s(20), s(25));

      expect(ranges.ranges, [(s(0), s(12)), (s(20), s(25)), (s(30), s(50))]);
      expect(ranges.total, s(37));
    });

    test(
      'skipped parts do not count and re-watching is not double counted',
      () {
        final ranges = WatchedRanges()
          ..add(s(0), s(60))
          ..add(s(0), s(60));
        expect(ranges.total, s(60));
      },
    );

    test('survives a JSON round trip', () {
      final ranges = WatchedRanges()
        ..add(s(5), s(10))
        ..add(s(20), s(30));
      final restored = WatchedRanges.fromJson(ranges.toJson());
      expect(restored.ranges, ranges.ranges);
    });
  });

  group('buildNotesPdf', () {
    test(
      'creates a PDF for bookmarks, including a note longer than a page',
      () async {
        final longNote =
            'Heading\n${List.filled(400, 'A long line of notes.').join(' ')}';
        final bytes = await buildNotesPdf(
          videoId: 'dQw4w9WgXcQ',
          title: 'Test video',
          channelName: 'Channel',
          clips: [
            const VideoClip(
              start: Duration(seconds: 90),
              end: Duration(seconds: 120),
              note: 'Second',
            ),
            VideoClip(
              start: const Duration(seconds: 5),
              end: const Duration(seconds: 20),
              note: longNote,
            ),
          ],
        );

        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1000));
      },
    );

    test('links to the bookmark start time', () {
      expect(
        videoUrlAt('abc', const Duration(minutes: 1, seconds: 5)),
        'https://www.youtube.com/watch?v=abc&t=65s',
      );
    });
  });

  test('combined PDF holds bookmarks from several videos', () async {
    const clip = VideoClip(
      start: Duration(seconds: 1),
      end: Duration(seconds: 4),
      note: 'Point',
    );
    final videos = [
      const VideoNotes(videoId: 'a', title: 'First', clips: [clip, clip]),
      const VideoNotes(videoId: 'b', title: 'Second', clips: [clip]),
    ];

    final bytes = await buildCombinedNotesPdf(videos: videos);

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(notesPdfFilename(videos), 'combined-video-notes.pdf');
    expect(notesPdfFilename(videos.take(1).toList()), 'First-notes.pdf');
  });

  testWidgets('history select mode picks videos with bookmarks in order', (
    WidgetTester tester,
  ) async {
    const clips =
        '[{"start":1000,"end":4000,"note":"A"},'
        '{"start":5000,"end":9000,"note":"B"}]';
    SharedPreferences.setMockInitialValues({
      'watch_history':
          '[{"videoId":"vid1","lastWatched":3,"title":"Video one"},'
          '{"videoId":"vid2","lastWatched":2,"title":"Video two"},'
          '{"videoId":"vid3","lastWatched":1,"title":"Video three"}]',
      'clips_vid1': clips,
      'clips_vid3': '[{"start":0,"end":2000,"note":"C"}]',
    });

    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('Select videos'), findsOneWidget);

    // Pick video three first, then video one; video two has no bookmarks.
    await tester.tap(find.text('Video three'));
    await tester.tap(find.text('Video one'));
    await tester.tap(find.text('Video two'));
    await tester.pumpAndSettle();

    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('2 videos · 3 bookmarks'), findsOneWidget);
    expect(
      find.text('This video has no bookmarks to combine yet.'),
      findsOneWidget,
    );
    // Selection order badges: video three is 1, video one is 2.
    final badges = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(CircleAvatar),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .toList();
    expect(badges, ['2', '1']);
  });
}
