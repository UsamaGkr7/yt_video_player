import 'package:flutter/material.dart';

import 'bookmark_playlist_screen.dart';
import 'notes_pdf.dart';
import 'video_store.dart';

const _brandGreen = Color(0xFF33A052);

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return '${time.day}/${time.month}/${time.year}';
}

/// Lists previously watched videos. Tapping one pops the route with that
/// video's id so the player screen can open it.
///
/// In select mode (the "Select" button or a long press) the user picks
/// videos that have bookmarks, in any order, and then prints/saves one
/// combined PDF or plays all their bookmarks back to back in that order.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<WatchHistoryEntry>? _entries;
  Map<String, int> _clipCounts = {};
  bool _selecting = false;
  // Selected video ids, in the order they were picked.
  final List<String> _selected = [];
  bool _isWorking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await VideoStore.loadHistory();
    final counts = <String, int>{
      for (final entry in entries)
        entry.videoId: await VideoStore.clipCount(entry.videoId),
    };
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _clipCounts = counts;
    });
  }

  bool _hasBookmarks(String videoId) => (_clipCounts[videoId] ?? 0) > 0;

  int get _selectedClipCount =>
      _selected.fold(0, (sum, id) => sum + (_clipCounts[id] ?? 0));

  void _startSelecting([WatchHistoryEntry? first]) {
    setState(() {
      _selecting = true;
      _selected.clear();
    });
    if (first != null) _toggleSelected(first);
  }

  void _stopSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(WatchHistoryEntry entry) {
    if (!_hasBookmarks(entry.videoId)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('This video has no bookmarks to combine yet.'),
          ),
        );
      return;
    }
    setState(() {
      if (!_selected.remove(entry.videoId)) _selected.add(entry.videoId);
    });
  }

  Future<List<VideoNotes>> _selectedNotes() async {
    final byId = {for (final entry in _entries!) entry.videoId: entry};
    return [
      for (final videoId in _selected)
        VideoNotes(
          videoId: videoId,
          title: byId[videoId]?.title,
          channelName: byId[videoId]?.channelName,
          clips: await VideoStore.loadClips(videoId),
        ),
    ];
  }

  Future<void> _exportSelected({required bool print}) async {
    if (_isWorking || _selected.isEmpty) return;
    setState(() => _isWorking = true);
    try {
      await printOrShareNotes(await _selectedNotes(), print: print);
    } catch (error, stackTrace) {
      debugPrint('Combined PDF export failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the PDF: $error')),
      );
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _playSelected() async {
    if (_isWorking || _selected.isEmpty) return;
    setState(() => _isWorking = true);
    final videos = await _selectedNotes();
    if (!mounted) return;
    setState(() => _isWorking = false);
    // Bookmarks may have been deleted since the counts were loaded.
    final playable = videos.where((v) => v.clips.isNotEmpty).toList();
    if (playable.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookmarkPlaylistScreen(videos: playable),
      ),
    );
  }

  Future<void> _remove(WatchHistoryEntry entry) async {
    setState(() => _entries!.remove(entry));
    await VideoStore.removeHistory(entry.videoId);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'Your bookmarks are kept. Only the history list and resume '
          'positions are removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await VideoStore.clearHistory();
    if (!mounted) return;
    setState(() => _entries = []);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final canSelect =
        entries != null && entries.any((e) => _hasBookmarks(e.videoId));
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stopSelecting();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  onPressed: _stopSelecting,
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel selection',
                )
              : null,
          title: Text(
            _selecting
                ? (_selected.isEmpty
                      ? 'Select videos'
                      : '${_selected.length} selected')
                : 'Watch history',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
          actions: [
            if (!_selecting && canSelect)
              TextButton.icon(
                onPressed: () => _startSelecting(),
                icon: const Icon(Icons.checklist),
                label: const Text('Select'),
              ),
            if (!_selecting && entries != null && entries.isNotEmpty)
              TextButton(onPressed: _clearAll, child: const Text('Clear all')),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: const Color(0xFFE5E5E5)),
          ),
        ),
        body: entries == null
            ? const Center(child: CircularProgressIndicator())
            : entries.isEmpty
            ? const Center(
                child: Text(
                  'Videos you watch will show up here.',
                  style: TextStyle(color: Color(0xFF606060)),
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final clipCount = _clipCounts[entry.videoId] ?? 0;
                      if (_selecting) {
                        final order = _selected.indexOf(entry.videoId);
                        return HistoryTile(
                          entry: entry,
                          clipCount: clipCount,
                          selectionOrder: order == -1 ? null : order + 1,
                          dimmed: clipCount == 0,
                          onTap: () => _toggleSelected(entry),
                        );
                      }
                      return Dismissible(
                        key: ValueKey(entry.videoId),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.red.shade400,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.delete_outline,
                            color: Colors.white,
                          ),
                        ),
                        onDismissed: (_) => _remove(entry),
                        child: HistoryTile(
                          entry: entry,
                          clipCount: clipCount,
                          onTap: () => Navigator.of(context).pop(entry.videoId),
                          onLongPress: clipCount > 0
                              ? () => _startSelecting(entry)
                              : null,
                          onRemove: () => _remove(entry),
                        ),
                      );
                    },
                  ),
                ),
              ),
        bottomNavigationBar: _selecting ? _selectionBar() : null,
      ),
    );
  }

  Widget _selectionBar() {
    final hasSelection = _selected.isNotEmpty;
    final clipCount = _selectedClipCount;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E5E5))),
        ),
        // heightFactor keeps the bar as tall as its content; a plain Center
        // would expand to fill the whole screen.
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    hasSelection
                        ? '${_selected.length} video'
                              '${_selected.length == 1 ? '' : 's'} · '
                              '$clipCount bookmark${clipCount == 1 ? '' : 's'}'
                        : 'Tap videos in the order you want them',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF606060)),
                  ),
                ),
                if (_isWorking)
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
                  //   onPressed: hasSelection
                  //       ? () => _exportSelected(print: true)
                  //       : null,
                  //   icon: const Icon(Icons.print_outlined),
                  //   color: _brandGreen,
                  //   tooltip: 'Print combined notes',
                  // ),
                  IconButton(
                    onPressed: hasSelection
                        ? () => _exportSelected(print: false)
                        : null,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    color: _brandGreen,
                    tooltip: 'Save combined notes as PDF',
                  ),
                ],
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: hasSelection && !_isWorking ? _playSelected : null,
                  icon: const Icon(Icons.playlist_play),
                  label: const Text('Play bookmarks'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HistoryTile extends StatelessWidget {
  const HistoryTile({
    super.key,
    required this.entry,
    required this.clipCount,
    required this.onTap,
    this.onLongPress,
    this.onRemove,
    this.selectionOrder,
    this.dimmed = false,
  });

  final WatchHistoryEntry entry;
  final int clipCount;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onRemove;

  /// Position of this video in the current selection (1-based), or null
  /// when it is not selected.
  final int? selectionOrder;

  /// Greys the tile out, e.g. when it cannot be selected.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final progress = entry.progress;
    final details = [
      if (entry.channelName != null) entry.channelName!,
      _relativeTime(entry.lastWatched),
      if (clipCount > 0) '$clipCount bookmark${clipCount == 1 ? '' : 's'}',
    ].join(' · ');

    final isSelected = selectionOrder != null;
    final tile = Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFF1F8F3) : const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? primary : const Color(0xFFE5E5E5),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 128,
                  height: 72,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        entry.thumbnailUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          color: const Color(0xFFE5E5E5),
                          child: const Icon(
                            Icons.ondemand_video,
                            color: Color(0xFF606060),
                          ),
                        ),
                      ),
                      if (isSelected)
                        Container(
                          color: const Color(0x66000000),
                          alignment: Alignment.center,
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: primary,
                            foregroundColor: Colors.white,
                            child: Text(
                              '$selectionOrder',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (progress != null)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: const Color(0x66000000),
                            valueColor: AlwaysStoppedAnimation<Color>(primary),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title ?? 'Untitled video',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F0F0F),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF606060),
                        fontSize: 12,
                      ),
                    ),
                    if (entry.position > Duration.zero) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.duration > Duration.zero
                            ? '${formatDuration(entry.position)} / ${formatDuration(entry.duration)}'
                            : 'Stopped at ${formatDuration(entry.position)}',
                        style: const TextStyle(
                          color: Color(0xFF606060),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.close, color: Color(0xFF606060)),
                  tooltip: 'Remove from history',
                ),
            ],
          ),
        ),
      ),
    );
    return dimmed ? Opacity(opacity: 0.45, child: tile) : tile;
  }
}
