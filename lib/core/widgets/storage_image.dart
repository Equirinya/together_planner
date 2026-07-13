import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

/// Downloads Firebase Storage files to a persistent on-disk cache and hands out
/// the resulting [File]s. A single shared instance is used by every
/// [StorageImage] so downloads are de-duplicated, throttled, and only fetched
/// once per app install (until evicted).
///
/// The cache lives in the application support directory rather than the
/// temporary directory, because the OS purges the temporary directory whenever
/// the app is backgrounded or storage runs low — which caused images to be
/// re-downloaded constantly. Growth is bounded by [_maxCacheBytes].
class StorageImageCache {
  StorageImageCache._();
  static final StorageImageCache instance = StorageImageCache._();

  /// Max number of Storage downloads running at once. The rest wait in [_queue].
  static const int _maxConcurrent = 4;

  /// Soft cap on total cache size before the oldest files are pruned.
  static const int _maxCacheBytes = 250 * 1024 * 1024;

  Directory? _dir;
  Future<Directory>? _dirFuture;

  /// Files known to exist on disk and be non-empty, for synchronous hits.
  final Map<String, File> _resolved = {};

  /// Downloads currently in progress, so concurrent requests share one fetch.
  final Map<String, Future<File>> _inFlight = {};

  int _active = 0;
  final Queue<Completer<void>> _queue = Queue();
  bool _pruned = false;

  String cacheId(String path, String? cacheKey) =>
      cacheKey == null || cacheKey.isEmpty ? path : '$path#$cacheKey';

  /// The already-cached file for [path], or null if it must be downloaded.
  /// Synchronous so a freshly mounted widget can paint without a frame of
  /// placeholder.
  File? resolvedFile(String path, String? cacheKey) =>
      _resolved[cacheId(path, cacheKey)];

  /// Returns the local file for [path], downloading it if necessary. Repeated
  /// calls for the same key (while one is in flight) share a single download.
  Future<File> getFile(String path, {String? cacheKey, bool force = false}) {
    final id = cacheId(path, cacheKey);

    if (!force) {
      final cached = _resolved[id];
      if (cached != null) return Future.value(cached);
      final ongoing = _inFlight[id];
      if (ongoing != null) return ongoing;
    }

    final future = _resolve(id, path, cacheKey, force);
    _inFlight[id] = future;
    future.whenComplete(() {
      if (_inFlight[id] == future) _inFlight.remove(id);
    });
    return future;
  }

  /// Pre-populates the cache for [path] with already-known [bytes] (e.g. a
  /// locally edited image about to be uploaded), so a widget that mounts for
  /// this path right after paints instantly instead of hitting the network.
  Future<File> seed(String path, Uint8List bytes, {String? cacheKey}) async {
    final dir = await _getDir();
    final id = cacheId(path, cacheKey);
    final file = File('${dir.path}/${_fileName(path, cacheKey)}');
    await file.writeAsBytes(bytes, flush: true);
    _resolved[id] = file;
    return file;
  }

  /// Drops [path] from the cache (memory + disk) so the next request re-downloads
  /// it. Used when a cached file fails to decode.
  Future<void> invalidate(String path, String? cacheKey) async {
    final id = cacheId(path, cacheKey);
    _resolved.remove(id);
    _inFlight.remove(id);
    try {
      final dir = await _getDir();
      final file = File('${dir.path}/${_fileName(path, cacheKey)}');
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('StorageImageCache invalidate failed: $e');
    }
  }

  Future<File> _resolve(
      String id, String path, String? cacheKey, bool force) async {
    final dir = await _getDir();
    final file = File('${dir.path}/${_fileName(path, cacheKey)}');

    if (!force && await file.exists() && await file.length() > 0) {
      _resolved[id] = file;
      return file;
    }

    await _withSlot(() async {
      final ref = FirebaseStorage.instance.ref(path);
      // Download to a temp file and rename on success, so an interrupted
      // download never leaves a partial file that later fails to decode.
      final part = File('${file.path}.part');
      await ref.writeToFile(part);
      if (await part.length() == 0) {
        await part.delete();
        throw Exception('Downloaded file is empty: $path');
      }
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    });

    _resolved[id] = file;
    return file;
  }

  /// Runs [task] once a download slot is free, releasing it (and waking the next
  /// waiter) when done.
  Future<T> _withSlot<T>(Future<T> Function() task) async {
    if (_active >= _maxConcurrent) {
      final waiter = Completer<void>();
      _queue.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_queue.isNotEmpty) _queue.removeFirst().complete();
    }
  }

  Future<Directory> _getDir() {
    if (_dir != null) return Future.value(_dir!);
    return _dirFuture ??= () async {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/storage_image_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      unawaited(_pruneOnce(dir));
      return dir;
    }();
  }

  String _fileName(String path, String? cacheKey) {
    final digest = md5.convert(utf8.encode(path + (cacheKey ?? ''))).toString();
    final dot = path.lastIndexOf('.');
    final ext = dot == -1
        ? ''
        : path.substring(dot + 1).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return ext.isEmpty ? digest : '$digest.$ext';
  }

  /// Once per session, deletes the oldest cached files if the cache exceeds
  /// [_maxCacheBytes], down to ~80% of the cap.
  Future<void> _pruneOnce(Directory dir) async {
    if (_pruned) return;
    _pruned = true;
    try {
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        files.add(entity);
        total += await entity.length();
      }
      if (total <= _maxCacheBytes) return;

      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = await f.lastModified();
      }
      files.sort((a, b) => stats[a]!.compareTo(stats[b]!));

      const target = _maxCacheBytes * 8 ~/ 10;
      for (final f in files) {
        if (total <= target) break;
        final len = await f.length();
        await f.delete();
        total -= len;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('StorageImageCache prune failed: $e');
    }
  }
}

class StorageImage extends StatefulWidget {
  /// The Firebase Storage path (e.g. "images/users/abc.jpg" or "folder/pic.png")
  final String storagePath;

  /// Widget shown while loading (optional)
  final Widget? placeholder;

  /// Widget shown on error (optional)
  final Widget? errorWidget;

  /// Image fit
  final BoxFit? fit;

  /// Retained for API compatibility; downloads always retry on the next build.
  final int? maxSizeBytes;
  final bool retryOnError;

  /// Decode-time downscaling. When both are given, width wins to preserve aspect.
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// Cache buster: when this changes, the file is re-downloaded even if the
  /// storagePath is unchanged (e.g. after the image at that path was replaced).
  final String? cacheKey;

  const StorageImage({
    super.key,
    required this.storagePath,
    this.placeholder,
    this.errorWidget,
    this.fit,
    this.maxSizeBytes,
    this.retryOnError = true,
    this.memCacheWidth,
    this.memCacheHeight,
    this.cacheKey,
  });

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  /// How many times to re-attempt decoding the same file (evicting Flutter's
  /// cached failure) before giving up and re-downloading it.
  static const int _maxDecodeRetries = 2;

  File? _file;
  bool _failed = false;
  bool _triedRedownload = false;
  int _decodeAttempt = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant StorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath ||
        oldWidget.cacheKey != widget.cacheKey) {
      _file = null;
      _failed = false;
      _triedRedownload = false;
      _decodeAttempt = 0;
      _resolve();
    }
  }

  void _resolve() {
    final cached = StorageImageCache.instance
        .resolvedFile(widget.storagePath, widget.cacheKey);
    if (cached != null) {
      _file = cached;
      return;
    }
    _load();
  }

  Future<void> _load({bool force = false}) async {
    // Capture identity so a result for a superseded path/key is ignored.
    final path = widget.storagePath;
    final cacheKey = widget.cacheKey;
    try {
      final file = await StorageImageCache.instance
          .getFile(path, cacheKey: cacheKey, force: force);
      if (!mounted || path != widget.storagePath || cacheKey != widget.cacheKey) {
        return;
      }
      setState(() {
        _file = file;
        _failed = false;
        _decodeAttempt = 0;
      });
    } catch (e, st) {
      if (kDebugMode) debugPrint('StorageImage load error: $e\n$st');
      if (!mounted || path != widget.storagePath || cacheKey != widget.cacheKey) {
        return;
      }
      setState(() => _failed = true);
    }
  }

  /// Handles a failed decode. The file on disk is usually fine — the decode was
  /// just attempted too early and Flutter cached the failure — so first evict
  /// that cached failure and retry the same file after a short settle. Only if
  /// retries are exhausted is the file treated as corrupt and re-downloaded.
  void _onDecodeError() {
    final file = _file;
    if (file == null) return;

    if (_decodeAttempt < _maxDecodeRetries) {
      _decodeAttempt++;
      FileImage(file).evict();
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() {});
      });
      return;
    }

    if (_triedRedownload) return;
    _triedRedownload = true;
    StorageImageCache.instance
        .invalidate(widget.storagePath, widget.cacheKey)
        .whenComplete(() {
      if (mounted) {
        _decodeAttempt = 0;
        _load(force: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file != null) {
      return Image.file(
        file,
        // Attempt is part of the key so an evict + rebuild produces a fresh
        // image element that re-resolves instead of reusing the failed stream.
        key: ValueKey('${file.path}#$_decodeAttempt'),
        fit: widget.fit,
        cacheWidth: (widget.memCacheWidth ?? 0) > 0 ? widget.memCacheWidth : null,
        cacheHeight: (widget.memCacheWidth ?? 0) > 0
            ? null
            : ((widget.memCacheHeight ?? 0) > 0 ? widget.memCacheHeight : null),
        errorBuilder: (_, __, ___) {
          _onDecodeError();
          return widget.errorWidget ?? const Icon(Icons.broken_image);
        },
      );
    }
    if (_failed) {
      return widget.errorWidget ??
          const Center(child: Icon(Icons.broken_image));
    }
    return Center(child: widget.placeholder ?? const Icon(Icons.image));
  }
}
