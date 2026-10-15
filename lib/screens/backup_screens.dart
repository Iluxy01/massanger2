import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/backup.dart';
import '../core/media_tools.dart';
import '../state/app_state.dart';
import '../utils.dart';
import '../widgets/effects.dart';

/// Сохранить зашифрованную копию: пароль, «с файлами или без», затем отдать
/// файл через «Поделиться» (сохранить в Файлы, на Диск, себе в другой мессенджер).
Future<void> showExportBackup(BuildContext context) async {
  final app = context.appRead;
  if (app.demo) {
    showVeilToast(context, 'В демо-версии копию не сохранить', icon: Icons.backup_rounded);
    return;
  }
  final mediaBytes = await app.live!.media.usage();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ExportSheet(mediaBytes: mediaBytes),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.mediaBytes});
  final int mediaBytes;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _media = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pw = _pw.text;
    if (pw.length < 6) {
      setState(() => _error = 'Пароль — не короче 6 символов');
      return;
    }
    if (pw != _pw2.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.appRead;
    try {
      final dir = await getTemporaryDirectory();
      final d = DateTime.now();
      final out = '${dir.path}/veil-backup-${d.year}-${two(d.month)}-${two(d.day)}.veil';
      await app.exportBackup(out, pw, withMedia: _media);
      if (!mounted) return;
      Navigator.of(context).pop();
      await shareFile(out, text: 'Резервная копия Veil');
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не получилось сохранить: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: vc.textFaint),
      filled: true,
      fillColor: vc.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 28,
            color: vc.elevated,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const GradientIcon(Icons.backup_rounded, size: 26),
                    const SizedBox(width: 10),
                    Text(
                      'Резервная копия',
                      style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Один зашифрованный файл: ключ, друзья, переписка и настройки. С ним можно '
                  'перенести Veil на новый телефон. Без пароля файл бесполезен — '
                  'запиши пароль, восстановить его нельзя.',
                  style: TextStyle(color: vc.textDim, fontSize: 13.5, height: 1.35),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _pw,
                  obscureText: true,
                  enabled: !_busy,
                  style: TextStyle(color: vc.text),
                  decoration: deco('Пароль для копии'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pw2,
                  obscureText: true,
                  enabled: !_busy,
                  style: TextStyle(color: vc.text),
                  decoration: deco('Пароль ещё раз'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _media,
                  onChanged: _busy ? null : (v) => setState(() => _media = v),
                  title: Text('Фото, видео и файлы', style: TextStyle(color: vc.text)),
                  subtitle: Text(
                    widget.mediaBytes == 0
                        ? 'Файлов пока нет'
                        : 'Добавит ${fmtSize(widget.mediaBytes)}',
                    style: TextStyle(color: vc.textDim, fontSize: 12.5),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                _busy
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : AccentButton(
                        label: 'Сохранить копию',
                        icon: Icons.lock_rounded,
                        onTap: _save,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Восстановление на новом телефоне: выбрать файл копии и ввести пароль.
/// true — восстановлено.
Future<bool> restoreFromBackup(BuildContext context) async {
  final app = context.appRead;
  if (app.demo) {
    showVeilToast(context, 'В демо-версии восстановление недоступно', icon: Icons.backup_rounded);
    return false;
  }
  PlatformFile? f;
  try {
    f = await FilePicker.pickFile();
  } catch (_) {
    if (context.mounted) {
      showVeilToast(context, 'Не получилось открыть файлы', icon: Icons.error_outline_rounded);
    }
    return false;
  }
  if (f == null || !context.mounted) return false;
  // Файл из облака может прийти без пути — копируем во временную папку.
  var path = f.path;
  if (path == null || !File(path).existsSync()) {
    final tmp = await getTemporaryDirectory();
    final out = File('${tmp.path}/restore.veil');
    final sink = out.openWrite();
    await sink.addStream(f.readAsByteStream());
    await sink.close();
    path = out.path;
  }
  if (!context.mounted) return false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RestoreSheet(path: path!),
  );
  return ok ?? false;
}

class _RestoreSheet extends StatefulWidget {
  const _RestoreSheet({required this.path});
  final String path;

  @override
  State<_RestoreSheet> createState() => _RestoreSheetState();
}

class _RestoreSheetState extends State<_RestoreSheet> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.appRead.restoreBackup(widget.path, _pw.text);
      if (mounted) Navigator.of(context).pop(true);
    } on BackupError catch (e) {
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
          _error = 'Не получилось восстановить: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 28,
            color: vc.elevated,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Восстановление',
                  style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Введи пароль, который задал при сохранении копии.',
                  style: TextStyle(color: vc.textDim, fontSize: 13.5),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _pw,
                  obscureText: true,
                  autofocus: true,
                  enabled: !_busy,
                  onSubmitted: (_) => _restore(),
                  style: TextStyle(color: vc.text),
                  decoration: InputDecoration(
                    hintText: 'Пароль копии',
                    hintStyle: TextStyle(color: vc.textFaint),
                    filled: true,
                    fillColor: vc.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                _busy
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : AccentButton(
                        label: 'Восстановить',
                        icon: Icons.restore_rounded,
                        onTap: _restore,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
