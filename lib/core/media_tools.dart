import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';

/// Помощники для вложений: тип файла, превью, открытие в других приложениях.

const _mimes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'mp3': 'audio/mpeg',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'apk': 'application/vnd.android.package-archive',
};

String mimeFor(String name) {
  final i = name.lastIndexOf('.');
  final ext = i < 0 ? '' : name.substring(i + 1).toLowerCase();
  return _mimes[ext] ?? 'application/octet-stream';
}

/// «1,4 МБ», «820 КБ».
String fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0).replaceAll('.', ',')} МБ';
}

/// Размеры картинки и крошечное размытое превью (PNG ~30 px, base64).
Future<({int width, int height, String? thumb})> imageMeta(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    final w = desc.width, h = desc.height;
    desc.dispose();
    buffer.dispose();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: w >= h ? 32 : null,
      targetHeight: h > w ? 32 : null,
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    final thumb = png == null ? null : base64.encode(png.buffer.asUint8List());
    return (width: w, height: h, thumb: thumb != null && thumb.length < 12000 ? thumb : null);
  } catch (_) {
    return (width: 0, height: 0, thumb: null);
  }
}

/// Размер кадра и длительность видео (или аудио).
Future<({int width, int height, int seconds})> videoMeta(String path) async {
  final c = VideoPlayerController.file(File(path));
  try {
    await c.initialize().timeout(const Duration(seconds: 8));
    final v = c.value;
    return (
      width: v.size.width.round(),
      height: v.size.height.round(),
      seconds: (v.duration.inMilliseconds / 1000).round(),
    );
  } catch (_) {
    return (width: 0, height: 0, seconds: 0);
  } finally {
    await c.dispose();
  }
}

/// Громкость (дБ, от −160 до 0) → [bars] столбиков 0..31 для формы волны.
List<int> compressWave(List<double> db, {int bars = 40}) {
  if (db.isEmpty) return List.filled(bars, 4);
  final levels = [for (final d in db) ((d + 50) / 50).clamp(0.0, 1.0)];
  return List.generate(bars, (i) {
    final from = (i * levels.length / bars).floor();
    final to = max(from + 1, ((i + 1) * levels.length / bars).floor());
    var peak = 0.0;
    for (var j = from; j < to && j < levels.length; j++) {
      peak = max(peak, levels[j]);
    }
    return (peak * 31).round().clamp(2, 31);
  });
}

const _open = MethodChannel('veil/open');

/// Открыть файл в подходящем приложении. false — такого приложения нет.
Future<bool> openExternally(String path, String mime) async {
  try {
    return await _open.invokeMethod<bool>('file', {'path': path, 'mime': mime}) ?? false;
  } catch (e) {
    debugPrint('open: $e');
    return false;
  }
}

/// Открыть точку в приложении карт.
Future<bool> openMap(GeoPoint g) async {
  try {
    return await _open.invokeMethod<bool>('geo', {'lat': g.lat, 'lng': g.lng}) ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> shareFile(String path, {String? text}) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: text));
}

/// Номер плитки карты (схема OSM/«слиппи»), дробный — для точного центра.
({double x, double y}) tileOf(double lat, double lng, int zoom) {
  final n = pow(2, zoom).toDouble();
  final x = (lng + 180) / 360 * n;
  final r = lat * pi / 180;
  final y = (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n;
  return (x: x, y: y);
}

/// Плитки карты (CARTO на данных OpenStreetMap): светлые или тёмные под тему.
String tileUrl(int x, int y, int zoom, {required bool dark}) {
  final style = dark ? 'dark_all' : 'rastertiles/voyager';
  final sub = 'abcd'[(x + y) % 4];
  return 'https://$sub.basemaps.cartocdn.com/$style/$zoom/$x/$y@2x.png';
}

const tileHeaders = {'User-Agent': 'Veil/0.1 (app.veil.messenger)'};
