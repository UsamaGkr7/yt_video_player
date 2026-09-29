import 'package:flutter/material.dart';

import 'video_store.dart';

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
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<WatchHistoryEntry>? _entries;
  Map<String, int> _clipCounts = {};

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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Watch history',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        actions: [
          if (entries != null && entries.isNotEmpty)
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
                        clipCount: _clipCounts[entry.videoId] ?? 0,
                        onTap: () => Navigator.of(context).pop(entry.videoId),
                        onRemove: () => _remove(entry),
                      ),
                    );
                  },
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
    this.onRemove,
  });

  final WatchHistoryEntry entry;
  final int clipCount;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final progress = entry.progress;
    final details = [
      if (entry.channelName != null) entry.channelName!,
      _relativeTime(entry.lastWatched),
      if (clipCount > 0) '$clipCount bookmark${clipCount == 1 ? '' : 's'}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E5E5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
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
  }
}
