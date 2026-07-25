import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/session_controller.dart';
import '../../sync/sync_service.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final syncStatus = ref.watch(syncStatusProvider).value ??
        const SyncStatus(SyncState.localOnly);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined, size: 18),
                  tooltip: 'Light',
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined, size: 18),
                  tooltip: 'System',
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined, size: 18),
                  tooltip: 'Dark',
                ),
              ],
              selected: {themeMode},
              onSelectionChanged: (selection) =>
                  ref.read(themeModeProvider.notifier).set(selection.first),
            ),
          ),
          const Divider(),
          const _SectionHeader('Sync'),
          _SyncCard(status: syncStatus),
          const Divider(),
          const _SectionHeader('Your data'),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('Export backup'),
            subtitle: const Text(
                'Copies your full workspace as JSON to the clipboard.'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final json = await ref.read(backupCodecProvider).export();
              await Clipboard.setData(ClipboardData(text: json));
              messenger.showSnackBar(const SnackBar(
                content: Text(
                    'Backup copied to clipboard. Paste it into a file to keep it safe.'),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Import backup'),
            subtitle:
                const Text('Replaces everything with a pasted backup.'),
            onTap: () {
              // A restore would bypass the op stream and desync everyone.
              if (ref.read(sessionControllerProvider).isActive) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('Leave the team session before importing a backup.'),
                ));
                return;
              }
              _importBackup(context, ref);
            },
          ),
          const Divider(),
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.explore_outlined),
            title: Text('Waypoint'),
            subtitle: Text(
                'Free, local-first project management for small teams.\nVersion 0.1.0'),
          ),
        ],
      ),
    );
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import backup'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Paste a Waypoint backup below. This replaces all current data.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 4,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '{ "format": "waypoint-backup", … }',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(backupCodecProvider).import(controller.text);
      messenger.showSnackBar(
          const SnackBar(content: Text('Backup imported.')));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Import failed: ${e.message}'),
      ));
    }
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status.state == SyncState.localOnly
                      ? Icons.laptop_outlined
                      : Icons.cloud_done_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Text(
                  status.state == SyncState.localOnly
                      ? 'Local only'
                      : 'Synced',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Everything in Waypoint is stored on this device and every '
              'feature is free — that never changes. Optional cloud sync '
              '(end-to-end encrypted, across all your devices) is coming as '
              'a paid add-on for people who want it, and backups will always '
              'be exportable either way.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
