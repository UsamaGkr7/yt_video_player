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
  final sorted = List.of(clips)..sort((a, b) => a.start.compareTo(b.start));
  final date = exportedAt ?? DateTime.now();
  final videoUrl = 'https://www.youtube.com/watch?v=$videoId';

  final doc = pw.Document(
    title: title == null ? 'Video notes' : 'Notes: $title',
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
                title ?? 'Video notes',
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
      build: (context) => [
        _header(
          logo: assets.logo,
          title: title,
          channelName: channelName,
          videoUrl: videoUrl,
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
    ),
  );

  return doc.save();
}

pw.Widget _header({
  required Uint8List? logo,
  required String? title,
  required String? channelName,
  required String videoUrl,
  required int clipCount,
  required DateTime date,
}) {
  final dateText =
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
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
