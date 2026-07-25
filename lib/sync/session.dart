import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../data/backup.dart';
import '../data/database.dart';
import 'protocol.dart';

const _uuid = Uuid();

String generateJoinCode() {
  // No easily-confused characters (0/O, 1/I).
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)])
      .join();
}

/// LAN addresses this device can be reached at.
Future<List<String>> localAddresses() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses) address.address,
  ];
}

/// The project manager's side: serves this device's workspace to teammates
/// on the local network over plain WebSockets.
///
/// Trust model (v1): anyone on the LAN with the join code can read and edit
/// the workspace. Run it on networks you trust; TLS + per-member auth is on
/// the roadmap alongside hosted sync.
class HostSession {
  HostSession({
    required this.db,
    required String hostName,
    this.port = defaultSessionPort,
  })  : code = generateJoinCode(),
        _hostMember = SessionMember(
          id: _uuid.v4(),
          name: hostName,
          isHost: true,
        );

  final AppDatabase db;
  final int port;
  final String code;
  final SessionMember _hostMember;

  HttpServer? _server;
  final Map<WebSocket, SessionMember> _clients = {};
  final _membersController =
      StreamController<List<SessionMember>>.broadcast();

  List<SessionMember> get members => [_hostMember, ..._clients.values];
  Stream<List<SessionMember>> get membersStream => _membersController.stream;
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_handleRequest, onError: (Object _) {});
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('Waypoint session — connect with the Waypoint app.');
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen(
      (Object? data) => _handleMessage(socket, data),
      onDone: () => _dropClient(socket),
      onError: (Object _) => _dropClient(socket),
      cancelOnError: true,
    );
  }

  Future<void> _handleMessage(WebSocket socket, Object? data) async {
    final Map<String, Object?> message;
    try {
      message = (jsonDecode(data as String) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (message['kind']) {
      case 'hello':
        if (message['protocol'] != syncProtocolVersion) {
          _send(socket, rejectMessage(
              'Different app versions — update Waypoint on both devices.'));
          await socket.close();
          return;
        }
        if ((message['code'] as String?)?.toUpperCase() != code) {
          _send(socket, rejectMessage('Wrong join code.'));
          await socket.close();
          return;
        }
        final member = SessionMember(
          id: _uuid.v4(),
          name: (message['name'] as String?)?.trim().isNotEmpty == true
              ? (message['name'] as String).trim()
              : 'Teammate',
          isHost: false,
        );
        _clients[socket] = member;
        final snapshot = await BackupCodec(db).exportObject();
        _send(socket, welcomeMessage(snapshot, members, member.id));
        _broadcastMembers();
      case 'ops':
        if (!_clients.containsKey(socket)) return;
        final ops = opsFromMessage(message);
        await db.applyOps(ops);
        _broadcast(opsMessage(ops), except: socket);
    }
  }

  /// Relay the host's own edits to every connected teammate.
  void broadcastOps(List<SyncOp> ops) => _broadcast(opsMessage(ops));

  void _broadcast(Map<String, Object?> message, {WebSocket? except}) {
    final encoded = jsonEncode(message);
    for (final socket in _clients.keys) {
      if (socket != except) socket.add(encoded);
    }
  }

  void _broadcastMembers() {
    _broadcast(membersMessage(members));
    _membersController.add(members);
  }

  void _dropClient(WebSocket socket) {
    if (_clients.remove(socket) != null) _broadcastMembers();
  }

  void _send(WebSocket socket, Map<String, Object?> message) =>
      socket.add(jsonEncode(message));

  Future<void> stop() async {
    for (final socket in _clients.keys.toList()) {
      await socket.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    await _membersController.close();
  }
}

/// A teammate's side: connects to a [HostSession], mirrors the shared
/// workspace into a local session database, and exchanges ops live.
class ClientSession {
  ClientSession({required this.db});

  final AppDatabase db;

  WebSocket? _socket;
  bool _closed = false;
  final _membersController =
      StreamController<List<SessionMember>>.broadcast();
  final _disconnectController = StreamController<void>.broadcast();

  List<SessionMember> _members = const [];
  String? memberId;

  List<SessionMember> get members => _members;
  Stream<List<SessionMember>> get membersStream => _membersController.stream;

  /// Fires once when the connection drops (never for a local [leave]).
  Stream<void> get onDisconnected => _disconnectController.stream;

  /// Connects and replaces [db]'s contents with the host's snapshot.
  /// Throws [SessionRejectedException] or [SocketException] on failure.
  Future<void> connect({
    required String address,
    required String code,
    required String name,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final hostPort = address.contains(':') ? address : '$address:$defaultSessionPort';
    final socket = await WebSocket.connect('ws://$hostPort').timeout(timeout);
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 5);

    final welcome = Completer<Map<String, Object?>>();
    socket.listen(
      (Object? data) {
        final Map<String, Object?> message;
        try {
          message = (jsonDecode(data as String) as Map).cast<String, Object?>();
        } catch (_) {
          return;
        }
        if (!welcome.isCompleted &&
            (message['kind'] == 'welcome' || message['kind'] == 'reject')) {
          welcome.complete(message);
          return;
        }
        _handleMessage(message);
      },
      onDone: _handleDisconnect,
      onError: (Object _) => _handleDisconnect(),
      cancelOnError: true,
    );

    socket.add(jsonEncode(helloMessage(name, code.toUpperCase())));
    final reply = await welcome.future.timeout(timeout);
    if (reply['kind'] == 'reject') {
      await close();
      throw SessionRejectedException(reply['reason'] as String? ?? 'Rejected');
    }
    memberId = reply['you'] as String?;
    await BackupCodec(db)
        .importObject(reply['snapshot'] as Map<String, Object?>?);
    _members = membersFromMessage(reply);
    _membersController.add(_members);
  }

  Future<void> _handleMessage(Map<String, Object?> message) async {
    // Frames can still be in flight while the socket is closing.
    if (_closed) return;
    switch (message['kind']) {
      case 'ops':
        await db.applyOps(opsFromMessage(message));
      case 'members':
        _members = membersFromMessage(message);
        _membersController.add(_members);
    }
  }

  void sendOps(List<SyncOp> ops) => _socket?.add(jsonEncode(opsMessage(ops)));

  void _handleDisconnect() {
    if (_socket != null) _disconnectController.add(null);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _membersController.close();
    await _disconnectController.close();
  }
}

class SessionRejectedException implements Exception {
  SessionRejectedException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
