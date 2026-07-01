import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class _CacheEntry {
  final Map<String, dynamic> data;
  final DateTime timestamp;

  _CacheEntry(this.data, this.timestamp);

  bool get isValid => DateTime.now().difference(timestamp).inMinutes < 5;
}

class LoadDocumentBuilder extends StatelessWidget {
  const LoadDocumentBuilder({super.key, required this.docRef, required this.builder, this.useCache = true});

  final DocumentReference<Map<String, dynamic>> docRef;
  final Widget Function(Map<String, dynamic> data) builder;
  final bool useCache;

  static final Map<String, _CacheEntry> _memoryCache = {};

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: docRef.get(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          if (useCache && (_memoryCache[docRef.path]?.isValid ?? false)) {
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
      },
    );
  }
}

class LoadCollectionBuilder extends StatelessWidget {
  final Query<Map<String, dynamic>> collRef;
  final Widget Function(List<QueryDocumentSnapshot<Map<String, dynamic>>>) builder;

  const LoadCollectionBuilder({super.key, required this.collRef, required this.builder});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: collRef.get(),
      builder: (context, snapshot) {
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
      },
    );
  }
}
