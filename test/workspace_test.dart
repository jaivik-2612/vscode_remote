import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/data/enums.dart';
import 'package:waypoint/data/workspace.dart';
import 'package:waypoint/sync/protocol.dart';

void main() {
  late AppDatabase db;
  late List<SyncOp> sent;
  late Workspace workspace;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sent = [];
    workspace = Workspace(db, onOps: sent.addAll);
  });

  tearDown(() => db.close());

  test('mutations write locally and emit relayable ops', () async {
    final project =
        await workspace.createProject(name: 'Shared', color: 0xFF000000);
    final task =
        await workspace.createTask(projectId: project.id, title: 'Together');

    expect((await db.watchProjects().first).single.name, 'Shared');
    expect((await db.watchTasksForProject(project.id).first).single.id, task.id);

    // Ops round-trip through JSON into a second replica.
    final replica = AppDatabase(NativeDatabase.memory());
    addTearDown(replica.close);
    final decoded = [
      for (final op in sent) SyncOp.fromJson(op.toJson()),
    ];
    await replica.applyOps(decoded);
    expect((await replica.watchProjects().first).single.name, 'Shared');
    expect((await replica.watchTasksForProject(project.id).first).single.title,
        'Together');
  });

  test('moveTask stamps and clears completedAt through the op path', () async {
    final project = await workspace.createProject(name: 'P', color: 1);
    final task = await workspace.createTask(projectId: project.id, title: 'T');

    await workspace.moveTask(task.id, TaskStatus.done, 5);
    var current = await db.watchTask(task.id).first;
    expect(current!.completedAt, isNotNull);

    await workspace.moveTask(task.id, TaskStatus.todo, 6);
    current = await db.watchTask(task.id).first;
    expect(current!.completedAt, isNull);
    expect(current.sortOrder, 6);
  });

  test('setTaskLabels emits clear + upserts and applies idempotently',
      () async {
    final project = await workspace.createProject(name: 'P', color: 1);
    final task = await workspace.createTask(projectId: project.id, title: 'T');
    final label = await workspace.createLabel('bug', 2);

    sent.clear();
    await workspace.setTaskLabels(task.id, {label.id});
    expect(sent.first, isA<ClearTaskLabelsOp>());
    expect((await db.watchLabelsForTask(task.id).first).single.name, 'bug');

    // Replaying the same ops (echo from the host) changes nothing.
    await db.applyOps(sent);
    expect((await db.watchLabelsForTask(task.id).first), hasLength(1));
  });

  test('deleting a project via ops cascades on every replica', () async {
    final project = await workspace.createProject(name: 'P', color: 1);
    final task = await workspace.createTask(projectId: project.id, title: 'T');
    await workspace.addSubtask(task.id, 'child');

    final replica = AppDatabase(NativeDatabase.memory());
    addTearDown(replica.close);
    await replica.applyOps(sent);

    await workspace.deleteProject(project.id);
    await replica.applyOps([sent.last]);

    for (final target in [db, replica]) {
      expect(await target.watchTasksForProject(project.id).first, isEmpty);
      expect(await target.watchSubtasks(task.id).first, isEmpty);
    }
  });
}
