import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// Статус доставки исходящего сообщения.
/// Для входящих: delivered — ещё не отправили отчёт о прочтении, read — отправили.
enum MsgStatus { sending, sent, delivered, read }

/// Тип сообщения.
enum MsgKind { text, voice }

List<Color> gradientAt(int i) => avatarGradients[i.abs() % avatarGradients.length];

/// Профиль владельца телефона. Ключи и профиль никогда не покидают устройство.
class Profile {
  Profile({
    required this.name,
    required this.emoji,
    required this.colorIndex,
    required this.fingerprint,
    this.bio = '',
  });

  String name;
  String emoji;
  int colorIndex;
  String bio;

  /// Публичный ключ (64 hex-символа). Это и есть адрес в Veil.
  final String fingerprint;

  List<Color> get colors => gradientAt(colorIndex);

  String get veilId =>
      'VEIL-${fingerprint.substring(0, 4)}-${fingerprint.substring(4, 8)}-'
              '${fingerprint.substring(8, 12)}'
          .toUpperCase();

  Map<String, dynamic> toJson() => {
    'name': name,
    'emoji': emoji,
    'color': colorIndex,
    'bio': bio,
    'pub': fingerprint,
  };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String,
    emoji: j['emoji'] as String,
    colorIndex: (j['color'] as num).toInt(),
    bio: j['bio'] as String? ?? '',
    fingerprint: j['pub'] as String,
  );
}

/// Друг из списка контактов. id == его публичный ключ.
class Contact {
  Contact({
    required this.id,
    required this.name,
    required this.emoji,
    required this.colorIndex,
    String? fingerprint,
    this.online = false,
    this.bio = '',
    this.lastSeen,
    this.verified = false,
    this.hasStory = false,
    this.request = false,
  }) : fingerprint = fingerprint ?? id;

  final String id;
  String name;
  String emoji;
  int colorIndex;
  final String fingerprint;
  bool online;
  String bio;
  DateTime? lastSeen;
  bool verified;
  bool hasStory;
  bool blocked = false;

  /// Добавил нас сам, а мы его ещё не подтвердили.
  bool request;

  /// Таймер исчезающих сообщений в минутах (0 — выключено).
  int disappearing = 0;

  List<Color> get colors => gradientAt(colorIndex);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'color': colorIndex,
    'bio': bio,
    'verified': verified,
    'blocked': blocked,
    'request': request,
    'ttl': disappearing,
    if (lastSeen != null) 'seen': lastSeen!.millisecondsSinceEpoch,
  };

  static Contact fromJson(Map<String, dynamic> j) =>
      Contact(
          id: j['id'] as String,
          name: j['name'] as String,
          emoji: j['emoji'] as String,
          colorIndex: (j['color'] as num).toInt(),
          bio: j['bio'] as String? ?? '',
          verified: j['verified'] == true,
          request: j['request'] == true,
          lastSeen: j['seen'] is num
              ? DateTime.fromMillisecondsSinceEpoch((j['seen'] as num).toInt())
              : null,
        )
        ..blocked = j['blocked'] == true
        ..disappearing = (j['ttl'] as num?)?.toInt() ?? 0;
}

/// Одно сообщение переписки. Хранится только локально.
class Message {
  Message({
    required this.id,
    required this.mine,
    required this.text,
    required this.time,
    this.status = MsgStatus.read,
    this.replyTo,
    this.secret = false,
    this.kind = MsgKind.text,
    this.voiceSeconds = 0,
    this.reaction,
  });

  final String id;
  final bool mine;
  final String text;
  final DateTime time;
  MsgStatus status;
  final Message? replyTo;

  /// «Секретное» сообщение — размыто, пока его не коснёшься.
  final bool secret;
  bool revealed = false;
  final MsgKind kind;
  final int voiceSeconds;
  String? reaction;

  Map<String, dynamic> toJson() => {
    'id': id,
    'mine': mine,
    'text': text,
    'ts': time.millisecondsSinceEpoch,
    'st': status.index,
    if (replyTo != null) 'reply': replyTo!.id,
    if (secret) 'secret': true,
    if (reaction != null) 'react': reaction,
  };

  /// [lookup] находит сообщение, на которое ответили.
  static Message fromJson(Map<String, dynamic> j, Message? Function(String id) lookup) => Message(
    id: j['id'] as String,
    mine: j['mine'] == true,
    text: j['text'] as String? ?? '',
    time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
    status: MsgStatus.values[((j['st'] as num?)?.toInt() ?? 3).clamp(0, 3)],
    replyTo: j['reply'] is String ? lookup(j['reply'] as String) : null,
    secret: j['secret'] == true,
    reaction: j['react'] as String?,
  );
}
