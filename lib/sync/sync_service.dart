import 'dart:async';

/// Where sync stands right now, surfaced in Settings.
enum SyncState { localOnly, idle, syncing, error }

class SyncStatus {
  const SyncStatus(this.state, {this.lastSyncedAt, this.message});

  final SyncState state;
  final DateTime? lastSyncedAt;
  final String? message;
}

/// The seam between the free app and the (optional) paid sync backend.
///
/// Waypoint's model mirrors Obsidian's: every feature works locally, forever,
/// for free. Revenue comes from convenience — hosted end-to-end-encrypted sync
/// and file storage for people who want their workspace on every device
/// without running anything themselves.
///
/// The whole app talks to this interface only, so:
///  * [LocalOnlySyncService] is the default and keeps the app 100% offline.
///  * A future `CloudSyncService` implements the same interface against the
///    hosted backend (snapshot format shared with `BackupCodec`).
///  * Self-hosters can implement it against their own storage — the interface
///    is deliberately small and the wire format is plain JSON.
abstract class SyncService {
  Stream<SyncStatus> get status;

  /// Pushes local changes and pulls remote ones. No-op when local-only.
  Future<void> syncNow();

  Future<void> dispose();
}

/// Default implementation: everything stays on this device.
class LocalOnlySyncService implements SyncService {
  final _controller = StreamController<SyncStatus>.broadcast(
    onListen: () {},
  );

  @override
  Stream<SyncStatus> get status async* {
    yield const SyncStatus(SyncState.localOnly);
    yield* _controller.stream;
  }

  @override
  Future<void> syncNow() async {
    // Nothing to do: there is no remote.
  }

  @override
  Future<void> dispose() => _controller.close();
}
