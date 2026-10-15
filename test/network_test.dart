@Tags(['network'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil/core/giftwrap.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/relay_pool.dart';

/// Проверка настоящих публичных ретрансляторов. Запускается только в CI:
///   VEIL_NETWORK_TEST=1 flutter test test/network_test.dart
/// Кандидаты на замену — проверяются и печатаются, но на результат теста не влияют.
const candidateRelays = [
  'wss://relay.damus.io',
  'wss://relay.nos.social',
  'wss://relay.mostr.pub',
  'wss://relay.0xchat.com',
  'wss://relay.nostr.net',
  'wss://nostr.wine',
  'wss://relay.nostr.band',
  'wss://nostr21.com',
  'wss://relay.nostrplebs.com',
  'wss://nostr.einundzwanzig.space',
  'wss://relay.fountain.fm',
  'wss://nostr.lu.ke',
  'wss://relay.coinos.io',
  'wss://relay.nostr.bg',
];

void main() {
  final enabled = Platform.environment['VEIL_NETWORK_TEST'] == '1';

  test(
    'публичные ретрансляторы принимают и доставляют конверты',
    () async {
      final alice = Keys.generate();
      final bob = Keys.generate();
      var working = 0;

      for (final url in [...defaultRelays, ...candidateRelays]) {
        final pool = RelayPool([url]);
        final got = <int>{};
        final sub = pool.events.listen((e) {
          final opened = GiftWrap.unwrap(bob, e);
          if (opened != null && opened.$1 == alice.pub) got.add(e.kind);
        });
        pool.subscribe(
          () => [
            {
              'kinds': [GiftWrap.kindWrap, GiftWrap.kindWrapEphemeral],
              '#p': [bob.pub],
              'since': nowSec() - 3600,
            },
          ],
        );
        pool.start();
        await pool.waitEose(const Duration(seconds: 15));

        final stored = await pool.publish(
          GiftWrap.wrap(sender: alice, recipientPub: bob.pub, content: '{"t":"msg"}'),
        );
        await pool.publish(
          GiftWrap.wrap(
            sender: alice,
            recipientPub: bob.pub,
            content: '{"t":"typ"}',
            ephemeral: true,
          ),
          timeout: const Duration(seconds: 3),
        );
        for (var i = 0; i < 40 && got.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final ok = stored && got.contains(GiftWrap.kindWrap);
        if (ok && defaultRelays.contains(url)) working++;
        // ignore: avoid_print
        print(
          '${ok ? '✅' : '❌'} $url  принят=$stored  доставлен=${got.contains(1059)}  '
          'эфемерный=${got.contains(21059)}  ${pool.errorOf(url) ?? ''}',
        );
        await sub.cancel();
        await pool.close();
      }
      // ignore: avoid_print
      print('Работает ретрансляторов: $working из ${defaultRelays.length}');
      expect(working, greaterThan(0));
    },
    skip: enabled ? false : 'нужен интернет (VEIL_NETWORK_TEST=1)',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
