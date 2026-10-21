import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'effects.dart';
import 'stickers.dart';
import 'visual.dart';

/// Панель над полем ввода: стикеры Veil, свои стикеры из фото и свои GIF.
class StickerPanel extends StatefulWidget {
  const StickerPanel({
    super.key,
    required this.onSticker,
    required this.onMine,
    required this.onGif,
    required this.onCreate,
    required this.onAddGif,
  });

  /// Стикер из набора Veil (код).
  final ValueChanged<String> onSticker;

  /// Свой стикер (путь к картинке).
  final ValueChanged<String> onMine;

  /// Свой GIF (путь).
  final ValueChanged<String> onGif;

  /// «Из фото» — сделать новый стикер.
  final VoidCallback onCreate;

  /// «С телефона» — добавить GIF.
  final VoidCallback onAddGif;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  int _tab = 0;

  Future<void> _remove(String path, {required bool gif}) async {
    final app = context.appRead;
    final vc = app.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text(gif ? 'Убрать GIF?' : 'Убрать стикер?', style: TextStyle(color: vc.text)),
        content: Text(
          'Он пропадёт только из твоей коллекции — у друзей останется.',
          style: TextStyle(color: vc.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Убрать')),
        ],
      ),
    );
    if (ok == true) {
      app.removeFromCollection(path);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = context.accent;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget tab(int i, String label) => Expanded(
      child: Pressable(
        scale: 0.95,
        onTap: () => setState(() => _tab = i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200).by(context),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            gradient: _tab == i ? acc.gradient : null,
            borderRadius: BorderRadius.circular(12 * context.skin.radius),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _tab == i ? acc.onAccent : vc.textDim,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );

    Widget addTile(IconData icon, String label, VoidCallback onTap) => Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: acc.a.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16 * context.skin.radius),
          border: Border.all(color: acc.a.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GradientIcon(icon, size: 26),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: vc.textDim, fontSize: 11, height: 1.1),
            ),
          ],
        ),
      ),
    );

    Widget file(String path, {required bool gif}) => Pressable(
      onTap: () => gif ? widget.onGif(path) : widget.onMine(path),
      onLongPress: () => _remove(path, gif: gif),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(gif ? 12 : 0),
        child: Image.file(
          File(path),
          fit: gif ? BoxFit.cover : BoxFit.contain,
          cacheWidth: (90 * dpr).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Icon(Icons.broken_image_rounded, color: vc.textFaint),
        ),
      ),
    );

    final mine = [
      for (final p in app.myStickers)
        if (File(p).existsSync()) p,
    ];
    final gifs = [
      for (final p in app.myGifs)
        if (File(p).existsSync()) p,
    ];

    final List<Widget> tiles;
    if (_tab == 0) {
      // Сначала свои (и «сделать из фото»), потом набор Veil.
      tiles = [
        addTile(Icons.add_photo_alternate_rounded, 'Из фото', widget.onCreate),
        for (final p in mine) file(p, gif: false),
        for (final s in VeilStickers.all)
          Pressable(
            key: ValueKey('stk-${s.id}'),
            onTap: () => widget.onSticker(s.id),
            child: Tooltip(message: s.label, child: VeilSticker(s, size: 64)),
          ),
      ];
    } else {
      tiles = [
        addTile(Icons.gif_box_rounded, 'С телефона', widget.onAddGif),
        for (final p in gifs) file(p, gif: true),
      ];
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: SizedBox(
          height: 290,
          child: Column(
            children: [
              Row(children: [tab(0, 'Стикеры'), const SizedBox(width: 6), tab(1, 'GIF')]),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.count(
                  crossAxisCount: _tab == 0 ? 5 : 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  padding: const EdgeInsets.only(bottom: 6),
                  children: tiles,
                ),
              ),
              if (_tab == 1 && gifs.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Добавь GIF с телефона — или сохрани присланный (удержи его в чате).',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: vc.textFaint, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
