import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/enums.dart';
import '../../providers.dart';
import '../../sync/session_controller.dart';
import '../../widgets/common.dart';
import '../board/board_page.dart';
import '../tasks/task_editor.dart';
import 'project_editor.dart';

/// A single project: kanban board or flat list, toggleable.
class ProjectPage extends ConsumerStatefulWidget {
  const ProjectPage({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends ConsumerState<ProjectPage> {
  bool _showBoard = true;

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId)).value;
    if (project == null) {
      // Deleted while open (e.g. from another window): fall back gracefully.
      return const Scaffold(body: SizedBox.shrink());
    }
    final db = ref.read(workspaceProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ProjectAvatar(project: project, size: 30),
            const SizedBox(width: 10),
            Flexible(child: Text(project.name)),
          ],
        ),
        actions: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.view_kanban_outlined, size: 18),
                tooltip: 'Board',
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.view_list_outlined, size: 18),
                tooltip: 'List',
              ),
            ],
            selected: {_showBoard},
            onSelectionChanged: (selection) =>
                setState(() => _showBoard = selection.first),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'edit':
                  await showProjectEditor(context, project: project);
                case 'archive':
                  await db.setProjectArchived(project.id, !project.archived);
                  if (context.mounted && !project.archived) {
                    Navigator.pop(context);
                  }
                case 'delete':
                  final ok = await confirmDialog(
                    context,
                    title: 'Delete project?',
                    message:
                        '"${project.name}" and all of its tasks will be permanently deleted. Consider archiving instead.',
                  );
                  if (ok) {
                    await db.deleteProject(project.id);
                    if (context.mounted) Navigator.pop(context);
                  }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Edit project'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'archive',
                child: ListTile(
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(project.archived ? 'Unarchive' : 'Archive'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete project'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showTaskEditor(context, projectId: project.id),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
      body: _showBoard
          ? BoardView(projectId: project.id)
          : _ProjectTaskList(projectId: project.id),
    );
  }
}

class _ProjectTaskList extends ConsumerWidget {
  const _ProjectTaskList({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks =
        ref.watch(projectTasksProvider(projectId)).value ?? const [];
    if (tasks.isEmpty) {
      return const EmptyState(
        icon: Icons.task_alt,
        title: 'No tasks yet',
        subtitle: 'Create your first task with the button below.',
      );
    }

    final sections = [
      for (final status in TaskStatus.values)
        (status, tasks.where((t) => t.status == status).toList()),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final (status, sectionTasks) in sections)
          if (sectionTasks.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Icon(status.icon,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    '${status.label} · ${sectionTasks.length}',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            for (final task in sectionTasks) TaskListTile(task: task),
          ],
      ],
    );
  }
}

/// A task row used by list views (project list, dashboard, search).
class TaskListTile extends ConsumerWidget {
  const TaskListTile({super.key, required this.task, this.project});

  final Task task;

  /// When set, shows which project the task belongs to (cross-project views).
  final Project? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final db = ref.read(workspaceProvider);
    final done = task.status == TaskStatus.done;

    return ListTile(
      leading: Checkbox(
        value: done,
        shape: const CircleBorder(),
        onChanged: (value) => db.moveTask(
          task.id,
          value == true ? TaskStatus.done : TaskStatus.todo,
          task.sortOrder,
        ),
      ),
      title: Text(
        task.title,
        style: done
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: scheme.onSurfaceVariant,
              )
            : null,
      ),
      subtitle: project != null || task.dueDate != null
          ? Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (project != null) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Color(project!.color),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        project!.name,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (task.dueDate != null)
                    DueDateChip(dueDate: task.dueDate!, done: done),
                ],
              ),
            )
          : null,
      trailing: PriorityChip(priority: task.priority, compact: true),
      onTap: () => showTaskEditor(context, task: task),
    );
  }
}
