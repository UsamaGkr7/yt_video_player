import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'package:ytvideoplayer/main.dart';

void main() {
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
}
