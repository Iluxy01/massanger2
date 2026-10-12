import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'nostr.dart';

/// Шифрование NIP-44 v2: ECDH(secp256k1) → HKDF → ChaCha20 + HMAC-SHA256.
/// Спецификация: https://github.com/nostr-protocol/nips/blob/master/44.md
class Nip44 {
  static final _curve = ECDomainParameters('secp256k1');
  static final _p = BigInt.parse(
    'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
    radix: 16,
  );
  static final _salt = utf8.encode('nip44-v2');

  /// Общий ключ беседы. Одинаков для (мой приватный, его публичный) и наоборот.
  static Uint8List conversationKey(String privHex, String pubHex) {
    final d = BigInt.parse(privHex, radix: 16);
    final x = BigInt.parse(pubHex, radix: 16);
    if (x >= _p) throw ArgumentError('bad pubkey');
    final ySq = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
    var y = ySq.modPow((_p + BigInt.one) ~/ BigInt.from(4), _p);
    if (y.modPow(BigInt.two, _p) != ySq) throw ArgumentError('bad pubkey');
    if (y.isOdd) y = _p - y;
    final point = _curve.curve.createPoint(x, y);
    final shared = (point * d)!;
    final sx = _bytes32(shared.x!.toBigInteger()!);
    return Uint8List.fromList(Hmac(sha256, _salt).convert(sx).bytes);
  }

  static Uint8List _bytes32(BigInt v) => hexDecode(v.toRadixString(16).padLeft(64, '0'));

  /// HKDF-Expand(prk, info, 76) → chacha_key, chacha_nonce, hmac_key.
  static (Uint8List, Uint8List, Uint8List) messageKeys(Uint8List convKey, Uint8List nonce) {
    if (convKey.length != 32 || nonce.length != 32) throw ArgumentError('bad key/nonce');
    final out = <int>[];
    var prev = <int>[];
    for (var i = 1; out.length < 76; i++) {
      prev = Hmac(sha256, convKey).convert([...prev, ...nonce, i]).bytes;
      out.addAll(prev);
    }
    return (
      Uint8List.fromList(out.sublist(0, 32)),
      Uint8List.fromList(out.sublist(32, 44)),
      Uint8List.fromList(out.sublist(44, 76)),
    );
  }

  static int calcPaddedLen(int len) {
    if (len < 1) throw ArgumentError('empty');
    if (len <= 32) return 32;
    final nextPower = 1 << ((log(len - 1) / ln2).floor() + 1);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * (((len - 1) ~/ chunk) + 1);
  }

  static Uint8List _pad(String plaintext) {
    final bytes = utf8.encode(plaintext);
    if (bytes.isEmpty || bytes.length > 65535) throw ArgumentError('bad length');
    final out = Uint8List(2 + calcPaddedLen(bytes.length));
    out[0] = bytes.length >> 8;
    out[1] = bytes.length & 0xff;
    out.setRange(2, 2 + bytes.length, bytes);
    return out;
  }

  static String _unpad(Uint8List padded) {
    final len = (padded[0] << 8) | padded[1];
    if (len == 0 || padded.length != 2 + calcPaddedLen(len)) throw const FormatException('padding');
    return utf8.decode(padded.sublist(2, 2 + len));
  }

  static Uint8List _chacha(Uint8List key, Uint8List nonce, Uint8List data) {
    final c = ChaCha7539Engine()..init(true, ParametersWithIV(KeyParameter(key), nonce));
    final out = Uint8List(data.length);
    c.processBytes(data, 0, data.length, out, 0);
    return out;
  }

  static String encrypt(String plaintext, Uint8List convKey, {Uint8List? nonce}) {
    final n = nonce ?? randomBytes(32);
    final (ck, cn, hk) = messageKeys(convKey, n);
    final ct = _chacha(ck, cn, _pad(plaintext));
    final mac = Hmac(sha256, hk).convert([...n, ...ct]).bytes;
    return base64.encode([2, ...n, ...ct, ...mac]);
  }

  static String decrypt(String payload, Uint8List convKey) {
    if (payload.isEmpty || payload.startsWith('#')) throw const FormatException('version');
    if (payload.length < 132 || payload.length > 87472) throw const FormatException('size');
    final data = base64.decode(payload);
    if (data.length < 99 || data.length > 65603) throw const FormatException('size');
    if (data[0] != 2) throw const FormatException('version');
    final n = Uint8List.fromList(data.sublist(1, 33));
    final ct = Uint8List.fromList(data.sublist(33, data.length - 32));
    final mac = data.sublist(data.length - 32);
    final (ck, cn, hk) = messageKeys(convKey, n);
    final expected = Hmac(sha256, hk).convert([...n, ...ct]).bytes;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= expected[i] ^ mac[i];
    }
    if (diff != 0) throw const FormatException('mac');
    return _unpad(_chacha(ck, cn, ct));
  }
}
