import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

/// Вход по отпечатку пальца или лицу (системный диалог Android).
/// PIN-код при этом остаётся: биометрия — лишь быстрый способ его не вводить.
class Biometric {
  Biometric._();

  static final _auth = LocalAuthentication();
  static bool _busy = false;

  /// Есть ли на телефоне настроенный отпечаток или лицо.
  static Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Спросить отпечаток / лицо. false — отменили, не узнали или недоступно.
  static Future<bool> check(String reason) async {
    if (_busy) return false;
    _busy = true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        // Лицо — без лишнего «подтвердить» после распознавания.
        sensitiveTransaction: false,
        authMessages: const [
          AndroidAuthMessages(signInTitle: 'Вход в Veil', cancelButton: 'Ввести PIN'),
        ],
      );
    } catch (_) {
      return false;
    } finally {
      _busy = false;
    }
  }
}
