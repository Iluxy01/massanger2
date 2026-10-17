import 'dart:convert';

/// Внутренний протокол Veil — JSON внутри зашифрованного конверта.
///
/// t = msg    сообщение          {id, text, reply?, secret?, p?, k?, att?, geo?, poll?}
/// t = vote   голос в опросе     {id, o: [номера вариантов]}
/// t = need   «не могу скачать файл» {id, r: [ретрансляторы, где я на связи]}
/// t = have   «положил туда»       {id, r: [ретрансляторы с кусками]}
/// ping и msg несут r — где отправитель сейчас на связи.
/// t = rcpt   отчёт о доставке   {ids, s: d|r}
/// t = react  реакция            {id, e?}
/// t = hello  «я тебя добавил»   {p}
/// t = prof   обновился профиль  {p}
/// t = ttl    исчезающие сообщ.  {m}
/// t = edit   правка своего     {id, text}
/// t = del    удалить у всех    {id}
/// t = pin    закрепить в чате  {id?} (без id — открепить)
/// t = seen1  одноразовое открыли {id} (у msg — once: true)
/// t = todo   общий список: {id, op: t|a, i, on?|tx?} — отметить / добавить пункт
/// (ключи «t» и «v» заняты: тип и версия конверта — в данных их не использовать)
/// У msg: oa — капсула времени (откроется не раньше, мс).
/// В группе у любого сигнала есть g (id группы), у сообщения — ещё gi (состав).
/// t = join   вступить в канал по ссылке {g, i: код, p} — автору канала
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
  static const vote = 'vote';
  static const need = 'need';
  static const have = 'have';
  static const edit = 'edit';
  static const delete = 'del';
  static const pin = 'pin';
  static const opened = 'seen1';
  static const todo = 'todo';
  static const join = 'join';

  Map<String, dynamic> toMap() => {...data, 'v': 1, 't': type};

  static Payload fromMap(Map<String, dynamic> m) {
    final d = Map<String, dynamic>.of(m)..remove('v');
    return Payload(d.remove('t') as String, d);
  }

  String encode() => jsonEncode(toMap());

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

/// Пригласительная ссылка канала:
/// `veil://ch?g=ID&a=КЛЮЧ_АВТОРА&i=КОД&n=Название&e=😀`. По ней любой может
/// попросить автора добавить его в подписчики.
class ChannelInvite {
  ChannelInvite({
    required this.id,
    required this.admin,
    required this.code,
    required this.name,
    required this.emoji,
  });

  final String id;
  final String admin;
  final String code;
  final String name;
  final String emoji;

  static final _hex = RegExp(r'^[0-9a-f]{64}$');
  static final _id = RegExp(r'^g_[0-9a-f]{8,36}$');
  static final _code = RegExp(r'^[0-9a-f]{8,32}$');

  String encode() => Uri(
    scheme: 'veil',
    host: 'ch',
    queryParameters: {'g': id, 'a': admin, 'i': code, 'n': name, 'e': emoji},
  ).toString();

  static ChannelInvite? parse(String raw) {
    final s = raw.trim();
    final start = s.indexOf('veil://ch');
    if (start < 0) return null;
    final uri = Uri.tryParse(s.substring(start).split(RegExp(r'\s')).first);
    if (uri == null || uri.host != 'ch') return null;
    final q = uri.queryParameters;
    final g = q['g'], a = q['a']?.toLowerCase(), i = q['i'];
    if (g == null || !_id.hasMatch(g) || a == null || !_hex.hasMatch(a)) return null;
    if (i == null || !_code.hasMatch(i)) return null;
    String clip(String? v, String d, int max) {
      final t = (v ?? '').trim();
      if (t.isEmpty) return d;
      return t.length > max ? t.substring(0, max) : t;
    }

    return ChannelInvite(
      id: g,
      admin: a,
      code: i,
      name: clip(q['n'], 'Канал', 40),
      emoji: clip(q['e'], '📢', 16),
    );
  }
}
