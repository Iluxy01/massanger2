import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app.dart';
import '../core/biometric.dart';
import '../core/bip39_words.dart';
import '../core/recovery.dart';
import '../core/transfer.dart';
import '../state/app_state.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';
import 'lock_screen.dart';

// ───────────────────────────── Ключ восстановления ─────────────────────────────

/// 24 слова в две колонки, с номерами.
class RecoveryWordsGrid extends StatelessWidget {
  const RecoveryWordsGrid({super.key, required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final half = (words.length + 1) ~/ 2;
    Widget cell(int i) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${i + 1}',
              textAlign: TextAlign.right,
              style: TextStyle(color: vc.textFaint, fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              words[i],
              style: TextStyle(
                color: vc.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
    return Glass(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Column(children: [for (var i = 0; i < half; i++) cell(i)])),
          Expanded(child: Column(children: [for (var i = half; i < words.length; i++) cell(i)])),
        ],
      ),
    );
  }
}

/// Проверка, что слова записаны: угадать три слова по номерам.
class RecoveryCheck extends StatefulWidget {
  const RecoveryCheck({super.key, required this.words, required this.onPassed});

  final List<String> words;
  final VoidCallback onPassed;

  @override
  State<RecoveryCheck> createState() => _RecoveryCheckState();
}

class _RecoveryCheckState extends State<RecoveryCheck> {
  final _rnd = Random.secure();
  late final List<int> _asked;
  late final Map<int, List<String>> _options;
  final _answered = <int>{};
  int? _wrong;

  @override
  void initState() {
    super.initState();
    final all = List.generate(widget.words.length, (i) => i)..shuffle(_rnd);
    _asked = all.take(3).toList()..sort();
    _options = {
      for (final i in _asked)
        i: ({
          widget.words[i],
          for (var k = 0; k < 12; k++) bip39Words[_rnd.nextInt(bip39Words.length)],
        }.take(4).toList()..shuffle(_rnd)),
    };
  }

  void _pick(int i, String w) {
    final app = context.appRead;
    if (w == widget.words[i]) {
      app.tick(HapticKind.light);
      setState(() {
        _answered.add(i);
        _wrong = null;
      });
      if (_answered.length == _asked.length) widget.onPassed();
    } else {
      app.tick(HapticKind.heavy);
      setState(() => _wrong = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final i in _asked) ...[
          Text(
            'Слово №${i + 1}',
            style: TextStyle(color: vc.text, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in _options[i]!)
                Pressable(
                  key: ValueKey('check-$i-$w'),
                  onTap: _answered.contains(i) ? null : () => _pick(i, w),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200).by(context),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: _answered.contains(i) && w == widget.words[i] ? acc.gradient : null,
                      color: _answered.contains(i) && w == widget.words[i] ? null : vc.surface,
                      borderRadius: BorderRadius.circular(14 * context.skin.radius),
                      border: Border.all(color: vc.border),
                    ),
                    child: Text(
                      w,
                      style: TextStyle(
                        color: _answered.contains(i) && w == widget.words[i]
                            ? acc.onAccent
                            : vc.text,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_wrong == i)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Не то слово — загляни в записанное',
                style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13),
              ),
            ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

/// Спросить PIN (или отпечаток) перед тем, как показать секрет. true — можно.
Future<bool> confirmOwner(BuildContext context, String reason) async {
  final app = context.appRead;
  if (!app.hasPin) return true;
  if (app.biometric && await Biometric.check(reason)) return true;
  if (!context.mounted) return false;
  final ok = await Navigator.of(
    context,
  ).push(LockScreen.verifyRoute(title: 'Введи PIN', subtitle: reason, verify: app.checkPin));
  return ok == true;
}

/// Профиль → «Ключ восстановления»: показать 24 слова и проверить, что записаны.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key});

  static Future<void> open(BuildContext context) async {
    if (!await confirmOwner(context, 'Чтобы показать ключ восстановления')) return;
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const RecoveryKeyScreen()));
  }

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  List<String>? _words;
  String? _nsec;
  bool _checking = false;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.appRead;
    // Пока слова на экране — без скриншотов и превью в недавних.
    _app.secureScreen(true);
    _app.recoveryWords().then((w) {
      if (mounted) setState(() => _words = w);
    });
  }

  @override
  void dispose() {
    _app.secureScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final words = _words;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Ключ восстановления'),
      ),
      body: words == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                Text(
                  _checking
                      ? 'Проверим, что всё записано верно.'
                      : 'Эти 24 слова — твой аккаунт. С ними можно войти в Veil на любом '
                            'телефоне, даже если этот потерян. Запиши их на бумагу и храни '
                            'там, где никто не увидит. Не фотографируй и не отправляй никому — '
                            'мы их никогда не спросим.',
                  style: TextStyle(color: vc.textDim, fontSize: 14.5, height: 1.45),
                ),
                const SizedBox(height: 18),
                if (_checking)
                  RecoveryCheck(
                    words: words,
                    onPassed: () {
                      _app.markRecoverySaved();
                      showVeilToast(
                        context,
                        'Ключ записан — отлично',
                        icon: Icons.verified_rounded,
                      );
                      Navigator.of(context).pop();
                    },
                  )
                else ...[
                  RecoveryWordsGrid(words: words),
                  const SizedBox(height: 22),
                  AccentButton(
                    label: 'Я записал(а) — проверить',
                    icon: Icons.task_alt_rounded,
                    onTap: () => setState(() => _checking = true),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      final priv = Recovery.parse(words.join(' '));
                      setState(() => _nsec = _nsec == null ? Recovery.toNsec(priv) : null);
                    },
                    child: Text(
                      _nsec == null
                          ? 'Показать как nsec (для других приложений Nostr)'
                          : 'Скрыть nsec',
                      style: TextStyle(color: vc.textFaint, fontSize: 13),
                    ),
                  ),
                  if (_nsec != null)
                    SelectableText(
                      _nsec!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: vc.textDim, fontFamily: 'monospace', fontSize: 13),
                    ),
                ],
              ],
            ),
    );
  }
}

// ───────────────────────────── Вход по ключу ─────────────────────────────

/// Новый телефон: ввести 24 слова (или nsec). Возвращает секретный ключ.
class KeyLoginScreen extends StatefulWidget {
  const KeyLoginScreen({super.key});

  static Route<String> route() => MaterialPageRoute(builder: (_) => const KeyLoginScreen());

  @override
  State<KeyLoginScreen> createState() => _KeyLoginScreenState();
}

class _KeyLoginScreenState extends State<KeyLoginScreen> {
  final _text = TextEditingController();
  String? _error;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.appRead;
    _app.secureScreen(true);
  }

  @override
  void dispose() {
    _app.secureScreen(false);
    _text.dispose();
    super.dispose();
  }

  int get _count {
    final t = _text.text.trim();
    if (t.isEmpty || t.toLowerCase().startsWith('nsec')) return 0;
    return t.split(RegExp(r'[\s,;.]+')).where((w) => RegExp(r'^[a-zA-Z]+$').hasMatch(w)).length;
  }

  void _go() {
    try {
      final priv = Recovery.parse(_text.text);
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop(priv);
    } on RecoveryError catch (e) {
      _app.tick(HapticKind.heavy);
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final nsec = _text.text.trim().toLowerCase().startsWith('nsec');
    final n = _count;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Вход по ключу'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Введи 24 слова ключа восстановления — через пробел, в том порядке, как '
            'записаны. Достаточно первых четырёх букв каждого слова. Можно вставить и '
            'ключ nsec1… из другого приложения Nostr.',
            style: TextStyle(color: vc.textDim, fontSize: 14.5, height: 1.45),
          ),
          const SizedBox(height: 16),
          Glass(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              key: const ValueKey('recovery-input'),
              controller: _text,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              style: TextStyle(color: vc.text, fontFamily: 'monospace', fontSize: 15, height: 1.5),
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'слово слово слово …',
                hintStyle: TextStyle(color: vc.textFaint),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                nsec ? 'Ключ nsec' : 'Слов: $n из ${Recovery.wordCount}',
                style: TextStyle(color: vc.textFaint, fontSize: 13),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text == null || !mounted) return;
                  setState(() {
                    _text.text = d!.text!.trim();
                    _error = null;
                  });
                },
                icon: Icon(Icons.content_paste_rounded, size: 18, color: vc.textDim),
                label: Text('Вставить', style: TextStyle(color: vc.textDim)),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                _error!,
                style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13.5),
              ),
            ),
          const SizedBox(height: 18),
          AccentButton(
            label: 'Дальше',
            icon: Icons.arrow_forward_rounded,
            onTap: nsec || n >= Recovery.wordCount ? _go : null,
          ),
          const SizedBox(height: 16),
          Text(
            'По ключу вернётся сам аккаунт: друзья смогут писать тебе как раньше, а '
            'то, что они написали за последний месяц, придёт заявками. Прежняя '
            'переписка хранилась только на старом телефоне — её переносит резервная '
            'копия или перенос с телефона на телефон.',
            style: TextStyle(color: vc.textFaint, fontSize: 12.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Перенос: старый телефон ─────────────────────────────

/// Профиль → «Перенести на новый телефон»: показать QR-код.
class MoveOutScreen extends StatefulWidget {
  const MoveOutScreen({super.key});

  static Future<void> open(BuildContext context) async {
    final app = context.appRead;
    if (app.demo) {
      showVeilToast(context, 'В демо-версии перенос недоступен', icon: Icons.phonelink_rounded);
      return;
    }
    if (!await confirmOwner(context, 'Чтобы перенести аккаунт')) return;
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const MoveOutScreen()));
  }

  @override
  State<MoveOutScreen> createState() => _MoveOutScreenState();
}

class _MoveOutScreenState extends State<MoveOutScreen> {
  final _progress = ValueNotifier<double>(0);
  TransferTicket? _ticket;
  bool _busy = false;
  String? _error;
  late final AppState _app;
  bool _secured = false;

  @override
  void initState() {
    super.initState();
    _app = context.appRead;
  }

  @override
  void dispose() {
    // Ушли с экрана — код больше не нужен: просим ретрансляторы убрать пакет.
    if (_ticket != null) _app.finishTransfer();
    if (_secured) _app.secureScreen(false);
    _progress.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress.value = 0;
    });
    try {
      final t = await _app.prepareTransfer(progress: _progress);
      if (!mounted) return;
      _app.secureScreen(true);
      _secured = true;
      setState(() {
        _ticket = t;
        _busy = false;
      });
    } on TransferError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не получилось: $e';
        });
      }
    }
  }

  Future<void> _done() async {
    final vc = context.vc;
    final wipe = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text('Аккаунт перенесён?', style: TextStyle(color: vc.text)),
        content: Text(
          'Если на новом телефоне всё на месте, Veil на этом лучше стереть: с одним '
          'аккаунтом на двух телефонах переписка начнёт расходиться.',
          style: TextStyle(color: vc.textDim, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Оставить', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Стереть здесь')),
        ],
      ),
    );
    if (!mounted) return;
    if (wipe == true) {
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      await _app.wipeEverything();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final ticket = _ticket;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Перенос на новый телефон'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (ticket == null) ...[
            const Center(child: GradientIcon(Icons.phonelink_ring_rounded, size: 64)),
            const SizedBox(height: 18),
            _Steps(
              steps: const [
                'Установи Veil на новый телефон',
                'Там нажми «У меня уже есть аккаунт» → «С другого телефона»',
                'Наведи камеру на код, который появится здесь',
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Перенесутся друзья, группы, каналы, переписка и настройки — зашифрованно, '
              'через те же ретрансляторы. Фото и файлы останутся здесь: для них — '
              'резервная копия в файл.',
              style: TextStyle(color: vc.textDim, fontSize: 14, height: 1.45),
            ),
            const SizedBox(height: 24),
            if (_busy)
              ValueListenableBuilder<double>(
                valueListenable: _progress,
                builder: (_, v, _) => Column(
                  children: [
                    LinearProgressIndicator(value: v > 0 ? v : null, minHeight: 6),
                    const SizedBox(height: 10),
                    Text('Готовлю данные…', style: TextStyle(color: vc.textDim)),
                  ],
                ),
              )
            else
              AccentButton(label: 'Показать код', icon: Icons.qr_code_2_rounded, onTap: _prepare),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.redAccent.shade100, height: 1.4),
                ),
              ),
          ] else ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: SizedBox(
                  width: 260,
                  height: 260,
                  child: QrImageView(
                    data: ticket.encode(),
                    padding: EdgeInsets.zero,
                    gapless: true,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber.shade300, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Этот код — ключ от твоего аккаунта. Показывай его только своему новому '
                    'телефону. Код действует, пока открыт этот экран.',
                    style: TextStyle(color: vc.textDim, fontSize: 14, height: 1.45),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AccentButton(label: 'Новый телефон вошёл', icon: Icons.check_rounded, onTap: _done),
          ],
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(gradient: acc.gradient, shape: BoxShape.circle),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(color: acc.onAccent, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      steps[i],
                      style: TextStyle(color: vc.text, fontSize: 15, height: 1.35),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ───────────────────────────── Перенос: новый телефон ─────────────────────────────

/// Новый телефон: отсканировать код со старого и забрать всё. true — вошли.
class MoveInScreen extends StatefulWidget {
  const MoveInScreen({super.key});

  static Route<bool> route() => MaterialPageRoute(builder: (_) => const MoveInScreen());

  @override
  State<MoveInScreen> createState() => _MoveInScreenState();
}

class _MoveInScreenState extends State<MoveInScreen> {
  final _progress = ValueNotifier<double>(0);
  bool _busy = false;
  bool _cameraFailed = false;
  String? _error;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_busy) return;
    for (final b in capture.barcodes) {
      final t = TransferTicket.parse(b.rawValue ?? '');
      if (t != null) {
        _receive(t);
        return;
      }
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final t = TransferTicket.parse(d?.text ?? '');
    if (t == null) {
      showVeilToast(context, 'В буфере нет кода переноса', icon: Icons.content_paste_off_rounded);
      return;
    }
    await _receive(t);
  }

  Future<void> _receive(TransferTicket t) async {
    final app = context.appRead;
    app.tick(HapticKind.medium);
    setState(() {
      _busy = true;
      _error = null;
      _progress.value = 0;
    });
    try {
      await app.receiveTransfer(t, progress: _progress);
      if (mounted) Navigator.of(context).pop(true);
    } on TransferError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не получилось: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('С другого телефона'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            'На старом телефоне открой Профиль → «Перенести на новый телефон» → '
            '«Показать код» и наведи на него камеру.',
            style: TextStyle(color: vc.textDim, fontSize: 14.5, height: 1.45),
          ),
          const SizedBox(height: 18),
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: ColoredBox(
                color: const Color(0xFF0B0B10),
                child: _busy
                    ? ValueListenableBuilder<double>(
                        valueListenable: _progress,
                        builder: (_, v, _) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 72,
                                height: 72,
                                child: CircularProgressIndicator(
                                  value: v > 0 ? v : null,
                                  strokeWidth: 5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                v > 0 ? 'Переношу… ${(v * 100).round()}%' : 'Подключаюсь…',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      )
                    : context.app.demo || _cameraFailed
                    ? Center(
                        child: Icon(
                          Icons.no_photography_outlined,
                          size: 56,
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      )
                    : MobileScanner(
                        onDetect: _detected,
                        errorBuilder: (context, error) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() => _cameraFailed = true);
                          });
                          return const SizedBox();
                        },
                      ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.redAccent.shade100, height: 1.4),
              ),
            ),
          const SizedBox(height: 18),
          if (!_busy)
            TextButton.icon(
              onPressed: _paste,
              icon: Icon(Icons.content_paste_rounded, color: vc.textDim, size: 18),
              label: Text('Вставить код', style: TextStyle(color: vc.textDim)),
            ),
        ],
      ),
    );
  }
}
