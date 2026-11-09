import '../models/library_backup.dart';
import 'shelf_store.dart';

/// Last-write-wins merge for LAN sync (`docs/lan-sync-design.md` §6).
///
/// Kept apart from `LibraryStore.mergeBackup()` on purpose: restoring a backup
/// means "fill the gaps, never overwrite what I have", while syncing means
/// "the newer reading position wins". Changing the restore path to these rules
/// would make importing an old backup roll the user's progress backwards.
///
/// This is a pure function: no Hive, no I/O. `SyncAgent` applies the result
/// through the stores, and tests drive it with plain backups.
class SyncMerger {
  const SyncMerger._();

  static LibraryBackup merge(LibraryBackup local, LibraryBackup remote) {
    return LibraryBackup.capture(
      shelf: _mergeShelf(local.shelf, remote.shelf),
      history: _mergeHistory(local.history, remote.history),
      watched: _mergeWatched(local.watched, remote.watched),
      groups: _mergeGroups(local.groups, remote.groups),
      aiData: local.aiData ?? remote.aiData,
    );
  }

  /// Reading progress: `(kind, id)` is the key; a newer `time` wins, and a
  /// tie is broken by the larger `progress`.
  static List<Map<String, dynamic>> _mergeHistory(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
  ) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final record in [...local, ...remote]) {
      final key = _historyKey(record);
      final current = byKey[key];
      if (current == null) {
        byKey[key] = Map<String, dynamic>.from(record);
        continue;
      }
      final time = _int(record['time']);
      final currentTime = _int(current['time']);
      if (time > currentTime ||
          (time == currentTime &&
              _double(record['progress']) > _double(current['progress']))) {
        byKey[key] = Map<String, dynamic>.from(record);
      }
    }
    return byKey.values.toList();
  }

  static String _historyKey(Map<String, dynamic> record) =>
      '${record['kind'] ?? 'book'}:${record['contentId'] ?? record['id']}';

  /// Watched episodes are a union; the later timestamp wins for one episode.
  static Map<String, Map<String, int>> _mergeWatched(
    Map<String, Map<String, int>> local,
    Map<String, Map<String, int>> remote,
  ) {
    final merged = <String, Map<String, int>>{};
    for (final source in [local, remote]) {
      for (final entry in source.entries) {
        final episodes = Map<String, int>.from(merged[entry.key] ?? const {});
        for (final episode in entry.value.entries) {
          final current = episodes[episode.key];
          if (current == null || episode.value > current) {
            episodes[episode.key] = episode.value;
          }
        }
        merged[entry.key] = episodes;
      }
    }
    return merged;
  }

  /// Shelf membership is a union; the earlier `addedAt` is the truth about
  /// when the book was first collected.
  static List<ShelfRecord> _mergeShelf(
    List<ShelfRecord> local,
    List<ShelfRecord> remote,
  ) {
    final byKey = <String, ShelfRecord>{};
    for (final record in [...local, ...remote]) {
      final key = ShelfStore.keyOf(record.item);
      final current = byKey[key];
      if (current == null || record.addedAt.isBefore(current.addedAt)) {
        byKey[key] = record;
      }
    }
    return byKey.values.toList();
  }

  /// Groups and assignments are unions; the larger `at` wins for one key.
  /// The result is still a portable organization document, so the existing
  /// `ShelfGroupStore` validator stays the single gate for that shape.
  static Map<String, dynamic> _mergeGroups(
    Map<String, dynamic> local,
    Map<String, dynamic> remote,
  ) {
    if (local.isEmpty && remote.isEmpty) return const <String, dynamic>{};
    final groups = <String, dynamic>{};
    final assignments = <String, dynamic>{};
    for (final source in [local, remote]) {
      final sourceGroups = source['groups'];
      if (sourceGroups is Map) {
        for (final entry in sourceGroups.entries) {
          final key = entry.key.toString();
          final value = _map(entry.value);
          final current = groups[key];
          if (current == null || _at(value) >= _at(_map(current))) {
            groups[key] = value;
          }
        }
      }
      final sourceAssignments = source['assignments'];
      if (sourceAssignments is Map) {
        for (final entry in sourceAssignments.entries) {
          final key = entry.key.toString();
          final value = _map(entry.value);
          final current = assignments[key];
          if (current == null || _at(value) >= _at(_map(current))) {
            assignments[key] = value;
          }
        }
      }
    }
    return {
      'version': 1,
      'groups': groups,
      'assignments': assignments,
    };
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static int _at(Map<String, dynamic> value) => _int(value['at']);

  static int _int(Object? value) =>
      value is num && value.isFinite ? value.toInt() : 0;

  static double _double(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : 0;
}
