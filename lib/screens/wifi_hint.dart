import 'package:flutter/material.dart';

import '../core/media_tools.dart';
import '../state/app_state.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';

/// При первой отправке файла (фото, голосовое, видео…) с Wi-Fi — подсказка
/// отправлять через мобильный интернет. Показывается один раз.
/// true — продолжать отправку, false — пользователь передумал.
Future<bool> wifiHint(BuildContext context) async {
  final app = context.appRead;
  if (app.demo || app.wifiHintShown) return true;
  if (!await onWifi() || !context.mounted) return true;
  app.markWifiHintShown();
  return await showWifiHintSheet(context) ?? false;
}

/// Сам лист подсказки (true — отправить, false/null — передумали).
Future<bool?> showWifiHintSheet(BuildContext context) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => const _WifiHintSheet(),
);

class _WifiHintSheet extends StatefulWidget {
  const _WifiHintSheet();

  @override
  State<_WifiHintSheet> createState() => _WifiHintSheetState();
}

class _WifiHintSheetState extends State<_WifiHintSheet> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    final body = TextStyle(color: vc.textDim, fontSize: 14, height: 1.4);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 28,
          color: vc.elevated,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const GradientIcon(Icons.signal_cellular_alt_rounded, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Отправь через мобильный интернет',
                          style: TextStyle(
                            color: vc.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Сейчас ты на Wi-Fi. Если друг на мобильном интернете, фото, голосовые '
                    'и видео с Wi-Fi могут до него не дойти — придёт только превью. '
                    'Выключи Wi-Fi на время отправки, и файл дойдёт.',
                    style: body,
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250).by(context),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _more
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: vc.surface,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                'Почему так. У Veil нет своего сервера: сообщения и файлы идут '
                                'через открытые серверы-ретрансляторы, и почти все они за '
                                'границей.\n\n'
                                'Мобильные операторы в России ограничивают соединения с '
                                'зарубежными серверами: по одному соединению проходит '
                                'примерно 16 КБ, дальше оно «замирает». Текст и превью '
                                'маленькие и проходят, а файл передаётся кусками по ~60 КБ — '
                                'такой кусок до телефона на мобильном интернете не доходит.\n\n'
                                'Когда оба телефона в одной сети, файлы доходят. Если файл '
                                'всё же застрял — пусть друг ненадолго включит Wi-Fi: '
                                'загрузка продолжится сама.',
                                style: body.copyWith(fontSize: 13.5),
                              ),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: 16),
                  AccentButton(
                    label: 'Понятно, отправить',
                    icon: Icons.send_rounded,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => setState(() => _more = !_more),
                          child: Text(
                            _more ? 'Скрыть' : 'Подробнее',
                            style: TextStyle(color: acc.mid, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text(
                            'Переключусь',
                            style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
