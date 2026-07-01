import 'dart:io';
import 'dart:convert';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

class StorageImage extends StatefulWidget {
  /// The Firebase Storage path (e.g. "images/users/abc.jpg" or "folder/pic.png")
  final String storagePath;

  /// Widget shown while loading (optional)
  final Widget? placeholder;

  /// Widget shown on error (optional)
  final Widget? errorWidget;

  /// Image fit
  final BoxFit? fit;

  /// max bytes to request through getData fallback (if used) — keep reasonably sized
  final int? maxSizeBytes;

  /// Whether to automatically attempt to re-download on error (useful for transient network)
  final bool retryOnError;

  ///if the image is displayed smaller than its raw resolution
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// Cache buster: when this changes, the file is re-downloaded even if the
  /// storagePath is unchanged (e.g. after the image at that path was replaced).
  final String? cacheKey;

  const StorageImage({
    Key? key,
    required this.storagePath,
    this.placeholder,
    this.errorWidget,
    this.fit,
    this.maxSizeBytes,
    this.retryOnError = true,
    this.memCacheWidth,
    this.memCacheHeight,
    this.cacheKey,
  }) : super(key: key);

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  static Directory? _globalCacheDir;
  static final Set<String> _verifiedDiskFiles = {};
  // Resolved files keyed by storage path, so a freshly mounted StorageImage for
  // an already-loaded image can render synchronously without the async disk
  // lookup (and its one-frame placeholder flash).
  static final Map<String, File> _resolvedFiles = {};

  File? _file;
  double? _progress;
  String? _error;
  bool _loading = true;
  bool _hasRetriedDecode = false;

  // Cache key combining the path with the optional cacheKey buster.
  String get _mapKey =>
      widget.cacheKey == null ? widget.storagePath : '${widget.storagePath}#${widget.cacheKey}';

  @override
  void initState() {
    super.initState();
    final cached = _resolvedFiles[_mapKey];
    if (cached != null) {
      _file = cached;
      _loading = false;
      _progress = 1;
    } else {
      _loadOrDownload();
    }
  }

  @override
  void didUpdateWidget(covariant StorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath || oldWidget.cacheKey != widget.cacheKey) {
      _hasRetriedDecode = false; // Reset the retry flag
      final cached = _resolvedFiles[_mapKey];
      if (cached != null) {
        _file = cached;
        _progress = 1;
        _error = null;
        _loading = false;
      } else {
        // reset and load new
        _file = null;
        _progress = null;
        _error = null;
        _loading = true;
        _loadOrDownload();
      }
    }
  }

  Future<String> _hashedFilename(String path) async {
    final bytes = utf8.encode(path + (widget.cacheKey ?? ''));
    final digest = md5.convert(bytes).toString();
    final ext = _extensionFromPath(path);
    return ext.isNotEmpty ? '$digest.$ext' : digest;
  }

  String _extensionFromPath(String path) {
    final idx = path.lastIndexOf('.');
    if (idx == -1) return '';
    return path.substring(idx + 1).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  }

  Future<Directory> _getCacheDir() async {
    if (_globalCacheDir != null) return _globalCacheDir!;

    final dir = await getTemporaryDirectory();
    final storageCache = Directory('${dir.path}/couple_planner_firebase_storage_cache');
    if (!await storageCache.exists()) {
      await storageCache.create(recursive: true);
    }

    _globalCacheDir = storageCache;
    return _globalCacheDir!;
  }

  Future<void> _handleCorruptFile() async {
    if (!mounted) return;

    setState(() {
      _hasRetriedDecode = true;
      _file = null;
      _loading = true;
      _error = null;
    });

    try {
      final cache = await _getCacheDir();
      final filename = await _hashedFilename(widget.storagePath);
      final file = File('${cache.path}/$filename');

      // Delete the corrupted file from disk and memory cache
      if (await file.exists()) {
        await file.delete();
      }
      _verifiedDiskFiles.remove(filename);
      _resolvedFiles.remove(_mapKey);
    } catch (e) {
      if (kDebugMode) debugPrint("Failed to delete corrupt file: $e");
    }

    // Force a fresh download
    _loadOrDownload(forceDownload: true);
  }

  Future<void> _loadOrDownload({bool forceDownload = false}) async {
    setState(() {
      _loading = true;
      _progress = null;
      _error = null;
    });

    try {
      final cache = await _getCacheDir();
      final filename = await _hashedFilename(widget.storagePath);
      final file = File('${cache.path}/$filename');

      // Skip cache check if we are forcing a redownload
      if (!forceDownload && (_verifiedDiskFiles.contains(filename) || await file.exists())) {
        _verifiedDiskFiles.add(filename); // Add to memory cache
        _resolvedFiles[_mapKey] = file;
        if (mounted) {
          setState(() {
            _file = file;
            _loading = false;
            _progress = 1;
          });
        }
        return;
      }

      final ref = FirebaseStorage.instance.ref(widget.storagePath);
      final downloadTask = ref.writeToFile(file);

      final sub = downloadTask.snapshotEvents.listen(
        (snapshot) {
          if (!mounted) return;
          final total = snapshot.totalBytes ?? 0;
          final transferred = snapshot.bytesTransferred;
          setState(() {
            _progress = total > 0 ? transferred / total : 0.0;
          });
        },
        onError: (e) {
          // Handle stream error quietly, catch block will handle failure
        },
      );

      await downloadTask;
      await sub.cancel();

      if (await file.exists()) {
        // Simple sanity check: Make sure the file isn't 0 bytes
        if (await file.length() == 0) {
          await file.delete();
          throw Exception('Downloaded file is empty');
        }

        _verifiedDiskFiles.add(filename); // Add to memory cache
        _resolvedFiles[_mapKey] = file;
        if (mounted) {
          setState(() {
            _file = file;
            _loading = false;
            _progress = 1.0;
          });
        }
        return;
      } else {
        throw Exception('Downloaded but file missing');
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('StorageImage download error: $e\n$st');

      if (widget.maxSizeBytes != null) {
        try {
          final ref = FirebaseStorage.instance.ref(widget.storagePath);
          final bytes = await ref.getData(widget.maxSizeBytes!);
          if (bytes != null && bytes.isNotEmpty) {
            final cache = await _getCacheDir();
            final filename = await _hashedFilename(widget.storagePath);
            final file = File('${cache.path}/$filename');
            await file.writeAsBytes(bytes);

            _verifiedDiskFiles.add(filename);
            _resolvedFiles[_mapKey] = file;
            if (mounted) {
              setState(() {
                _file = file;
                _loading = false;
                _progress = 1.0;
              });
            }
            return;
          }
        } catch (e2, st2) {
          if (kDebugMode) debugPrint('StorageImage fallback error: $e2\n$st2');
        }
      }

      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
          _progress = null;
        });
      }
    }
  }

  Widget _buildContent() {
    if (_file != null) {
      return Image.file(
        _file!,
        fit: widget.fit,
        cacheWidth: (widget.memCacheWidth != null && widget.memCacheWidth! > 0) ? widget.memCacheWidth : null,
        cacheHeight: (widget.memCacheWidth == null && widget.memCacheHeight != null && widget.memCacheHeight! > 0) ? widget.memCacheHeight : null,
        errorBuilder: (_, __, ___) => widget.errorWidget ?? const Icon(Icons.broken_image),
      );
    }
    if (_loading) {
      final placeholder = Center(child: widget.placeholder ?? const Icon(Icons.image));

      if (_progress != null) {
        return Stack(
          fit: StackFit.expand,
          children: [
            placeholder,
            Center(child: CircularProgressIndicator(value: _progress)),
          ],
        );
      }
      return placeholder;
    }

    return widget.errorWidget ?? Center(child: const Icon(Icons.broken_image));
  }

  @override
  Widget build(BuildContext context) {
    return _buildContent();
  }
}
