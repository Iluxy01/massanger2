import 'dart:convert';

import 'crypto_worker.dart';
import 'nip44.dart';
import 'nostr.dart';

/// Тройной конверт NIP-59 (как в NIP-17):
///
///   rumor (не подписан, наш JSON внутри)
///     → seal (kind 13, подписан отправителем, зашифрован для получателя)
///       → gift wrap (kind 1059, подписан СЛУЧАЙНЫМ одноразовым ключом)
///
/// Ретранслятор видит только одноразовый ключ, получателя и шифротекст —
/// ни отправителя, ни содержимого.
///
/// Время конверта — настоящее (без «размытия» на 2 суток назад, как в NIP-59):
/// ретранслятор и так видит момент получения, а размытие заставляло при каждом
/// переподключении заново скачивать конверты за двое суток — лишний трафик и нагрев.
class GiftWrap {
  static const kindRumor = 14;
  static const kindSeal = 13;
  static const kindWrap = 1059;

  /// Эфемерный вариант (печатает…, «в сети») — ретрансляторы его не хранят.
  static const kindWrapEphemeral = 21059;

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
      createdAt: nowSec(),
      content: Nip44.encrypt(
        jsonEncode(rumor.toJson()),
        // Ключ беседы с другом постоянный — кэшируем.
        Nip44.conversationKey(sender.priv, recipientPub, cache: true),
      ),
    );
    final oneTime = Keys.generate();
    return Event.signed(
      oneTime,
      kind: ephemeral ? kindWrapEphemeral : kindWrap,
      createdAt: nowSec(),
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

  /// То же в постоянном фоновом потоке (см. [CryptoWorker]) — криптография на
  /// чистом Dart занимает десятки миллисекунд и не должна тормозить интерфейс.
  static Future<Event> wrapAsync({
    required Keys sender,
    required String recipientPub,
    required String content,
    bool ephemeral = false,
    Duration ttl = const Duration(days: 7),
  }) => CryptoWorker.shared.wrap(
    sender: sender,
    recipientPub: recipientPub,
    content: content,
    ephemeral: ephemeral,
    ttl: ttl,
  );

  static Future<(String, Event)?> unwrapAsync(Keys me, Event e) =>
      CryptoWorker.shared.unwrap(me, e);

  /// Открыть конверт. Возвращает (публичный ключ отправителя, rumor) или null,
  /// если что-то не сходится (подделка, чужое сообщение, мусор).
  static (String, Event)? unwrap(Keys me, Event wrap) {
    try {
      // Подпись внешнего конверта не проверяем: её ставит одноразовый ключ и она
      // ничего не доказывает, а целостность гарантирует MAC шифра NIP-44.
      // Проверяем только, что id соответствует содержимому (по нему — дедупликация).
      if (!wrap.idValid) return null;
      final sealJson = Nip44.decrypt(wrap.content, Nip44.conversationKey(me.priv, wrap.pubkey));
      final seal = Event.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
      if (seal.kind != kindSeal || !seal.verify()) return null;
      final rumorJson = Nip44.decrypt(
        seal.content,
        Nip44.conversationKey(me.priv, seal.pubkey, cache: true),
      );
      final rumor = Event.fromJson(jsonDecode(rumorJson) as Map<String, dynamic>);
      // Отправитель внутри должен совпадать с тем, кто подписал печать.
      if (rumor.pubkey != seal.pubkey || !rumor.idValid) return null;
      return (seal.pubkey, rumor);
    } catch (_) {
      return null;
    }
  }
}
