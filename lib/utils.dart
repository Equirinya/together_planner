import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

String getRelativeDateString(DateTime date) {
  final now = DateTime.now();
  final difference = date.difference(now);

  if (difference.inDays > 6 || difference.inDays < -1) {
    return '${date.day}/${date.month}';
  } else if (difference.inHours > 0 && difference.inHours <= 24) {
    return 'Tomorrow';
  } else if (difference.inHours > -24 && difference.inHours <= 0) {
    return 'Today';
  } else if(difference.inHours > - 48 && difference.inHours <= 24) {
    return 'Yesterday';
  } else {
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return weekdays[date.weekday - 1];
  }
}

class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime timestamp;

  _CacheEntry(this.data, this.timestamp);

  bool get isValid => DateTime.now().difference(timestamp).inMinutes < 5;
}

class LoadDocumentBuilder extends StatelessWidget {
  const LoadDocumentBuilder({super.key, required this.docRef, required this.builder, this.useCache = true});


  final DocumentReference<Map<String, dynamic>> docRef;
  final Widget Function(Map<String,dynamic> data) builder;
  final bool useCache;

  static final Map<String, _CacheEntry> _memoryCache = {};

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(future: docRef.get(), builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        if(useCache && (_memoryCache[docRef.path]?.isValid ?? false)) {
          return builder(_memoryCache[docRef.path]!.data);
        }
        return const CupertinoActivityIndicator();
      }
      if (snapshot.hasError) {
        return const Icon(Icons.warning_rounded);
      }
      if (!snapshot.hasData || snapshot.data == null) {
        return const Icon(Icons.error_outline_rounded);
      }
      _memoryCache[docRef.path] = _CacheEntry(snapshot.data!.data()!, DateTime.now());
      return builder(snapshot.data!.data()!);
    },);
  }
}

class LoadCollectionBuilder extends StatelessWidget {
  final Query<Map<String, dynamic>> collRef;
  final Widget Function(List<QueryDocumentSnapshot<Map<String, dynamic>>>) builder;
  const LoadCollectionBuilder({super.key, required this.collRef, required this.builder});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(future: collRef.get(), builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const CupertinoActivityIndicator();
      }
      if (snapshot.hasError) {
        return const Icon(Icons.warning_rounded);
      }
      if (!snapshot.hasData || snapshot.data == null) {
        return const Icon(Icons.error_outline_rounded);
      }
      final docsData = snapshot.data!.docs;
      return builder(docsData);
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

  ///if the image is displayed smaller than its raw resolution
  final int? memCacheWidth;
  final int? memCacheHeight;

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
  }) : super(key: key);

  @override
  State<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<StorageImage> {
  static Directory? _globalCacheDir;
  static final Set<String> _verifiedDiskFiles = {};

  File? _file;
  double? _progress;
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
    final bytes = utf8.encode(path);
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

  Future<void> _loadOrDownload() async {
    setState(() {
      _loading = true;
      _progress = null;
      _error = null;
    });

    try {
      final cache = await _getCacheDir();
      final filename = await _hashedFilename(widget.storagePath);
      final file = File('${cache.path}/$filename');

      if (_verifiedDiskFiles.contains(filename) || await file.exists()) {
        _verifiedDiskFiles.add(filename); // Add to memory cache
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

      final sub = downloadTask.snapshotEvents.listen((snapshot) {
        if (!mounted) return;
        final total = snapshot.totalBytes ?? 0;
        final transferred = snapshot.bytesTransferred;
        setState(() {
          _progress = total > 0 ? transferred / total : 0.0;
        });
      }, onError: (e) {
        // Handle stream error quietly, catch block will handle failure
      });

      await downloadTask;
      await sub.cancel();

      if (await file.exists()) {
        _verifiedDiskFiles.add(filename); // Add to memory cache
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
          if (bytes != null) {
            final cache = await _getCacheDir();
            final filename = await _hashedFilename(widget.storagePath);
            final file = File('${cache.path}/$filename');
            await file.writeAsBytes(bytes);

            _verifiedDiskFiles.add(filename);
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
      final placeholder = widget.placeholder ??
          Container(
            color: Colors.grey.shade200,
            child: const Center(child: Icon(Icons.image)),
          );

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

    return widget.errorWidget ??
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image),
              const SizedBox(height: 6),
              const Text('Failed to load image', style: TextStyle(fontSize: 12)),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!, style: const TextStyle(fontSize: 10)),
              ],
              if (widget.retryOnError)
                TextButton(
                  onPressed: _loadOrDownload,
                  child: const Text('Retry'),
                )
            ],
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return _buildContent();
  }
}