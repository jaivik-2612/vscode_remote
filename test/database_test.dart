import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/data/enums.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('projects', () {
    test('create and watch', () async {
      final project = await db.createProject(name: 'Website', color: 0xFF000000);
      final projects = await db.watchProjects().first;
      expect(projects, hasLength(1));
      expect(projects.single.id, project.id);
      expect(projects.single.name, 'Website');
    });

    test('archived projects are separated from active ones', () async {
      final project = await db.createProject(name: 'Old', color: 1);
      await db.setProjectArchived(project.id, true);
      expect(await db.watchProjects().first, isEmpty);
      final archived = await db.watchProjects(archived: true).first;
      expect(archived.single.id, project.id);
    });

    test('deleting a project cascades to its tasks and subtasks', () async {
      final project = await db.createProject(name: 'Temp', color: 1);
      final task = await db.createTask(projectId: project.id, title: 'A');
      await db.addSubtask(task.id, 'A.1');
      await db.deleteProject(project.id);
      expect(await db.watchTasksForProject(project.id).first, isEmpty);
      expect(await db.watchSubtasks(task.id).first, isEmpty);
    });

    test('progress counts open and done tasks per project', () async {
      final project = await db.createProject(name: 'P', color: 1);
      await db.createTask(projectId: project.id, title: 'open');
      final done = await db.createTask(projectId: project.id, title: 'done');
      await db.moveTask(done.id, TaskStatus.done, 0);
      final progress = await db.watchProjectProgress().first;
      expect(progress[project.id]!.open, 1);
      expect(progress[project.id]!.done, 1);
      expect(progress[project.id]!.fraction, 0.5);
    });
  });

  group('tasks', () {
    late Project project;

    setUp(() async {
      project = await db.createProject(name: 'P', color: 1);
    });

    test('moving to done stamps completedAt; moving back clears it', () async {
      final task = await db.createTask(projectId: project.id, title: 'T');
      expect(task.completedAt, isNull);

      await db.moveTask(task.id, TaskStatus.done, 10);
      var updated = await db.watchTask(task.id).first;
      expect(updated!.completedAt, isNotNull);
      expect(updated.status, TaskStatus.done);
      expect(updated.sortOrder, 10);

      await db.moveTask(task.id, TaskStatus.inProgress, 20);
      updated = await db.watchTask(task.id).first;
      expect(updated!.completedAt, isNull);
      expect(updated.status, TaskStatus.inProgress);
    });

    test('tasks are ordered by sortOrder within a project', () async {
      final b = await db.createTask(projectId: project.id, title: 'B');
      final a = await db.createTask(projectId: project.id, title: 'A');
      await db.moveTask(a.id, TaskStatus.todo, 1);
      await db.moveTask(b.id, TaskStatus.todo, 2);
      final tasks = await db.watchTasksForProject(project.id).first;
      expect(tasks.map((t) => t.title).toList(), ['A', 'B']);
    });

    test('open tasks exclude done tasks and archived projects', () async {
      final other = await db.createProject(name: 'Archived', color: 1);
      await db.createTask(projectId: project.id, title: 'visible');
      final done = await db.createTask(projectId: project.id, title: 'done');
      await db.moveTask(done.id, TaskStatus.done, 0);
      await db.createTask(projectId: other.id, title: 'hidden');
      await db.setProjectArchived(other.id, true);

      final open = await db.watchOpenTasks().first;
      expect(open.map((e) => e.task.title).toList(), ['visible']);
      expect(open.single.project.id, project.id);
    });

    test('search matches title and notes, escapes wildcards', () async {
      await db.createTask(projectId: project.id, title: 'Fix login bug');
      await db.createTask(
          projectId: project.id, title: 'Other', notes: 'about login flow');
      await db.createTask(projectId: project.id, title: '100% done');

      expect(await db.searchTasks('login').first, hasLength(2));
      expect(await db.searchTasks('100%').first, hasLength(1));
      expect(await db.searchTasks('%').first, hasLength(1));
    });
  });

  group('subtasks and labels', () {
    test('subtask lifecycle', () async {
      final project = await db.createProject(name: 'P', color: 1);
      final task = await db.createTask(projectId: project.id, title: 'T');
      await db.addSubtask(task.id, 'step 1');
      var subtasks = await db.watchSubtasks(task.id).first;
      expect(subtasks.single.done, isFalse);

      await db.setSubtaskDone(subtasks.single.id, true);
      subtasks = await db.watchSubtasks(task.id).first;
      expect(subtasks.single.done, isTrue);

      await db.deleteSubtask(subtasks.single.id);
      expect(await db.watchSubtasks(task.id).first, isEmpty);
    });

    test('labels attach to and detach from tasks', () async {
      final project = await db.createProject(name: 'P', color: 1);
      final task = await db.createTask(projectId: project.id, title: 'T');
      final bug = await db.createLabel('bug', 1);
      final ui = await db.createLabel('ui', 2);

      await db.setTaskLabels(task.id, {bug.id, ui.id});
      expect(await db.watchLabelsForTask(task.id).first, hasLength(2));

      await db.setTaskLabels(task.id, {ui.id});
      final remaining = await db.watchLabelsForTask(task.id).first;
      expect(remaining.single.name, 'ui');

      // Deleting a label cascades to task links.
      await db.deleteLabel(ui.id);
      expect(await db.watchLabelsForTask(task.id).first, isEmpty);
    });
  });
}
