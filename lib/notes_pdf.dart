import 'package:barcode/barcode.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'video_store.dart';

const _brandGreen = PdfColor.fromInt(0xFF33A052);
const _textDark = PdfColor.fromInt(0xFF0F0F0F);
const _textMuted = PdfColor.fromInt(0xFF606060);
const _border = PdfColor.fromInt(0xFFE5E5E5);

String videoUrlAt(String videoId, Duration at) =>
    'https://www.youtube.com/watch?v=$videoId&t=${at.inSeconds}s';

/// Fonts and logo used by the notes PDF. Noto Sans is loaded (and cached by
/// the printing package) so notes in any language and characters like
/// curly quotes render; the built-in PDF fonts only cover basic Latin.
/// Falls back to the built-in fonts when offline.
class NotesPdfAssets {
  const NotesPdfAssets({this.regular, this.bold, this.logo});

  final pw.Font? regular;
  final pw.Font? bold;
  final Uint8List? logo;

  static Future<NotesPdfAssets> load() async {
    pw.Font? regular;
    pw.Font? bold;
    Uint8List? logo;
    try {
      (regular, bold) = await (
        PdfGoogleFonts.notoSansRegular(),
        PdfGoogleFonts.notoSansBold(),
      ).wait.timeout(const Duration(seconds: 8));
    } catch (_) {
      regular = null;
      bold = null;
    }
    try {
      logo = (await rootBundle.load(
        'assets/images/logo.png',
      )).buffer.asUint8List();
    } catch (_) {
      logo = null;
    }
    return NotesPdfAssets(regular: regular, bold: bold, logo: logo);
  }
}

/// One video's bookmarks, as passed to the PDF builders.
class VideoNotes {
  const VideoNotes({
    required this.videoId,
    required this.clips,
    this.title,
    this.channelName,
  });

  final String videoId;
  final String? title;
  final String? channelName;
  final List<VideoClip> clips;

  String get videoUrl => 'https://www.youtube.com/watch?v=$videoId';

  List<VideoClip> get sortedClips =>
      List.of(clips)..sort((a, b) => a.start.compareTo(b.start));
}

/// Builds a printable page of the user's bookmarks for one video: each
/// bookmark's time range, full note and a QR code that opens the video at
/// that moment.
Future<Uint8List> buildNotesPdf({
  required String videoId,
  required String? title,
  required String? channelName,
  required List<VideoClip> clips,
  NotesPdfAssets assets = const NotesPdfAssets(),
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? exportedAt,
}) {
  final video = VideoNotes(
    videoId: videoId,
    title: title,
    channelName: channelName,
    clips: clips,
  );
  final sorted = video.sortedClips;
  final date = exportedAt ?? DateTime.now();

  return _saveDocument(
    documentTitle: title == null ? 'Video notes' : 'Notes: $title',
    runningTitle: title ?? 'Video notes',
    assets: assets,
    format: format,
    content: [
      _header(
        logo: assets.logo,
        title: title,
        channelName: channelName,
        videoUrl: video.videoUrl,
        clipCount: sorted.length,
        date: date,
      ),
      pw.SizedBox(height: 20),
      if (sorted.isEmpty)
        pw.Text(
          'No bookmarks yet.',
          style: const pw.TextStyle(color: _textMuted),
        )
      else
        for (final (index, clip) in sorted.indexed)
          ..._clipBlock(videoId: videoId, index: index, clip: clip),
    ],
  );
}

/// Builds one PDF holding the bookmarks of several videos, in the given
/// order: a summary with a contents list, then a section per video.
Future<Uint8List> buildCombinedNotesPdf({
  required List<VideoNotes> videos,
  NotesPdfAssets assets = const NotesPdfAssets(),
  PdfPageFormat format = PdfPageFormat.a4,
  DateTime? exportedAt,
}) {
  if (videos.length == 1) {
    final video = videos.single;
    return buildNotesPdf(
      videoId: video.videoId,
      title: video.title,
      channelName: video.channelName,
      clips: video.clips,
      assets: assets,
      format: format,
      exportedAt: exportedAt,
    );
  }

  final date = exportedAt ?? DateTime.now();
  final clipCount = videos.fold(0, (sum, v) => sum + v.clips.length);

  return _saveDocument(
    documentTitle: 'Combined video notes',
    runningTitle: 'Combined video notes',
    assets: assets,
    format: format,
    content: [
      _summaryHeader(
        logo: assets.logo,
        videos: videos,
        clipCount: clipCount,
        date: date,
      ),
      for (final (index, video) in videos.indexed) ...[
        pw.SizedBox(height: 24),
        _videoSectionHeader(number: index + 1, video: video),
        pw.SizedBox(height: 4),
        if (video.clips.isEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 8),
            child: pw.Text(
              'No bookmarks.',
              style: const pw.TextStyle(color: _textMuted),
            ),
          )
        else
          for (final (clipIndex, clip) in video.sortedClips.indexed)
            ..._clipBlock(videoId: video.videoId, index: clipIndex, clip: clip),
      ],
    ],
  );
}

Future<Uint8List> _saveDocument({
  required String documentTitle,
  required String runningTitle,
  required NotesPdfAssets assets,
  required PdfPageFormat format,
  required List<pw.Widget> content,
}) {
  final doc = pw.Document(
    title: documentTitle,
    creator: 'EwayPrint Video Player',
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 32),
      theme: pw.ThemeData.withFont(base: assets.regular, bold: assets.bold),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 12),
              child: pw.Text(
                runningTitle,
                maxLines: 1,
                style: const pw.TextStyle(color: _textMuted, fontSize: 9),
              ),
            ),
      footer: (context) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 8),
        decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _border)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Made with EwayPrint Video Player',
              style: const pw.TextStyle(color: _textMuted, fontSize: 9),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(color: _textMuted, fontSize: 9),
            ),
          ],
        ),
      ),
      build: (context) => content,
    ),
  );

  return doc.save();
}

String _formatDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/'
    '${date.month.toString().padLeft(2, '0')}/${date.year}';

pw.Widget _summaryHeader({
  required Uint8List? logo,
  required List<VideoNotes> videos,
  required int clipCount,
  required DateTime date,
}) {
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 16),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _brandGreen, width: 2)),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (logo != null) ...[
          pw.Image(pw.MemoryImage(logo), height: 28),
          pw.SizedBox(height: 12),
        ],
        pw.Text(
          'VIDEO NOTES',
          style: pw.TextStyle(
            color: _brandGreen,
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Combined notes',
          style: pw.TextStyle(
            color: _textDark,
            fontSize: 20,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          '${videos.length} videos · $clipCount bookmark'
          '${clipCount == 1 ? '' : 's'} · Exported ${_formatDate(date)}',
          style: const pw.TextStyle(color: _textMuted, fontSize: 10),
        ),
        pw.SizedBox(height: 12),
        for (final (index, video) in videos.indexed)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 18,
                  child: pw.Text(
                    '${index + 1}.',
                    style: pw.TextStyle(
                      color: _brandGreen,
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    video.title ?? 'Untitled video',
                    maxLines: 2,
                    style: const pw.TextStyle(color: _textDark, fontSize: 10),
                  ),
                ),
                pw.SizedBox(width: 8),
                pw.Text(
                  '${video.clips.length} bookmark'
                  '${video.clips.length == 1 ? '' : 's'}',
                  style: const pw.TextStyle(color: _textMuted, fontSize: 10),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

pw.Widget _videoSectionHeader({
  required int number,
  required VideoNotes video,
}) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(12),
    decoration: pw.BoxDecoration(
      color: const PdfColor.fromInt(0xFFF1F8F3),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'VIDEO $number',
                style: pw.TextStyle(
                  color: _brandGreen,
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                video.title ?? 'Untitled video',
                style: pw.TextStyle(
                  color: _textDark,
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (video.channelName != null) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  video.channelName!,
                  style: const pw.TextStyle(color: _textMuted, fontSize: 10),
                ),
              ],
              pw.SizedBox(height: 4),
              pw.UrlLink(
                destination: video.videoUrl,
                child: pw.Text(
                  video.videoUrl,
                  style: const pw.TextStyle(
                    color: _brandGreen,
                    fontSize: 9,
                    decoration: pw.TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 12),
        pw.BarcodeWidget(
          barcode: Barcode.qrCode(),
          data: video.videoUrl,
          width: 56,
          height: 56,
          color: _textDark,
        ),
      ],
    ),
  );
}

pw.Widget _header({
  required Uint8List? logo,
  required String? title,
  required String? channelName,
  required String videoUrl,
  required int clipCount,
  required DateTime date,
}) {
  final dateText = _formatDate(date);
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 16),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _brandGreen, width: 2)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) ...[
                pw.Image(pw.MemoryImage(logo), height: 28),
                pw.SizedBox(height: 12),
              ],
              pw.Text(
                'VIDEO NOTES',
                style: pw.TextStyle(
                  color: _brandGreen,
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                title ?? 'Untitled video',
                style: pw.TextStyle(
                  color: _textDark,
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (channelName != null) ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  channelName,
                  style: const pw.TextStyle(color: _textMuted, fontSize: 11),
                ),
              ],
              pw.SizedBox(height: 8),
              pw.UrlLink(
                destination: videoUrl,
                child: pw.Text(
                  videoUrl,
                  style: const pw.TextStyle(
                    color: _brandGreen,
                    fontSize: 10,
                    decoration: pw.TextDecoration.underline,
                  ),
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                '$clipCount bookmark${clipCount == 1 ? '' : 's'} · '
                'Exported $dateText',
                style: const pw.TextStyle(color: _textMuted, fontSize: 10),
              ),
            ],
          ),
        ),
        pw.SizedBox(width: 16),
        pw.Column(
          children: [
            pw.BarcodeWidget(
              barcode: Barcode.qrCode(),
              data: videoUrl,
              width: 72,
              height: 72,
              color: _textDark,
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Scan to watch',
              style: const pw.TextStyle(color: _textMuted, fontSize: 8),
            ),
          ],
        ),
      ],
    ),
  );
}

// Returned as separate widgets rather than one box so a long note can
// flow onto the next page; MultiPage cannot split a single widget that is
// taller than a page.
List<pw.Widget> _clipBlock({
  required String videoId,
  required int index,
  required VideoClip clip,
}) {
  final url = videoUrlAt(videoId, clip.start);
  final lines = clip.note.split('\n');
  final heading = lines.first;
  final body = lines.skip(1).join('\n').trim();

  return [
    pw.Container(
      padding: const pw.EdgeInsets.only(top: 12),
      decoration: index == 0
          ? null
          : const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _border)),
            ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: 22,
            height: 22,
            alignment: pw.Alignment.center,
            decoration: const pw.BoxDecoration(
              color: _brandGreen,
              shape: pw.BoxShape.circle,
            ),
            child: pw.Text(
              '${index + 1}',
              style: pw.TextStyle(
                color: PdfColors.white,
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.UrlLink(
                  destination: url,
                  child: pw.Text(
                    '${formatDuration(clip.start)} - ${formatDuration(clip.end)}',
                    style: pw.TextStyle(
                      color: _brandGreen,
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  heading,
                  maxLines: 3,
                  style: pw.TextStyle(
                    color: _textDark,
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.BarcodeWidget(
            barcode: Barcode.qrCode(),
            data: url,
            width: 56,
            height: 56,
            color: _textDark,
          ),
        ],
      ),
    ),
    if (body.isNotEmpty)
      pw.Paragraph(
        text: body,
        margin: const pw.EdgeInsets.only(left: 34, right: 68, top: 4),
        style: const pw.TextStyle(
          color: _textDark,
          fontSize: 11,
          lineSpacing: 2,
        ),
      ),
    pw.SizedBox(height: 12),
  ];
}

String notesPdfFilename(List<VideoNotes> videos) {
  if (videos.length != 1) return 'combined-video-notes.pdf';
  final slug = (videos.single.title ?? '')
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-');
  if (slug.isEmpty) return 'video-notes.pdf';
  return '${slug.length > 60 ? slug.substring(0, 60) : slug}-notes.pdf';
}

/// Builds the notes PDF for [videos] and either opens the print dialog or
/// hands the file to the platform share sheet (a download on web). Throws
/// if the PDF cannot be built or handed off.
Future<void> printOrShareNotes(
  List<VideoNotes> videos, {
  required bool print,
}) async {
  final assets = await NotesPdfAssets.load();
  final filename = notesPdfFilename(videos);
  Future<Uint8List> build(PdfPageFormat format) =>
      buildCombinedNotesPdf(videos: videos, assets: assets, format: format);

  if (print) {
    await Printing.layoutPdf(onLayout: build, name: filename);
  } else {
    await Printing.sharePdf(
      bytes: await build(PdfPageFormat.a4),
      filename: filename,
    );
  }
}
