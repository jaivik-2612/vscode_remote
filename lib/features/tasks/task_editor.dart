import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/enums.dart';
import '../../data/workspace.dart';
import '../../providers.dart';
import '../../sync/session_controller.dart';
import '../../widgets/common.dart';

/// Opens the task editor. Pass [task] to edit, or just [projectId] to create.
Future<void> showTaskEditor(
  BuildContext context, {
  Task? task,
  String? projectId,
  TaskStatus initialStatus = TaskStatus.todo,
}) {
  assert(task != null || projectId != null);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: TaskEditorSheet(
        task: task,
        projectId: projectId ?? task!.projectId,
        initialStatus: initialStatus,
      ),
    ),
  );
}

class TaskEditorSheet extends ConsumerStatefulWidget {
  const TaskEditorSheet({
    super.key,
    this.task,
    required this.projectId,
    this.initialStatus = TaskStatus.todo,
  });

  final Task? task;
  final String projectId;
  final TaskStatus initialStatus;

  @override
  ConsumerState<TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends ConsumerState<TaskEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  final _subtaskController = TextEditingController();

  late TaskStatus _status;
  late TaskPriority _priority;
  DateTime? _dueDate;

  bool get _isNew => widget.task == null;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.task?.title ?? '');
    _notes = TextEditingController(text: widget.task?.notes ?? '');
    _status = widget.task?.status ?? widget.initialStatus;
    _priority = widget.task?.priority ?? TaskPriority.none;
    _dueDate = widget.task?.dueDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _subtaskController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final db = ref.read(workspaceProvider);
    if (_isNew) {
      await db.createTask(
        projectId: widget.projectId,
        title: title,
        notes: _notes.text.trim(),
        status: _status,
        priority: _priority,
        dueDate: _dueDate,
      );
    } else {
      final old = widget.task!;
      await db.updateTask(old.copyWith(
        title: title,
        notes: _notes.text.trim(),
        status: _status,
        priority: _priority,
        dueDate: Value(_dueDate),
        completedAt: Value(
          _status == TaskStatus.done
              ? (old.completedAt ?? DateTime.now())
              : null,
        ),
      ));
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 365 * 5)),
      lastDate: now.add(const Duration(days: 365 * 10)),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: _isNew ? 0.6 : 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _isNew ? 'New task' : 'Edit task',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (!_isNew)
                IconButton(
                  tooltip: 'Delete task',
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: () async {
                    final ok = await confirmDialog(
                      context,
                      title: 'Delete task?',
                      message:
                          '"${widget.task!.title}" and its subtasks will be permanently deleted.',
                    );
                    if (ok) {
                      await ref
                          .read(workspaceProvider)
                          .deleteTask(widget.task!.id);
                      if (context.mounted) Navigator.pop(context);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _title,
            autofocus: _isNew,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<TaskStatus>(
                segments: [
                  for (final status in TaskStatus.values)
                    ButtonSegment(
                      value: status,
                      icon: Icon(status.icon, size: 16),
                      tooltip: status.label,
                    ),
                ],
                selected: {_status},
                onSelectionChanged: (selection) =>
                    setState(() => _status = selection.first),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<TaskPriority>(
                  initialValue: _priority,
                  decoration: const InputDecoration(
                    labelText: 'Priority',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final priority in TaskPriority.values)
                      DropdownMenuItem(
                        value: priority,
                        child: Row(
                          children: [
                            Icon(Icons.flag, size: 16, color: priority.color),
                            const SizedBox(width: 8),
                            Text(priority.label),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _priority = value ?? TaskPriority.none),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _pickDueDate,
                  onLongPress: _dueDate == null
                      ? null
                      : () => setState(() => _dueDate = null),
                  icon: const Icon(Icons.event, size: 18),
                  label: Text(
                    _dueDate == null
                        ? 'Due date'
                        : MaterialLocalizations.of(context)
                            .formatShortDate(_dueDate!),
                  ),
                ),
              ),
              if (_dueDate != null)
                IconButton(
                  tooltip: 'Clear due date',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _dueDate = null),
                ),
            ],
          ),
          if (!_isNew) ...[
            const SizedBox(height: 20),
            _LabelsSection(taskId: widget.task!.id),
            const SizedBox(height: 20),
            Text('Subtasks', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            _SubtasksSection(
              taskId: widget.task!.id,
              controller: _subtaskController,
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _save,
            child: Text(_isNew ? 'Create task' : 'Save changes'),
          ),
        ],
      ),
    );
  }
}

class _SubtasksSection extends ConsumerWidget {
  const _SubtasksSection({required this.taskId, required this.controller});

  final String taskId;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtasks = ref.watch(subtasksProvider(taskId)).value ?? [];
    final db = ref.read(workspaceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final subtask in subtasks)
          Row(
            children: [
              Checkbox(
                value: subtask.done,
                onChanged: (value) =>
                    db.setSubtaskDone(subtask.id, value ?? false),
              ),
              Expanded(
                child: Text(
                  subtask.title,
                  style: subtask.done
                      ? TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : null,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => db.deleteSubtask(subtask.id),
              ),
            ],
          ),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Add a subtask…',
            prefixIcon: Icon(Icons.add),
            border: InputBorder.none,
          ),
          onSubmitted: (value) {
            final title = value.trim();
            if (title.isEmpty) return;
            db.addSubtask(taskId, title);
            controller.clear();
          },
        ),
      ],
    );
  }
}

class _LabelsSection extends ConsumerWidget {
  const _LabelsSection({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allLabels = ref.watch(labelsProvider).value ?? [];
    final taskLabels = ref.watch(taskLabelsProvider(taskId)).value ?? [];
    final selectedIds = {for (final label in taskLabels) label.id};
    final db = ref.read(workspaceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Labels', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in allLabels)
              FilterChip(
                label: Text(label.name),
                selected: selectedIds.contains(label.id),
                checkmarkColor: Color(label.color),
                side: BorderSide(
                  color: Color(label.color).withValues(alpha: 0.6),
                ),
                onSelected: (selected) {
                  final next = {...selectedIds};
                  selected ? next.add(label.id) : next.remove(label.id);
                  db.setTaskLabels(taskId, next);
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('New label'),
              onPressed: () => _createLabel(context, db),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _createLabel(BuildContext context, Workspace db) async {
    final controller = TextEditingController();
    var color = projectColors.first.toARGB32();
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 16),
              ColorPickerRow(
                selected: color,
                onSelected: (value) => setState(() => color = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                await db.createLabel(name, color);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}
