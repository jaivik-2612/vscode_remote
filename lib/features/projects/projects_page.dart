import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'project_editor.dart';
import 'project_page.dart';

/// All projects, with live progress; archived ones behind a toggle.
class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({super.key});

  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final projects = ref
            .watch(_showArchived ? archivedProjectsProvider : projectsProvider)
            .value ??
        const <Project>[];
    final progress =
        ref.watch(projectProgressProvider).value ?? const {};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show active' : 'Show archived',
            icon: Icon(
                _showArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showProjectEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('New project'),
            ),
      body: projects.isEmpty
          ? EmptyState(
              icon: _showArchived
                  ? Icons.archive_outlined
                  : Icons.folder_open_outlined,
              title:
                  _showArchived ? 'No archived projects' : 'No projects yet',
              subtitle: _showArchived
                  ? 'Projects you archive will show up here.'
                  : 'A project holds your tasks, board and labels.\nCreate one to get going.',
              action: _showArchived
                  ? null
                  : FilledButton.icon(
                      onPressed: () => showProjectEditor(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Create a project'),
                    ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 340).floor().clamp(1, 4);
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: 130,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: projects.length,
                  itemBuilder: (context, index) => _ProjectCard(
                    project: projects[index],
                    progress: progress[projects[index].id] ??
                        const ProjectProgress(open: 0, done: 0),
                  ),
                );
              },
            ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.progress});

  final Project project;
  final ProjectProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ProjectPage(projectId: project.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProjectAvatar(project: project),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (project.description.isNotEmpty)
                          Text(
                            project.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress.fraction,
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: Color(project.color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    progress.total == 0
                        ? 'No tasks'
                        : '${progress.done}/${progress.total} done',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
