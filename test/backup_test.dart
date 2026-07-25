import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waypoint/data/backup.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/data/enums.dart';

void main() {
  test('export/import round-trips the whole workspace', () async {
    final source = AppDatabase(NativeDatabase.memory());
    addTearDown(source.close);

    final project = await source.createProject(
      name: 'Launch',
      description: 'Ship v1',
      color: 0xFF2196F3,
    );
    final task = await source.createTask(
      projectId: project.id,
      title: 'Write docs',
      notes: 'README + screenshots',
      priority: TaskPriority.high,
      dueDate: DateTime(2026, 8, 1),
    );
    await source.addSubtask(task.id, 'outline');
    final label = await source.createLabel('docs', 0xFF4CAF50);
    await source.setTaskLabels(task.id, {label.id});

    final json = await BackupCodec(source).export();

    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    // Pre-existing data must be replaced by the import.
    await target.createProject(name: 'Stale', color: 1);

    await BackupCodec(target).import(json);

    final projects = await target.watchProjects().first;
    expect(projects.single.name, 'Launch');
    expect(projects.single.description, 'Ship v1');

    final tasks = await target.watchTasksForProject(project.id).first;
    expect(tasks.single.title, 'Write docs');
    expect(tasks.single.priority, TaskPriority.high);
    expect(tasks.single.dueDate, DateTime(2026, 8, 1));

    final subtasks = await target.watchSubtasks(task.id).first;
    expect(subtasks.single.title, 'outline');

    final labels = await target.watchLabelsForTask(task.id).first;
    expect(labels.single.name, 'docs');
  });

  test('rejects non-backup JSON and leaves existing data intact', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.createProject(name: 'Keep me', color: 1);

    final codec = BackupCodec(db);
    await expectLater(
        codec.import('{"hello": "world"}'), throwsFormatException);
    await expectLater(codec.import('not json at all'),
        throwsA(isA<FormatException>()));

    final projects = await db.watchProjects().first;
    expect(projects.single.name, 'Keep me');
  });

  test('rejects backups from a newer format version', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final codec = BackupCodec(db);
    await expectLater(
      codec.import('{"format": "waypoint-backup", "version": 999}'),
      throwsFormatException,
    );
  });
}
