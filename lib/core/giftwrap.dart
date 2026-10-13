import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'nip44.dart';
import 'nostr.dart';

/// Тройной конверт NIP-59 (как в NIP-17):
///
///   rumor (не подписан, наш JSON внутри)
///     → seal (kind 13, подписан отправителем, зашифрован для получателя)
///       → gift wrap (kind 1059, подписан СЛУЧАЙНЫМ одноразовым ключом)
///
/// Ретранслятор видит только одноразовый ключ, получателя и шифротекст —
/// ни отправителя, ни содержимого, ни точного времени.
class GiftWrap {
  static const kindRumor = 14;
  static const kindSeal = 13;
  static const kindWrap = 1059;

  /// Эфемерный вариант (печатает…, «в сети») — ретрансляторы его не хранят.
  static const kindWrapEphemeral = 21059;

  static final _rnd = Random.secure();

  /// Время в прошлом до 2 суток — чтобы по метке нельзя было связать события.
  static int _fuzzedNow() => nowSec() - _rnd.nextInt(2 * 24 * 3600);

  static Event wrap({
    required Keys sender,
    required String recipientPub,
    required String content,
    bool ephemeral = false,
    Duration ttl = const Duration(days: 7),
  }) {
    final rumor = Event.unsigned(
      sender.pub,
      kind: kindRumor,
      content: content,
      tags: [
        ['p', recipientPub],
      ],
    );
    final seal = Event.signed(
      sender,
      kind: kindSeal,
      createdAt: ephemeral ? nowSec() : _fuzzedNow(),
      content: Nip44.encrypt(
        jsonEncode(rumor.toJson()),
        Nip44.conversationKey(sender.priv, recipientPub),
      ),
    );
    final oneTime = Keys.generate();
    return Event.signed(
      oneTime,
      kind: ephemeral ? kindWrapEphemeral : kindWrap,
      createdAt: ephemeral ? nowSec() : _fuzzedNow(),
      content: Nip44.encrypt(
        jsonEncode(seal.toJson()),
        Nip44.conversationKey(oneTime.priv, recipientPub),
      ),
      tags: [
        ['p', recipientPub],
        if (!ephemeral) ['expiration', '${nowSec() + ttl.inSeconds}'],
      ],
    );
  }

  /// То же в отдельном потоке — криптография на чистом Dart занимает десятки
  /// миллисекунд и не должна подтормаживать интерфейс.
  static Future<Event> wrapAsync({
    required Keys sender,
    required String recipientPub,
    required String content,
    bool ephemeral = false,
    Duration ttl = const Duration(days: 7),
  }) => Isolate.run(
    () => wrap(
      sender: sender,
      recipientPub: recipientPub,
      content: content,
      ephemeral: ephemeral,
      ttl: ttl,
    ),
  );

  static Future<(String, Event)?> unwrapAsync(Keys me, Event e) => Isolate.run(() => unwrap(me, e));

  /// Открыть конверт. Возвращает (публичный ключ отправителя, rumor) или null,
  /// если что-то не сходится (подделка, чужое сообщение, мусор).
  static (String, Event)? unwrap(Keys me, Event wrap) {
    try {
      if (!wrap.verify()) return null;
      final sealJson = Nip44.decrypt(wrap.content, Nip44.conversationKey(me.priv, wrap.pubkey));
      final seal = Event.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
      if (seal.kind != kindSeal || !seal.verify()) return null;
      final rumorJson = Nip44.decrypt(seal.content, Nip44.conversationKey(me.priv, seal.pubkey));
      final rumor = Event.fromJson(jsonDecode(rumorJson) as Map<String, dynamic>);
      // Отправитель внутри должен совпадать с тем, кто подписал печать.
      if (rumor.pubkey != seal.pubkey || !rumor.idValid) return null;
      return (seal.pubkey, rumor);
    } catch (_) {
      return null;
    }
  }
}
