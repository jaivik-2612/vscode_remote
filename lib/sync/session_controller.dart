import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workspace.dart';
import '../providers.dart';
import 'protocol.dart';
import 'session.dart';

sealed class SessionState {
  const SessionState();

  bool get isActive => this is SessionHosting || this is SessionConnected;
}

class SessionIdle extends SessionState {
  const SessionIdle();
}

class SessionStarting extends SessionState {
  const SessionStarting();
}

class SessionHosting extends SessionState {
  const SessionHosting({
    required this.addresses,
    required this.port,
    required this.code,
    required this.members,
  });

  final List<String> addresses;
  final int port;
  final String code;
  final List<SessionMember> members;
}

class SessionConnected extends SessionState {
  const SessionConnected({
    required this.hostAddress,
    required this.members,
    this.memberId,
  });

  final String hostAddress;
  final List<SessionMember> members;
  final String? memberId;
}

class SessionFailed extends SessionState {
  const SessionFailed(this.message);

  final String message;
}

class SessionController extends Notifier<SessionState> {
  HostSession? _host;
  ClientSession? _client;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  SessionState build() => const SessionIdle();

  /// Called by [Workspace] for every local mutation while a session is live.
  void sendOps(List<SyncOp> ops) {
    _host?.broadcastOps(ops);
    _client?.sendOps(ops);
  }

  Future<void> startHosting(String hostName) async {
    if (state.isActive) await leave();
    state = const SessionStarting();
    try {
      // The host shares their personal workspace.
      ref.read(databaseNameProvider.notifier).set(DatabaseNameNotifier.personal);
      final host = HostSession(
        db: ref.read(appDatabaseProvider),
        hostName: hostName.trim().isEmpty ? 'Host' : hostName.trim(),
      );
      await host.start();
      _host = host;
      final addresses = await localAddresses();
      void publish() {
        state = SessionHosting(
          addresses: addresses,
          port: host.boundPort,
          code: host.code,
          members: host.members,
        );
      }

      publish();
      _subscriptions.add(host.membersStream.listen((_) => publish()));
    } on SocketException catch (e) {
      await _cleanup();
      state = SessionFailed('Could not start the server: ${e.message}');
    }
  }

  Future<void> join({
    required String address,
    required String code,
    required String name,
  }) async {
    if (state.isActive) await leave();
    state = const SessionStarting();
    try {
      // Work in the separate session database; personal data stays untouched.
      ref
          .read(databaseNameProvider.notifier)
          .set(DatabaseNameNotifier.teamSession);
      final client = ClientSession(db: ref.read(appDatabaseProvider));
      await client.connect(address: address.trim(), code: code, name: name);
      _client = client;
      void publish() {
        state = SessionConnected(
          hostAddress: address.trim(),
          members: client.members,
          memberId: client.memberId,
        );
      }

      publish();
      _subscriptions.add(client.membersStream.listen((_) => publish()));
      _subscriptions.add(client.onDisconnected.listen((_) async {
        await _cleanup();
        state = const SessionFailed(
            'Connection to the host was lost. Join again when they are back '
            'online — your personal workspace is untouched.');
      }));
    } on SessionRejectedException catch (e) {
      await _cleanup();
      state = SessionFailed(e.reason);
    } on TimeoutException {
      await _cleanup();
      state = const SessionFailed(
          'Could not reach the host. Check the address and that both devices '
          'are on the same network.');
    } on SocketException {
      await _cleanup();
      state = const SessionFailed(
          'Could not reach the host. Check the address and that both devices '
          'are on the same network.');
    }
  }

  Future<void> leave() async {
    await _cleanup();
    state = const SessionIdle();
  }

  /// After a failure, return to idle (and the personal workspace).
  Future<void> acknowledgeFailure() => leave();

  Future<void> _cleanup() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final host = _host;
    final client = _client;
    _host = null;
    _client = null;
    await host?.stop();
    await client?.close();
    ref.read(databaseNameProvider.notifier).set(DatabaseNameNotifier.personal);
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

/// The single mutation path for the UI. Ops apply to the active database and
/// are relayed through the live session, if any.
final workspaceProvider = Provider<Workspace>((ref) {
  return Workspace(
    ref.watch(appDatabaseProvider),
    onOps: (ops) =>
        ref.read(sessionControllerProvider.notifier).sendOps(ops),
  );
});
