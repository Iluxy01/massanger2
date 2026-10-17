import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../utils.dart';
import 'effects.dart';
import 'visual.dart';

/// Общий список дел в пузыре: пункты отмечают все участники чата.
class TodoContent extends StatelessWidget {
  const TodoContent({
    super.key,
    required this.m,
    required this.chatId,
    required this.fg,
    required this.meta,
  });

  final Message m;
  final String chatId;
  final Color fg;
  final Widget meta;

  Future<void> _add(BuildContext context) async {
    final app = context.appRead;
    final vc = app.colors;
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text('Новый пункт', style: TextStyle(color: vc.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 200,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(color: vc.text),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Добавить')),
        ],
      ),
    );
    ctrl.dispose();
    if (text != null && text.trim().isNotEmpty) app.todoAdd(chatId, m, text);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final todo = m.todo!;
    final chat = app.contact(chatId);
    final group = chat?.isGroup ?? false;
    // Подписчик канала список только видит.
    final readOnly = chat != null && app.readOnly(chat);
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            todo.title,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16, height: 1.25),
          ),
          const SizedBox(height: 2),
          Text(
            'Список · готово ${todo.done} из ${todo.items.length}',
            style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          for (final it in todo.items)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: readOnly
                  ? null
                  : () {
                      app.tick(HapticKind.selection);
                      app.todoToggle(chatId, m, it.id);
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200).by(context),
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: it.done ? fg.withValues(alpha: 0.9) : Colors.transparent,
                        border: Border.all(color: fg.withValues(alpha: 0.7), width: 1.6),
                      ),
                      child: it.done
                          ? Icon(Icons.check_rounded, size: 15, color: _contrast(fg))
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            it.text,
                            style: TextStyle(
                              color: fg.withValues(alpha: it.done ? 0.55 : 1),
                              fontSize: 15,
                              decoration: it.done ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          // В группе — кто отметил.
                          if (group && it.done && it.by != null)
                            Text(
                              app.memberName(chatId, it.by!),
                              style: TextStyle(color: fg.withValues(alpha: 0.55), fontSize: 11.5),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Row(
            children: [
              if (todo.items.length < Todo.maxItems && !readOnly)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Пункт'),
                ),
              const Spacer(),
              meta,
            ],
          ),
        ],
      ),
    );
  }

  static Color _contrast(Color c) => c.computeLuminance() > 0.5 ? Colors.black : Colors.white;
}

/// Капсула времени у получателя: закрыта до назначенного момента; сама
/// откроется, когда время придёт (пузырь перерисуется).
class CapsuleSealed extends StatefulWidget {
  const CapsuleSealed({super.key, required this.m, required this.fg, required this.meta});

  final Message m;
  final Color fg;
  final Widget meta;

  @override
  State<CapsuleSealed> createState() => _CapsuleSealedState();
}

class _CapsuleSealedState extends State<CapsuleSealed> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _t?.cancel();
    final left = widget.m.openAt!.difference(DateTime.now());
    if (left.isNegative) return;
    // Раз в минуту обновляем «осталось», а в нужный момент — открываем.
    _t = Timer(left < const Duration(minutes: 1) ? left : const Duration(minutes: 1), () {
      if (!mounted) return;
      setState(() {});
      if (widget.m.sealed) {
        _arm();
      } else {
        context.appRead.notifyChanged();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.fg;
    final at = widget.m.openAt!;
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fg.withValues(alpha: 0.14)),
            child: const Center(child: Text('⏳', style: TextStyle(fontSize: 22))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Капсула времени',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14.5),
                ),
                const SizedBox(height: 2),
                Text(
                  'Откроется ${fmtWhen(at)} · ${fmtLeft(at)}',
                  style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12.5),
                ),
                Align(alignment: Alignment.centerRight, child: widget.meta),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// «15 мая, 10:00» / «сегодня в 21:00» / «завтра в 9:00».
String fmtWhen(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final time = fmtTime(t);
  if (diff == 0) return 'сегодня в $time';
  if (diff == 1) return 'завтра в $time';
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final year = t.year == now.year ? '' : ' ${t.year}';
  return '${t.day} ${months[t.month - 1]}$year, $time';
}

/// «через 3 дня» / «через 5 ч» / «через 12 мин».
String fmtLeft(DateTime t) {
  final d = t.difference(DateTime.now());
  if (d.inDays >= 1) return 'через ${d.inDays} дн.';
  if (d.inHours >= 1) return 'через ${d.inHours} ч';
  return 'через ${d.inMinutes + 1} мин';
}

/// Выбор момента: быстрые варианты и «своё время». null — передумали.
Future<DateTime?> pickWhen(BuildContext context, {required String title, bool far = false}) async {
  final app = context.appRead;
  final vc = app.colors;
  final now = DateTime.now();
  DateTime at(int days, int hour) => DateTime(now.year, now.month, now.day + days, hour);
  final presets = <(String, DateTime)>[
    if (!far) ('Через час', now.add(const Duration(hours: 1))),
    if (now.hour < 20) ('Сегодня в 21:00', at(0, 21)),
    ('Завтра в 9:00', at(1, 9)),
    if (far) ('Через неделю', now.add(const Duration(days: 7))),
    if (far) ('Через месяц', DateTime(now.year, now.month + 1, now.day, now.hour, now.minute)),
    if (far) ('Через год', DateTime(now.year + 1, now.month, now.day, now.hour, now.minute)),
  ];
  final picked = await showModalBottomSheet<Object>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 24,
          color: vc.elevated,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final (label, at) in presets)
                ListTile(
                  title: Text(label, style: TextStyle(color: vc.text)),
                  subtitle: Text(fmtWhen(at), style: TextStyle(color: vc.textDim, fontSize: 12.5)),
                  onTap: () => Navigator.pop(ctx, at),
                ),
              ListTile(
                leading: const GradientIcon(Icons.edit_calendar_rounded, size: 22),
                title: Text('Выбрать дату и время', style: TextStyle(color: vc.text)),
                onTap: () => Navigator.pop(ctx, 'custom'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (picked is DateTime) return picked;
  if (picked != 'custom' || !context.mounted) return null;
  final date = await showDatePicker(
    context: context,
    initialDate: now.add(const Duration(days: 1)),
    firstDate: now,
    lastDate: DateTime(now.year + 10),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
  );
  if (time == null) return null;
  final when = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  return when.isAfter(DateTime.now()) ? when : null;
}
