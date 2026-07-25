import 'package:drift/drift.dart' hide Column;
import 'package:uuid/uuid.dart';

import '../data/backup.dart';
import '../data/database.dart';
import '../data/enums.dart';
import '../sync/protocol.dart';

const _uuid = Uuid();

/// The single mutation path for the whole app.
///
/// Every change is expressed as row-level [SyncOp]s, applied to the local
/// database and handed to [onOps] (the active team session, if any) for
/// relay to other devices. Solo use is the degenerate case: [onOps] is null
/// and ops simply apply locally.
class Workspace {
  Workspace(this.db, {this.onOps});

  final AppDatabase db;
  final void Function(List<SyncOp> ops)? onOps;

  Future<void> _commit(List<SyncOp> ops) async {
    await db.applyOps(ops);
    onOps?.call(ops);
  }

  Map<String, Object?> _row(Insertable<dynamic> row) =>
      switch (row) {
        Project p => p.toJson(serializer: waypointRowSerializer),
        Task t => t.toJson(serializer: waypointRowSerializer),
        Subtask s => s.toJson(serializer: waypointRowSerializer),
        Label l => l.toJson(serializer: waypointRowSerializer),
        TaskLabel tl => tl.toJson(serializer: waypointRowSerializer),
        _ => throw ArgumentError('Unsupported row type: $row'),
      };

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Future<Project> createProject({
    required String name,
    String description = '',
    required int color,
  }) async {
    final project = Project(
      id: _uuid.v4(),
      name: name,
      description: description,
      color: color,
      archived: false,
      sortOrder: DateTime.now().millisecondsSinceEpoch,
      createdAt: DateTime.now(),
    );
    await _commit([UpsertOp('projects', _row(project))]);
    return project;
  }

  Future<void> updateProject(Project project) =>
      _commit([UpsertOp('projects', _row(project))]);

  Future<void> setProjectArchived(String id, bool archived) async {
    final project =
        await (db.select(db.projects)..where((p) => p.id.equals(id)))
            .getSingleOrNull();
    if (project == null) return;
    await _commit([
      UpsertOp('projects', _row(project.copyWith(archived: archived))),
    ]);
  }

  Future<void> deleteProject(String id) => _commit([DeleteOp('projects', id)]);

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  Future<Task> createTask({
    required String projectId,
    required String title,
    String notes = '',
    TaskStatus status = TaskStatus.todo,
    TaskPriority priority = TaskPriority.none,
    DateTime? dueDate,
  }) async {
    final task = Task(
      id: _uuid.v4(),
      projectId: projectId,
      title: title,
      notes: notes,
      status: status,
      priority: priority,
      dueDate: dueDate,
      createdAt: DateTime.now(),
      completedAt: status == TaskStatus.done ? DateTime.now() : null,
      sortOrder: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    await _commit([UpsertOp('tasks', _row(task))]);
    return task;
  }

  Future<void> updateTask(Task task) =>
      _commit([UpsertOp('tasks', _row(task))]);

  /// Moves a task to a new column/position; stamps or clears completedAt when
  /// crossing the done boundary.
  Future<void> moveTask(String id, TaskStatus status, double sortOrder) async {
    final task = await (db.select(db.tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (task == null) return;
    DateTime? completedAt = task.completedAt;
    if (status == TaskStatus.done && task.status != TaskStatus.done) {
      completedAt = DateTime.now();
    } else if (status != TaskStatus.done) {
      completedAt = null;
    }
    await _commit([
      UpsertOp(
        'tasks',
        _row(task.copyWith(
          status: status,
          sortOrder: sortOrder,
          completedAt: Value(completedAt),
        )),
      ),
    ]);
  }

  Future<void> deleteTask(String id) => _commit([DeleteOp('tasks', id)]);

  // ---------------------------------------------------------------------------
  // Subtasks
  // ---------------------------------------------------------------------------

  Future<void> addSubtask(String taskId, String title) {
    final subtask = Subtask(
      id: _uuid.v4(),
      taskId: taskId,
      title: title,
      done: false,
      sortOrder: DateTime.now().millisecondsSinceEpoch,
    );
    return _commit([UpsertOp('subtasks', _row(subtask))]);
  }

  Future<void> setSubtaskDone(String id, bool done) async {
    final subtask =
        await (db.select(db.subtasks)..where((s) => s.id.equals(id)))
            .getSingleOrNull();
    if (subtask == null) return;
    await _commit([UpsertOp('subtasks', _row(subtask.copyWith(done: done)))]);
  }

  Future<void> deleteSubtask(String id) => _commit([DeleteOp('subtasks', id)]);

  // ---------------------------------------------------------------------------
  // Labels
  // ---------------------------------------------------------------------------

  Future<Label> createLabel(String name, int color) async {
    final label = Label(id: _uuid.v4(), name: name, color: color);
    await _commit([UpsertOp('labels', _row(label))]);
    return label;
  }

  Future<void> deleteLabel(String id) => _commit([DeleteOp('labels', id)]);

  Future<void> setTaskLabels(String taskId, Set<String> labelIds) {
    return _commit([
      ClearTaskLabelsOp(taskId),
      for (final labelId in labelIds)
        UpsertOp('task_labels', _row(TaskLabel(taskId: taskId, labelId: labelId))),
    ]);
  }
}
