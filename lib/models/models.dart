import 'package:flutter/material.dart';

/// Статус доставки исходящего сообщения.
enum MsgStatus { sending, sent, delivered, read }

/// Тип сообщения.
enum MsgKind { text, voice }

/// Профиль владельца телефона. Ключи и профиль никогда не покидают устройство.
class Profile {
  Profile({
    required this.name,
    required this.emoji,
    required this.colors,
    required this.fingerprint,
    required this.veilId,
  });

  String name;
  String emoji;
  List<Color> colors;
  final String fingerprint;
  final String veilId;
}

/// Друг из списка контактов.
class Contact {
  Contact({
    required this.id,
    required this.name,
    required this.emoji,
    required this.colors,
    required this.fingerprint,
    this.online = false,
    this.bio = '',
    this.lastSeen,
    this.verified = false,
    this.hasStory = false,
  });

  final String id;
  final String name;
  final String emoji;
  final List<Color> colors;
  final String fingerprint;
  bool online;
  String bio;
  DateTime? lastSeen;
  bool verified;
  bool hasStory;
  bool blocked = false;

  /// Таймер исчезающих сообщений в минутах (0 — выключено).
  int disappearing = 0;
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
}
