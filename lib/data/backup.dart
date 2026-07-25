import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';

/// Plain-JSON backup of the entire workspace.
///
/// Export/import is free and always will be: your data is never held hostage.
/// The same snapshot format is what the (optional, paid) cloud sync service
/// transports — see `lib/sync/sync_service.dart`.
class BackupCodec {
  BackupCodec(this.db);

  final AppDatabase db;

  static const format = 'waypoint-backup';
  static const version = 1;

  static const _serializer =
      ValueSerializer.defaults(serializeDateTimeValuesAsString: true);

  Future<String> export() async {
    final snapshot = await db.transaction(() async {
      return {
        'format': format,
        'version': version,
        'exportedAt': DateTime.now().toIso8601String(),
        'projects': [
          for (final row in await db.select(db.projects).get())
            row.toJson(serializer: _serializer),
        ],
        'labels': [
          for (final row in await db.select(db.labels).get())
            row.toJson(serializer: _serializer),
        ],
        'tasks': [
          for (final row in await db.select(db.tasks).get())
            row.toJson(serializer: _serializer),
        ],
        'subtasks': [
          for (final row in await db.select(db.subtasks).get())
            row.toJson(serializer: _serializer),
        ],
        'taskLabels': [
          for (final row in await db.select(db.taskLabels).get())
            row.toJson(serializer: _serializer),
        ],
      };
    });
    return const JsonEncoder.withIndent('  ').convert(snapshot);
  }

  /// Replaces the current workspace with the backup's contents.
  ///
  /// Throws [FormatException] if [source] is not a Waypoint backup; the
  /// existing data is left untouched in that case (single transaction).
  Future<void> import(String source) async {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?> ||
        decoded['format'] != format ||
        decoded['version'] is! int) {
      throw const FormatException('Not a Waypoint backup file.');
    }
    if ((decoded['version'] as int) > version) {
      throw const FormatException(
          'Backup was created by a newer version of Waypoint.');
    }

    List<Map<String, Object?>> rows(String key) => [
          for (final row in (decoded[key] as List? ?? const []))
            (row as Map).cast<String, Object?>(),
        ];

    // Parse everything before touching the database.
    final projects = [
      for (final r in rows('projects')) Project.fromJson(r, serializer: _serializer),
    ];
    final labels = [
      for (final r in rows('labels')) Label.fromJson(r, serializer: _serializer),
    ];
    final tasks = [
      for (final r in rows('tasks')) Task.fromJson(r, serializer: _serializer),
    ];
    final subtasks = [
      for (final r in rows('subtasks')) Subtask.fromJson(r, serializer: _serializer),
    ];
    final taskLabels = [
      for (final r in rows('taskLabels'))
        TaskLabel.fromJson(r, serializer: _serializer),
    ];

    await db.transaction(() async {
      await db.delete(db.taskLabels).go();
      await db.delete(db.subtasks).go();
      await db.delete(db.tasks).go();
      await db.delete(db.labels).go();
      await db.delete(db.projects).go();
      for (final row in projects) {
        await db.into(db.projects).insert(row);
      }
      for (final row in labels) {
        await db.into(db.labels).insert(row);
      }
      for (final row in tasks) {
        await db.into(db.tasks).insert(row);
      }
      for (final row in subtasks) {
        await db.into(db.subtasks).insert(row);
      }
      for (final row in taskLabels) {
        await db.into(db.taskLabels).insert(row);
      }
    });
  }
}
