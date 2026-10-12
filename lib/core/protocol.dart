import 'dart:convert';

/// Внутренний протокол Veil — JSON внутри зашифрованного конверта.
///
/// t = msg    сообщение          {id, text, reply?, secret?, p?}
/// t = rcpt   отчёт о доставке   {ids, s: d|r}
/// t = react  реакция            {id, e?}
/// t = hello  «я тебя добавил»   {p}
/// t = prof   обновился профиль  {p}
/// t = ttl    исчезающие сообщ.  {m}
/// t = typ    печатает (эфемерно)
/// t = ping   я в сети (эфемерно)
class Payload {
  Payload(this.type, [Map<String, dynamic>? data]) : data = data ?? {};

  final String type;
  final Map<String, dynamic> data;

  static const msg = 'msg';
  static const receipt = 'rcpt';
  static const react = 'react';
  static const hello = 'hello';
  static const profile = 'prof';
  static const ttl = 'ttl';
  static const typing = 'typ';
  static const ping = 'ping';

  String encode() => jsonEncode({'v': 1, 't': type, ...data});

  static Payload? decode(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final t = j.remove('t');
      j.remove('v');
      if (t is! String) return null;
      return Payload(t, j);
    } catch (_) {
      return null;
    }
  }

  String? str(String k) => data[k] is String ? data[k] as String : null;
  int? integer(String k) => data[k] is num ? (data[k] as num).toInt() : null;
  bool flag(String k) => data[k] == true;
}

/// Публичная визитка, которую видят друзья.
class VeilCard {
  VeilCard({required this.name, required this.emoji, required this.color, this.bio = ''});

  final String name;
  final String emoji;
  final int color;
  final String bio;

  Map<String, dynamic> toJson() => {
    'n': name,
    'e': emoji,
    'c': color,
    if (bio.isNotEmpty) 'b': bio,
  };

  static VeilCard? fromJson(Object? o) {
    if (o is! Map) return null;
    final n = o['n'], e = o['e'], c = o['c'];
    if (n is! String || e is! String || c is! num) return null;
    return VeilCard(
      name: n.length > 40 ? n.substring(0, 40) : n,
      emoji: e.length > 16 ? '🙂' : e,
      color: c.toInt(),
      bio: o['b'] is String ? (o['b'] as String) : '',
    );
  }
}

/// Ссылка-приглашение / содержимое QR-кода: `veil://add?k=PUBKEY&n=…&e=…&c=…`
class Invite {
  Invite(this.pubkey, this.card);

  final String pubkey;
  final VeilCard card;

  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  String encode() => Uri(
    scheme: 'veil',
    host: 'add',
    queryParameters: {'k': pubkey, 'n': card.name, 'e': card.emoji, 'c': '${card.color}'},
  ).toString();

  static Invite? parse(String raw) {
    final s = raw.trim();
    // Можно вставить и голый ключ.
    if (_hex.hasMatch(s.toLowerCase())) {
      return Invite(s.toLowerCase(), VeilCard(name: 'Друг', emoji: '🙂', color: 0));
    }
    final start = s.indexOf('veil://');
    if (start < 0) return null;
    final uri = Uri.tryParse(s.substring(start).split(RegExp(r'\s')).first);
    if (uri == null) return null;
    final k = uri.queryParameters['k']?.toLowerCase();
    if (k == null || !_hex.hasMatch(k)) return null;
    return Invite(
      k,
      VeilCard(
        name: uri.queryParameters['n'] ?? 'Друг',
        emoji: uri.queryParameters['e'] ?? '🙂',
        color: int.tryParse(uri.queryParameters['c'] ?? '') ?? 0,
      ),
    );
  }
}
