import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/effects.dart';
import '../widgets/wallpaper.dart';
import 'chat_screen.dart';

/// Оформление отдельного чата: фон и цвет. Видно только тебе; меняется сразу.
class ChatLookScreen extends StatefulWidget {
  const ChatLookScreen({super.key, required this.contact});

  final Contact contact;

  static Route<void> route(Contact c) =>
      MaterialPageRoute(builder: (_) => ChatLookScreen(contact: c));

  @override
  State<ChatLookScreen> createState() => _ChatLookScreenState();
}

class _ChatLookScreenState extends State<ChatLookScreen> {
  /// Затемнение, пока тянут ползунок (сохраняется, когда отпустят).
  int? _dim;

  /// Свежий экземпляр: после возврата в приложение контакты перечитываются.
  Contact get c => context.appRead.contact(widget.contact.id) ?? widget.contact;

  Future<void> _photo() async {
    final app = context.appRead;
    XFile? f;
    try {
      f = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 85,
      );
    } catch (_) {
      if (mounted) showVeilToast(context, 'Нет доступа к фото', icon: Icons.no_photography_rounded);
      return;
    }
    if (f == null) return;
    await app.setChatWallpaperPhoto(c, f.path);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final wp = c.wallpaper;
    final own = c.chatAccent;
    final accent = own == null ? null : chatAccents[own.clamp(0, chatAccents.length - 1)];
    final photo = wp != null && wp.startsWith('f:');
    final dim = _dim ?? c.wallpaperDim;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Оформление чата'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // Живой пример: как будет выглядеть переписка.
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: 240,
              child: LayoutBuilder(
                builder: (_, box) => ChatAccent(
                  accent: accent,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (wp != null)
                        ChatWallpaper(wallpaper: wp, dim: dim, size: box.biggest)
                      else
                        const ChatBackground(),
                      const _Sample(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _Title('Фон'),
          SizedBox(
            height: 112,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _Choice(
                  key: const ValueKey('wp-auto'),
                  label: 'Как везде',
                  selected: wp == null,
                  onTap: () => app.setChatLook(c, wallpaper: 'auto'),
                  child: const ChatBackground(),
                ),
                for (final (i, p) in wallpaperPresets.indexed)
                  _Choice(
                    key: ValueKey('wp-$i'),
                    label: p.$1,
                    selected: wp == 'p:$i',
                    onTap: () => app.setChatLook(c, wallpaper: 'p:$i'),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: p.$2,
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                  ),
                _Choice(
                  key: const ValueKey('wp-photo'),
                  label: 'Своё фото',
                  selected: photo,
                  onTap: _photo,
                  child: photo
                      ? Image.file(
                          File(wp.substring(2)),
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        )
                      : ColoredBox(
                          color: vc.surface,
                          child: Icon(Icons.add_photo_alternate_rounded, color: vc.textDim),
                        ),
                ),
              ],
            ),
          ),
          if (photo) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.brightness_6_rounded, color: vc.textDim, size: 20),
                const SizedBox(width: 8),
                Text('Затемнение', style: TextStyle(color: vc.text)),
                Expanded(
                  child: Slider(
                    value: dim.toDouble(),
                    max: 80,
                    divisions: 16,
                    activeColor: (accent ?? app.accent).mid,
                    onChanged: (v) => setState(() => _dim = v.round()),
                    onChangeEnd: (v) {
                      app.setChatLook(c, dim: v.round());
                      setState(() => _dim = null);
                    },
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('$dim %', style: TextStyle(color: vc.textDim, fontSize: 13)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          _Title('Цвет'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _ColorChoice(
                key: const ValueKey('ca-auto'),
                colors: [app.accent.a, app.accent.b],
                selected: own == null,
                label: 'Как везде',
                onTap: () => app.setChatLook(c, resetAccent: true),
              ),
              for (final (i, a) in chatAccents.indexed)
                _ColorChoice(
                  key: ValueKey('ca-$i'),
                  colors: [a.a, a.b],
                  selected: own == i,
                  label: a.name,
                  onTap: () => app.setChatLook(c, accent: i),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Фон и цвет видишь только ты — у собеседника всё как у него настроено.',
            style: TextStyle(color: vc.textFaint, fontSize: 12.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 2),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: context.vc.textFaint,
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.3,
      ),
    ),
  );
}

/// Пара пузырей для примера.
class _Sample extends StatelessWidget {
  const _Sample();

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    Widget bubble(String text, bool mine) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: mine ? acc.gradient : null,
          color: mine ? null : vc.bubbleIn,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Text(text, style: TextStyle(color: mine ? context.mineFg : vc.text, fontSize: 15)),
      ),
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        bubble('Привет! Как тебе новый фон? 😊', false),
        bubble('Огонь 🔥 оставляю', true),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Container(
              width: 62,
              height: 84,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? acc.mid : vc.border,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(selected ? 11.5 : 13),
                child: child,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? vc.text : vc.textDim,
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorChoice extends StatelessWidget {
  const _ColorChoice({
    super.key,
    required this.colors,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final List<Color> colors;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Tooltip(
      message: label,
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? vc.text : Colors.transparent, width: 2.5),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 20) : null,
          ),
        ),
      ),
    );
  }
}
