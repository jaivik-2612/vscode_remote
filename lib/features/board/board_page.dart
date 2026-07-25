import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/enums.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../tasks/task_editor.dart';

const _columnWidth = 300.0;

bool get _isDesktop =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// Kanban board for a single project: one column per [TaskStatus], with
/// drag & drop between and within columns.
class BoardView extends ConsumerWidget {
  const BoardView({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(projectId));
    final tasks = tasksAsync.value ?? const <Task>[];

    final byStatus = {
      for (final status in TaskStatus.values)
        status: tasks.where((t) => t.status == status).toList(),
    };

    return ScrollConfiguration(
      // Let users drag-scroll the board with a mouse on desktop.
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
        },
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          for (final status in TaskStatus.values)
            _BoardColumn(
              projectId: projectId,
              status: status,
              tasks: byStatus[status]!,
            ),
        ],
      ),
    );
  }
}

class _BoardColumn extends ConsumerWidget {
  const _BoardColumn({
    required this.projectId,
    required this.status,
    required this.tasks,
  });

  final String projectId;
  final TaskStatus status;
  final List<Task> tasks;

  double _orderForInsert(int index) {
    if (tasks.isEmpty) return DateTime.now().millisecondsSinceEpoch.toDouble();
    if (index <= 0) return tasks.first.sortOrder - 1000;
    if (index >= tasks.length) return tasks.last.sortOrder + 1000;
    return (tasks[index - 1].sortOrder + tasks[index].sortOrder) / 2;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final db = ref.read(appDatabaseProvider);

    return Container(
      width: _columnWidth,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Icon(status.icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  status.label,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${tasks.length}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Add task',
                  icon: const Icon(Icons.add, size: 20),
                  onPressed: () => showTaskEditor(
                    context,
                    projectId: projectId,
                    initialStatus: status,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: DragTarget<Task>(
              onWillAcceptWithDetails: (details) => true,
              onAcceptWithDetails: (details) {
                final task = details.data;
                // Dropped on the column background: append to the end.
                final withoutDragged =
                    tasks.where((t) => t.id != task.id).toList();
                final order = withoutDragged.isEmpty
                    ? DateTime.now().millisecondsSinceEpoch.toDouble()
                    : withoutDragged.last.sortOrder + 1000;
                db.moveTask(task.id, status, order);
              },
              builder: (context, candidates, rejected) => Container(
                decoration: candidates.isNotEmpty
                    ? BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(16),
                      )
                    : null,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return _DropSlot(
                      onAccept: (dragged) {
                        if (dragged.id == task.id) return;
                        var insertAt = index;
                        final draggedIndex =
                            tasks.indexWhere((t) => t.id == dragged.id);
                        if (draggedIndex != -1 && draggedIndex < index) {
                          insertAt = index; // dropping below its old slot
                        }
                        db.moveTask(
                            dragged.id, status, _orderForInsert(insertAt));
                      },
                      child: _DraggableTaskCard(task: task),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps a card so dragging another card over it inserts above it.
class _DropSlot extends StatelessWidget {
  const _DropSlot({required this.onAccept, required this.child});

  final ValueChanged<Task> onAccept;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<Task>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidates, rejected) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: candidates.isNotEmpty ? 40 : 0,
            margin: candidates.isNotEmpty
                ? const EdgeInsets.only(bottom: 8)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DraggableTaskCard extends StatelessWidget {
  const _DraggableTaskCard({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final card = _TaskCard(task: task);
    final feedback = Material(
      color: Colors.transparent,
      child: SizedBox(
        width: _columnWidth - 16,
        child: Opacity(opacity: 0.9, child: card),
      ),
    );
    final childWhenDragging = Opacity(opacity: 0.35, child: card);

    if (_isDesktop) {
      return Draggable<Task>(
        data: task,
        feedback: feedback,
        childWhenDragging: childWhenDragging,
        child: card,
      );
    }
    return LongPressDraggable<Task>(
      data: task,
      delay: const Duration(milliseconds: 200),
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: card,
    );
  }
}

class _TaskCard extends ConsumerWidget {
  const _TaskCard({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final labels = ref.watch(taskLabelsProvider(task.id)).value ?? [];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showTaskEditor(context, task: task),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      decoration: task.status == TaskStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                    ),
              ),
              if (task.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.notes,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (labels.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [for (final label in labels) LabelChip(label: label)],
                ),
              ],
              if (task.dueDate != null || task.priority != TaskPriority.none) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (task.dueDate != null)
                      DueDateChip(
                        dueDate: task.dueDate!,
                        done: task.status == TaskStatus.done,
                      ),
                    const Spacer(),
                    PriorityChip(priority: task.priority, compact: true),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
