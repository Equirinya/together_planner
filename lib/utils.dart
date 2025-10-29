import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class LoadDocumentBuilder extends StatelessWidget {
  final DocumentReference<Map<String, dynamic>> docRef;
  final Widget Function(Map<String,dynamic> data) builder;
  const LoadDocumentBuilder({super.key, required this.docRef, required this.builder});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(future: docRef.get(), builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const CupertinoActivityIndicator();
      }
      if (snapshot.hasError) {
        return const Icon(Icons.warning_rounded);
      }
      if (!snapshot.hasData || snapshot.data == null) {
        return const Icon(Icons.error_outline_rounded);
      }
      return builder(snapshot.data!.data()!);
    },);
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

  /// max bytes to request through getData fallback (if used) — keep reasonably sized
  final int? maxSizeBytes;

  /// Whether to automatically attempt to re-download on error (useful for transient network)
  final bool retryOnError;

  const StorageImage({
    Key? key,
    required this.storagePath,
    this.placeholder,
    this.errorWidget,
    this.fit,
    this.maxSizeBytes,
    this.retryOnError = true,
  }) : super(key: key);

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  File? _file;
  double? _progress; // 0..1
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOrDownload();
  }

  @override
  void didUpdateWidget(covariant StorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath) {
      // reset and load new
      _file = null;
      _progress = null;
      _error = null;
      _loading = true;
      _loadOrDownload();
    }
  }

  Future<String> _hashedFilename(String path) async {
    // Use md5 of the storage path to create a stable filename. Keep original extension if present.
    final bytes = utf8.encode(path);
    final digest = md5.convert(bytes).toString();
    final ext = _extensionFromPath(path);
    return ext.isNotEmpty ? '$digest.$ext' : digest;
  }

  String _extensionFromPath(String path) {
    final idx = path.lastIndexOf('.');
    if (idx == -1) return '';
    final ext = path.substring(idx + 1);
    // sanitize a bit:
    final sanitized = ext.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return sanitized;
  }

  Future<Directory> _cacheDir() async {
    final dir = await getTemporaryDirectory(); // cache-like
    final storageCache = Directory('${dir.path}/couple_planner_firebase_storage_cache');
    if (!await storageCache.exists()) {
      await storageCache.create(recursive: true);
    }
    return storageCache;
  }

  Future<void> _loadOrDownload() async {
    setState(() {
      _loading = true;
      _progress = null;
      _error = null;
    });

    try {
      final cache = await _cacheDir();
      final filename = await _hashedFilename(widget.storagePath);
      final file = File('${cache.path}/$filename');

      // if cached, use it
      if (await file.exists()) {
        setState(() {
          _file = file;
          _loading = false;
          _progress = 1;
        });
        return;
      }

      // otherwise download from Firebase Storage directly to file (no public URL)
      final ref = FirebaseStorage.instance.ref(widget.storagePath);

      // Use writeToFile which streams to disk (preferred).
      // The return is a firebase_storage.DownloadTask which exposes snapshot events.
      final downloadTask = ref.writeToFile(file);

      // Listen for progress
      final sub = downloadTask.snapshotEvents.listen((snapshot) {
        final total = snapshot.totalBytes ?? 0;
        final transferred = snapshot.bytesTransferred;
        double p;
        if (total > 0) {
          p = transferred / total;
        } else {
          // if totalBytes not available, just set null or 0
          p = 0.0;
        }
        setState(() {
          _progress = p;
        });
      }, onError: (e) {
        // handle stream error
      });

      // Wait for completion
      await downloadTask;
      await sub.cancel();

      // double-check file exists
      if (await file.exists()) {
        setState(() {
          _file = file;
          _loading = false;
          _progress = 1.0;
        });
        return;
      } else {
        throw Exception('Downloaded but file missing');
      }
    } catch (e, st) {
      // If writeToFile is unavailable in your package version or fails, optional fallback:
      //  - Use ref.getData(maxSizeBytes) to retrieve bytes, then write to file.
      //  - But be aware getData loads into memory — keep maxSizeBytes small.
      // We'll attempt fallback only if writeToFile fails and a size is provided.
      if (kDebugMode) {
        // print stack in debug
        debugPrint('StorageImage download error: $e\n$st');
      }

      // Attempt fallback if maxSizeBytes supplied
      if (widget.maxSizeBytes != null) {
        try {
          final ref = FirebaseStorage.instance.ref(widget.storagePath);
          final bytes = await ref.getData(widget.maxSizeBytes!);
          if (bytes != null) {
            final cache = await _cacheDir();
            final filename = await _hashedFilename(widget.storagePath);
            final file = File('${cache.path}/$filename');
            await file.writeAsBytes(bytes);
            setState(() {
              _file = file;
              _loading = false;
              _progress = 1.0;
            });
            return;
          }
        } catch (e2, st2) {
          if (kDebugMode) {
            debugPrint('StorageImage fallback error: $e2\n$st2');
          }
        }
      }

      setState(() {
        _error = e.toString();
        _loading = false;
        _progress = null;
      });
    }
  }

  Widget _buildContent() {
    if (_file != null && _file!.existsSync()) {
      return Image.file(
        _file!,
        fit: widget.fit,
        errorBuilder: (_, __, ___) {
          return widget.errorWidget ?? const Icon(Icons.broken_image);
        },
      );
    }

    if (_loading) {
      // show placeholder + optional progress indicator
      final placeholder = widget.placeholder ??
          Container(
            color: Colors.grey.shade200,
            child: const Center(child: Icon(Icons.image)),
          );

      if (_progress != null) {
        // small linear progress overlay
        return Stack(
          fit: StackFit.expand,
          children: [
            placeholder,
            Center(
              child: CircularProgressIndicator(value: _progress),
            ),
          ],
        );
      }
      return placeholder;
    }

    // Not loading and no file => error
    final err = widget.errorWidget ??
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image),
              const SizedBox(height: 6),
              Text('Failed to load image', style: TextStyle(fontSize: 12)),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!, style: TextStyle(fontSize: 10)),
              ],
              if (widget.retryOnError)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _loadOrDownload();
                  },
                  child: const Text('Retry'),
                )
            ],
          ),
        );

    return err;
  }

  @override
  Widget build(BuildContext context) {
    return _buildContent();
  }
}
