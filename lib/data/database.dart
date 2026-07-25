import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:uuid/uuid.dart';

import 'enums.dart';

part 'database.g.dart';

const _uuid = Uuid();

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  IntColumn get color => integer()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()();
  // Foreign keys are written out by hand: drift_dev doesn't reliably pick up
  // `references()` with current analyzer versions, and a silently missing
  // ON DELETE CASCADE corrupts the workspace on project deletion.
  TextColumn get projectId => text().customConstraint(
      'NOT NULL REFERENCES projects (id) ON DELETE CASCADE')();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get status => intEnum<TaskStatus>()();
  IntColumn get priority => intEnum<TaskPriority>()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();
  RealColumn get sortOrder => real().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Subtasks extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text()
      .customConstraint('NOT NULL REFERENCES tasks (id) ON DELETE CASCADE')();
  TextColumn get title => text()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Labels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get color => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class TaskLabels extends Table {
  TextColumn get taskId => text()
      .customConstraint('NOT NULL REFERENCES tasks (id) ON DELETE CASCADE')();
  TextColumn get labelId => text()
      .customConstraint('NOT NULL REFERENCES labels (id) ON DELETE CASCADE')();

  @override
  Set<Column> get primaryKey => {taskId, labelId};
}

/// A task joined with the project it belongs to, for cross-project views.
class TaskWithProject {
  const TaskWithProject(this.task, this.project);

  final Task task;
  final Project project;
}

/// Progress summary of a project, computed in SQL.
class ProjectProgress {
  const ProjectProgress({required this.open, required this.done});

  final int open;
  final int done;

  int get total => open + done;
  double get fraction => total == 0 ? 0 : done / total;
}

@DriftDatabase(tables: [Projects, Tasks, Subtasks, Labels, TaskLabels])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  AppDatabase.open() : super(_openConnection());

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'waypoint',
      native: const DriftNativeOptions(shareAcrossIsolates: true),
    );
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // ---------------------------------------------------------------------------
  // Projects
  // ---------------------------------------------------------------------------

  Stream<List<Project>> watchProjects({bool archived = false}) {
    return (select(projects)
          ..where((p) => p.archived.equals(archived))
          ..orderBy([
            (p) => OrderingTerm.asc(p.sortOrder),
            (p) => OrderingTerm.asc(p.createdAt),
          ]))
        .watch();
  }

  Stream<Project?> watchProject(String id) {
    return (select(projects)..where((p) => p.id.equals(id))).watchSingleOrNull();
  }

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
    await into(projects).insert(project);
    return project;
  }

  Future<void> updateProject(Project project) =>
      update(projects).replace(project);

  Future<void> setProjectArchived(String id, bool archived) {
    return (update(projects)..where((p) => p.id.equals(id)))
        .write(ProjectsCompanion(archived: Value(archived)));
  }

  Future<void> deleteProject(String id) =>
      (delete(projects)..where((p) => p.id.equals(id))).go();

  /// Open/done task counts per project, kept live for the projects overview.
  Stream<Map<String, ProjectProgress>> watchProjectProgress() {
    final done = tasks.status.equalsValue(TaskStatus.done);
    final openCount = countAll(filter: done.not());
    final doneCount = countAll(filter: done);
    final query = selectOnly(tasks)
      ..addColumns([tasks.projectId, openCount, doneCount])
      ..groupBy([tasks.projectId]);
    return query.watch().map((rows) {
      return {
        for (final row in rows)
          row.read(tasks.projectId)!: ProjectProgress(
            open: row.read(openCount) ?? 0,
            done: row.read(doneCount) ?? 0,
          ),
      };
    });
  }

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  Stream<List<Task>> watchTasksForProject(String projectId) {
    return (select(tasks)
          ..where((t) => t.projectId.equals(projectId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .watch();
  }

  Stream<Task?> watchTask(String id) {
    return (select(tasks)..where((t) => t.id.equals(id))).watchSingleOrNull();
  }

  /// All tasks that are not done, joined with their (non-archived) project.
  Stream<List<TaskWithProject>> watchOpenTasks() {
    final query = select(tasks).join([
      innerJoin(projects, projects.id.equalsExp(tasks.projectId)),
    ])
      ..where(tasks.status.equalsValue(TaskStatus.done).not() &
          projects.archived.equals(false))
      ..orderBy([
        OrderingTerm(
          expression: tasks.dueDate.isNull(),
          mode: OrderingMode.asc,
        ),
        OrderingTerm.asc(tasks.dueDate),
        OrderingTerm.desc(tasks.priority),
      ]);
    return query.watch().map((rows) => [
          for (final row in rows)
            TaskWithProject(row.readTable(tasks), row.readTable(projects)),
        ]);
  }

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
      completedAt: null,
      sortOrder: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    await into(tasks).insert(task);
    return task;
  }

  Future<void> updateTask(Task task) => update(tasks).replace(task);

  /// Moves a task to a new column/position; stamps or clears completedAt when
  /// crossing the done boundary.
  Future<void> moveTask(String id, TaskStatus status, double sortOrder) async {
    final current = await (select(tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (current == null) return;
    DateTime? completedAt = current.completedAt;
    if (status == TaskStatus.done && current.status != TaskStatus.done) {
      completedAt = DateTime.now();
    } else if (status != TaskStatus.done) {
      completedAt = null;
    }
    await (update(tasks)..where((t) => t.id.equals(id))).write(TasksCompanion(
      status: Value(status),
      sortOrder: Value(sortOrder),
      completedAt: Value(completedAt),
    ));
  }

  Future<void> deleteTask(String id) =>
      (delete(tasks)..where((t) => t.id.equals(id))).go();

  /// Case-insensitive literal substring match. `instr` instead of `LIKE`
  /// because drift's `like()` has no ESCAPE clause, so user input containing
  /// `%`/`_` can't be escaped reliably.
  Expression<bool> _contains(GeneratedColumn<String> column, String needle) {
    return FunctionCallExpression<int>(
      'instr',
      [column.lower(), Variable<String>(needle.toLowerCase())],
    ).isBiggerThanValue(0);
  }

  Stream<List<TaskWithProject>> searchTasks(String query) {
    final search = select(tasks).join([
      innerJoin(projects, projects.id.equalsExp(tasks.projectId)),
    ])
      ..where(_contains(tasks.title, query) | _contains(tasks.notes, query))
      ..orderBy([OrderingTerm.desc(tasks.createdAt)])
      ..limit(50);
    return search.watch().map((rows) => [
          for (final row in rows)
            TaskWithProject(row.readTable(tasks), row.readTable(projects)),
        ]);
  }

  // ---------------------------------------------------------------------------
  // Subtasks
  // ---------------------------------------------------------------------------

  Stream<List<Subtask>> watchSubtasks(String taskId) {
    return (select(subtasks)
          ..where((s) => s.taskId.equals(taskId))
          ..orderBy([(s) => OrderingTerm.asc(s.sortOrder)]))
        .watch();
  }

  Future<void> addSubtask(String taskId, String title) {
    return into(subtasks).insert(Subtask(
      id: _uuid.v4(),
      taskId: taskId,
      title: title,
      done: false,
      sortOrder: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> setSubtaskDone(String id, bool done) {
    return (update(subtasks)..where((s) => s.id.equals(id)))
        .write(SubtasksCompanion(done: Value(done)));
  }

  Future<void> deleteSubtask(String id) =>
      (delete(subtasks)..where((s) => s.id.equals(id))).go();

  // ---------------------------------------------------------------------------
  // Labels
  // ---------------------------------------------------------------------------

  Stream<List<Label>> watchLabels() {
    return (select(labels)..orderBy([(l) => OrderingTerm.asc(l.name)])).watch();
  }

  Future<Label> createLabel(String name, int color) async {
    final label = Label(id: _uuid.v4(), name: name, color: color);
    await into(labels).insert(label);
    return label;
  }

  Future<void> deleteLabel(String id) =>
      (delete(labels)..where((l) => l.id.equals(id))).go();

  Stream<List<Label>> watchLabelsForTask(String taskId) {
    final query = select(labels).join([
      innerJoin(taskLabels, taskLabels.labelId.equalsExp(labels.id)),
    ])
      ..where(taskLabels.taskId.equals(taskId));
    return query
        .watch()
        .map((rows) => [for (final row in rows) row.readTable(labels)]);
  }

  Future<void> setTaskLabels(String taskId, Set<String> labelIds) {
    return transaction(() async {
      await (delete(taskLabels)..where((tl) => tl.taskId.equals(taskId))).go();
      for (final labelId in labelIds) {
        await into(taskLabels)
            .insert(TaskLabel(taskId: taskId, labelId: labelId));
      }
    });
  }
}
