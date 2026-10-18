import 'package:flutter_test/flutter_test.dart';
import 'package:veil/core/bip39_words.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/recovery.dart';

/// Ключ восстановления: 24 слова BIP39 и nsec (NIP-19).
void main() {
  test('официальные примеры BIP39 (256 бит)', () {
    String w(String hex) => Recovery.toWords(hex).join(' ');
    expect(w('00' * 32), '${'abandon ' * 23}art');
    expect(
      w('7f' * 32),
      'legal winner thank year wave sausage worth useful legal winner thank year wave '
      'sausage worth useful legal winner thank year wave sausage worth title',
    );
    expect(
      w('80' * 32),
      'letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd '
      'amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless',
    );
    expect(w('ff' * 32), '${'zoo ' * 23}vote');
    expect(bip39Words, hasLength(2048));
  });

  test('ключ ↔ слова туда и обратно; опечатки и лишнее', () {
    for (var i = 0; i < 20; i++) {
      final k = Keys.generate();
      final words = Recovery.toWords(k.priv);
      expect(words, hasLength(24));
      expect(Recovery.fromWords(words), k.priv);
      // Как люди записывают: с номерами, запятыми, заглавными, по 4 буквы.
      final messy = [
        for (var j = 0; j < words.length; j++)
          '${j + 1}. ${j.isEven ? words[j].toUpperCase() : words[j].substring(0, words[j].length.clamp(0, 4))},',
      ].join('\n');
      expect(Recovery.parse(messy), k.priv);
    }
    final words = Recovery.toWords(Keys.generate().priv);
    // Переставили два слова — сумма не сходится.
    final swapped = [...words]
      ..[0] = words[1]
      ..[1] = words[0];
    if (words[0] != words[1]) {
      expect(() => Recovery.fromWords(swapped), throwsA(isA<RecoveryError>()));
    }
    expect(
      () => Recovery.fromWords(words.take(23).toList()),
      throwsA(predicate((e) => '$e'.contains('24'))),
    );
    expect(
      () => Recovery.fromWords([...words.take(23), 'котик']),
      throwsA(predicate((e) => '$e'.contains('№24'))),
    );
    // Нулевой ключ — не ключ аккаунта.
    expect(() => Recovery.fromWords(Recovery.toWords('00' * 32)), throwsA(isA<RecoveryError>()));
    expect(Recovery.suggest('aban'), ['abandon']);
    expect(Recovery.wordIndex('zoo'), 2047);
  });

  test('nsec из NIP-19', () {
    const nsec = 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
    const hex = '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
    expect(Recovery.toNsec(hex), nsec);
    expect(Recovery.fromNsec(nsec), hex);
    expect(Recovery.parse('  ${nsec.toUpperCase()} '), hex);
    expect(
      () => Recovery.fromNsec('${nsec.substring(0, 20)}x${nsec.substring(21)}'),
      throwsA(isA<RecoveryError>()),
    );
    expect(() => Recovery.parse('nsec1abc'), throwsA(isA<RecoveryError>()));
  });
}
