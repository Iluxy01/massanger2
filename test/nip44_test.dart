import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil/core/nip44.dart';
import 'package:veil/core/nostr.dart';

/// Официальные тестовые векторы NIP-44 (github.com/paulmillr/nip44).
void main() {
  final v = jsonDecode(File('test/fixtures/nip44.vectors.json').readAsStringSync())['v2'];

  test('conversation key', () {
    for (final t in v['valid']['get_conversation_key']) {
      final k = Nip44.conversationKey(t['sec1'], t['pub2']);
      expect(hexEncode(k), t['conversation_key']);
    }
  });

  test('message keys', () {
    final ck = hexDecode(v['valid']['get_message_keys']['conversation_key']);
    for (final t in v['valid']['get_message_keys']['keys']) {
      final (a, b, c) = Nip44.messageKeys(ck, hexDecode(t['nonce']));
      expect(hexEncode(a), t['chacha_key']);
      expect(hexEncode(b), t['chacha_nonce']);
      expect(hexEncode(c), t['hmac_key']);
    }
  });

  test('padding', () {
    for (final t in v['valid']['calc_padded_len']) {
      expect(Nip44.calcPaddedLen(t[0]), t[1]);
    }
  });

  test('encrypt/decrypt', () {
    for (final t in v['valid']['encrypt_decrypt']) {
      final ck = Nip44.conversationKey(t['sec1'], Keys(t['sec2']).pub);
      expect(hexEncode(ck), t['conversation_key']);
      final payload = Nip44.encrypt(t['plaintext'], ck, nonce: hexDecode(t['nonce']));
      expect(payload, t['payload']);
      expect(Nip44.decrypt(payload, ck), t['plaintext']);
    }
  });

  test('invalid decrypt', () {
    for (final t in v['invalid']['decrypt']) {
      expect(
        () => Nip44.decrypt(t['payload'], hexDecode(t['conversation_key'])),
        throwsA(anything),
        reason: t['note'],
      );
    }
  });

  test('signed event verifies', () {
    final k = Keys.generate();
    final e = Event.signed(
      k,
      kind: 1,
      content: 'привет',
      tags: [
        ['p', k.pub],
      ],
    );
    expect(e.verify(), isTrue);
    final copy = Event.fromJson(jsonDecode(jsonEncode(e.toJson())));
    expect(copy.verify(), isTrue);
    // Портим последний байт подписи (гарантированно другим значением).
    final last = copy.sig.substring(126);
    copy.sig = '${copy.sig.substring(0, 126)}${last == '00' ? '01' : '00'}';
    expect(copy.verify(), isFalse);
  });
}
