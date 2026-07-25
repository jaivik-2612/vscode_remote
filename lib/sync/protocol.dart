/// Wire protocol for LAN team sessions.
///
/// Every mutation in the app is expressed as a small list of row-level
/// [SyncOp]s: idempotent upserts (full row) and deletes (by primary key).
/// Rows are keyed by UUID, so applying the same op twice, or applying your
/// own op echoed back by the host, is harmless. The host is authoritative:
/// it applies ops in arrival order and rebroadcasts them to every client,
/// which keeps all replicas converged without merge logic.
library;

/// Bump when the message or op format changes incompatibly.
const syncProtocolVersion = 1;

/// Default TCP port for hosted sessions.
const defaultSessionPort = 8722;

sealed class SyncOp {
  const SyncOp();

  Map<String, Object?> toJson();

  static SyncOp fromJson(Map<String, Object?> json) {
    return switch (json['op']) {
      'upsert' => UpsertOp(
          json['table'] as String,
          (json['row'] as Map).cast<String, Object?>(),
        ),
      'delete' => DeleteOp(json['table'] as String, json['id'] as String),
      'clearTaskLabels' => ClearTaskLabelsOp(json['taskId'] as String),
      _ => throw FormatException('Unknown op: ${json['op']}'),
    };
  }
}

/// Insert-or-replace a full row. [table] is the SQL table name.
class UpsertOp extends SyncOp {
  const UpsertOp(this.table, this.row);

  final String table;
  final Map<String, Object?> row;

  @override
  Map<String, Object?> toJson() => {'op': 'upsert', 'table': table, 'row': row};
}

/// Delete by `id` primary key. Cascades locally on every replica, so child
/// rows never need their own delete ops.
class DeleteOp extends SyncOp {
  const DeleteOp(this.table, this.id);

  final String table;
  final String id;

  @override
  Map<String, Object?> toJson() => {'op': 'delete', 'table': table, 'id': id};
}

/// Remove all label links for a task (followed by upserts of the new set).
class ClearTaskLabelsOp extends SyncOp {
  const ClearTaskLabelsOp(this.taskId);

  final String taskId;

  @override
  Map<String, Object?> toJson() => {'op': 'clearTaskLabels', 'taskId': taskId};
}

/// A person in a session.
class SessionMember {
  const SessionMember({
    required this.id,
    required this.name,
    required this.isHost,
  });

  final String id;
  final String name;
  final bool isHost;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'isHost': isHost};

  static SessionMember fromJson(Map<String, Object?> json) => SessionMember(
        id: json['id'] as String,
        name: json['name'] as String,
        isHost: json['isHost'] as bool,
      );
}

// -----------------------------------------------------------------------------
// Messages (one JSON object per WebSocket frame, discriminated by `kind`).
// -----------------------------------------------------------------------------

Map<String, Object?> helloMessage(String name, String code) => {
      'kind': 'hello',
      'protocol': syncProtocolVersion,
      'name': name,
      'code': code,
    };

Map<String, Object?> welcomeMessage(
  Map<String, Object?> snapshot,
  List<SessionMember> members,
  String yourId,
) =>
    {
      'kind': 'welcome',
      'snapshot': snapshot,
      'members': [for (final member in members) member.toJson()],
      'you': yourId,
    };

Map<String, Object?> rejectMessage(String reason) =>
    {'kind': 'reject', 'reason': reason};

Map<String, Object?> opsMessage(List<SyncOp> ops) => {
      'kind': 'ops',
      'ops': [for (final op in ops) op.toJson()],
    };

Map<String, Object?> membersMessage(List<SessionMember> members) => {
      'kind': 'members',
      'members': [for (final member in members) member.toJson()],
    };

List<SyncOp> opsFromMessage(Map<String, Object?> message) => [
      for (final op in (message['ops'] as List))
        SyncOp.fromJson((op as Map).cast<String, Object?>()),
    ];

List<SessionMember> membersFromMessage(Map<String, Object?> message) => [
      for (final member in (message['members'] as List))
        SessionMember.fromJson((member as Map).cast<String, Object?>()),
    ];
