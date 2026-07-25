import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sync/protocol.dart';
import '../../sync/session_controller.dart';

/// Host or join a live team session on the local network.
class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({super.key});

  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    final controller = ref.read(sessionControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      body: switch (session) {
        SessionIdle() => _buildIdle(context),
        SessionStarting() => const Center(child: CircularProgressIndicator()),
        SessionHosting(:final addresses, :final port, :final code, :final members) =>
          _buildHosting(context, controller, addresses, port, code, members),
        SessionConnected(:final hostAddress, :final members, :final memberId) =>
          _buildConnected(context, controller, hostAddress, members, memberId),
        SessionFailed(:final message) =>
          _buildFailed(context, controller, message),
      },
    );
  }

  Widget _buildIdle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = ref.read(sessionControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Work on one workspace together, over your local network. '
          'No account, no cloud — one person hosts, everyone else joins.',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Your name',
            hintText: 'Shown to everyone in the session',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          icon: Icons.wifi_tethering,
          title: 'Host a session',
          subtitle:
              'Share this device\'s workspace live. Teammates on the same '
              'network join with your address and a code.',
          child: FilledButton.icon(
            onPressed: () => controller.startHosting(_name.text),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start hosting'),
          ),
        ),
        const SizedBox(height: 12),
        _SectionCard(
          icon: Icons.login,
          title: 'Join a session',
          subtitle:
              'Connects to a host and mirrors their workspace. Your personal '
              'projects are kept separate and untouched.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _address,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Host address',
                  hintText: 'e.g. 192.168.1.23 or 192.168.1.23:$defaultSessionPort',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Join code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => controller.join(
                  address: _address.text,
                  code: _code.text,
                  name: _name.text.trim().isEmpty ? 'Teammate' : _name.text,
                ),
                icon: const Icon(Icons.login),
                label: const Text('Join'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHosting(
    BuildContext context,
    SessionController controller,
    List<String> addresses,
    int port,
    String code,
    List<SessionMember> members,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          icon: Icons.wifi_tethering,
          title: 'Hosting — your workspace is live',
          subtitle: 'Teammates on this network can join with:',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final address in addresses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(
                    '$address:$port',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Join code:',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(width: 10),
                  SelectableText(
                    code,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          letterSpacing: 4,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary,
                        ),
                  ),
                  IconButton(
                    tooltip: 'Copy code',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: code)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Anyone on this network with the code can view and edit this '
                'workspace — host on networks you trust.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _MembersCard(members: members),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: controller.leave,
          icon: const Icon(Icons.stop),
          label: const Text('Stop hosting'),
        ),
      ],
    );
  }

  Widget _buildConnected(
    BuildContext context,
    SessionController controller,
    String hostAddress,
    List<SessionMember> members,
    String? memberId,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          icon: Icons.cloud_done_outlined,
          title: 'Connected to $hostAddress',
          subtitle:
              'You are working on the host\'s workspace — every change syncs '
              'live for everyone. Your personal projects are safe in your own '
              'workspace and come back when you leave.',
          child: const SizedBox.shrink(),
        ),
        const SizedBox(height: 12),
        _MembersCard(members: members, you: memberId),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: controller.leave,
          icon: const Icon(Icons.logout),
          label: const Text('Leave session'),
        ),
        const SizedBox(height: 8),
        Text(
          'Leaving keeps a local copy of the shared workspace on this device.',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildFailed(
      BuildContext context, SessionController controller, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off,
                size: 56, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text('Session problem',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: controller.acknowledgeFailure,
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _MembersCard extends StatelessWidget {
  const _MembersCard({required this.members, this.you});

  final List<SessionMember> members;
  final String? you;

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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'In this session · ${members.length}',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final member in members)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    member.name.characters.first.toUpperCase(),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onPrimaryContainer),
                  ),
                ),
                title: Text(member.name),
                trailing: member.isHost
                    ? Chip(
                        label: const Text('Host'),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: scheme.outlineVariant),
                      )
                    : member.id == you
                        ? const Chip(
                            label: Text('You'),
                            visualDensity: VisualDensity.compact,
                          )
                        : null,
              ),
          ],
        ),
      ),
    );
  }
}
