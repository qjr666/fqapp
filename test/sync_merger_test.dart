import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/services/sync_merger.dart';

LibraryBackup backup({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> shelf = const [],
  List<Map<String, dynamic>> watched = const [],
  Map<String, dynamic>? groups,
}) {
  final payload = <String, dynamic>{
    'format': 'fqapp.library-backup',
    'version': 1,
    'createdAt': 1000,
    'shelf': shelf,
    'history': history,
    'watched': watched,
    'excludedLocalRecords': 0,
    if (groups != null) 'groups': groups,
  };
  return LibraryBackup.decode(
    Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  );
}

Map<String, dynamic> progress(int time, double value) => {
  'id': 'b1',
  'kind': 'book',
  'time': time,
  'progress': value,
};

void main() {
  test('a newer peer progress wins', () {
    final merged = SyncMerger.merge(
      backup(history: [progress(100, 0.2)]),
      backup(history: [progress(200, 0.8)]),
    );
    expect(merged.history, hasLength(1));
    expect(merged.history.single['time'], 200);
    expect(merged.history.single['progress'], 0.8);
  });

  test('an older peer never rolls the local position back', () {
    final merged = SyncMerger.merge(
      backup(history: [progress(300, 0.9)]),
      backup(history: [progress(100, 0.1)]),
    );
    expect(merged.history.single['time'], 300);
    expect(merged.history.single['progress'], 0.9);
  });

  test('equal timestamps break the tie by the larger progress', () {
    final merged = SyncMerger.merge(
      backup(history: [progress(200, 0.3)]),
      backup(history: [progress(200, 0.7)]),
    );
    expect(merged.history.single['progress'], 0.7);
  });

  test('watched episodes are a union and keep the later timestamp', () {
    final merged = SyncMerger.merge(
      backup(
        watched: [
          {
            'id': 'v1',
            'episodes': {'e1': 100, 'e2': 200},
          },
        ],
      ),
      backup(
        watched: [
          {
            'id': 'v1',
            'episodes': {'e1': 300, 'e3': 50},
          },
        ],
      ),
    );
    expect(merged.watched['v1'], {
      'e1': 300,
      'e2': 200,
      'e3': 50,
    });
  });

  test('shelf membership is a union with the earlier addedAt', () {
    Map<String, dynamic> record(int addedAt) => {
      'id': 'b1',
      'kind': 'book',
      'title': '书',
      'addedAt': addedAt,
    };
    final merged = SyncMerger.merge(
      backup(shelf: [record(500)]),
      backup(shelf: [record(100)]),
    );
    expect(merged.shelf, hasLength(1));
    expect(merged.shelf.single.addedAt.millisecondsSinceEpoch, 100);
  });

  test('groups and assignments keep the larger at', () {
    Map<String, dynamic> organization(int at) => {
      'version': 1,
      'groups': {
        'g1-abc': {'name': 'A', 'at': at, 'deleted': false},
      },
      'assignments': {
        'book:123': {'group': 'g1-abc', 'at': at},
      },
    };
    final merged = SyncMerger.merge(
      backup(groups: organization(10)),
      backup(groups: organization(20)),
    );
    final groups = merged.groups['groups'] as Map;
    final assignments = merged.groups['assignments'] as Map;
    expect(groups['g1-abc']['at'], 20);
    expect(assignments['book:123']['at'], 20);
  });

  test('merging a snapshot with itself does not duplicate anything', () {
    final original = backup(
      history: [progress(100, 0.5)],
      shelf: [
        {'id': 'b1', 'kind': 'book', 'addedAt': 10},
      ],
      watched: [
        {
          'id': 'v1',
          'episodes': {'e1': 1},
        },
      ],
    );
    final merged = SyncMerger.merge(original, original);
    expect(merged.history, hasLength(1));
    expect(merged.shelf, hasLength(1));
    expect(merged.watched['v1'], hasLength(1));
    expect(merged.history.single['time'], 100);
  });
}
