import 'dart:async';

import 'package:web/web.dart' as web;
import 'dart:js_interop';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/web_drop_item.dart';

/// A web implementation of the DesktopDrop plugin.
class DesktopDropWeb {
  final MethodChannel channel;

  DesktopDropWeb._private(this.channel);

  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'desktop_drop',
      const StandardMethodCodec(),
      registrar,
    );

    final pluginInstance = DesktopDropWeb._private(channel);
    channel.setMethodCallHandler(pluginInstance.handleMethodCall);
    pluginInstance._registerEvents();
  }

  // The FileSystemDirectoryReader.readEntries() Web API returns at most 100
  // entries per call by spec. To retrieve all children of a directory, the
  // caller must call readEntries() repeatedly until it returns an empty batch.
  // Calling it only once silently truncates directories with >100 files.
  // See: https://wicg.github.io/entries-api/#dom-filesystemdirectoryreader-readentries
  Future<List<dynamic>> _readAllEntries(
      web.FileSystemDirectoryReader reader) async {
    final allEntries = <dynamic>[];
    while (true) {
      final completer = Completer<List<dynamic>>();
      reader.readEntries((JSArray<web.FileSystemEntry> batch) {
        completer.complete(batch.toDart);
      }.toJS);
      final batch = await completer.future;
      if (batch.isEmpty) break;
      allEntries.addAll(batch);
    }
    return allEntries;
  }

  Future<WebDropItem> _entryToWebDropItem(web.FileSystemEntry entry) async {
    if (entry.isDirectory == true) {
      entry = entry as web.FileSystemDirectoryEntry;
      final web.FileSystemDirectoryReader reader = entry.createReader();

      final List<dynamic> entries = await _readAllEntries(reader);

      final children = await Future.wait(
        entries.map((e) => _entryToWebDropItem(e)),
      )
        ..removeWhere(
            (element) => element.name == '.DS_Store' && element.type == '');

      return WebDropItem(
        uri: web.URL.createObjectURL(web.Blob().slice(0, 0, 'directory')),
        name: entry.name,
        size: 0,
        lastModified: DateTime.now(),
        relativePath: entry.fullPath,
        type: 'directory',
        children: children,
      );
    }

    entry = entry as web.FileSystemFileEntry;

    Completer fileCompleter = Completer<web.File>();

    fileCallBack(web.File file) {
      fileCompleter.complete(file);
    }

    entry.file(fileCallBack.toJS);

    final web.File file = await fileCompleter.future;

    return WebDropItem(
      uri: web.URL.createObjectURL(file),
      name: file.name,
      size: file.size,
      lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      relativePath: entry.fullPath,
      type: file.type,
      children: [],
    );
  }

  void _registerEvents() {
    web.window.ondrop = ((web.DragEvent event) {
      event.preventDefault();

      final items = event.dataTransfer!.items;

      // A drag carries more than the files themselves: sources such as GTK
      // file managers add `text/uri-list` and `text/plain` string items
      // alongside them. `webkitGetAsEntry()` is null for every item whose
      // `kind` is not 'file', so mapping the whole list and force-unwrapping
      // threw before the drop could be delivered — synchronously, outside the
      // `catchError` below — and the drop was silently lost.
      final entries = <web.FileSystemEntry>[];
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (item.kind != 'file') continue;
        final entry = item.webkitGetAsEntry();
        if (entry == null) continue;
        entries.add(entry);
      }

      Future.wait(entries.map(_entryToWebDropItem)).then((webItems) {
        channel.invokeMethod(
          "performOperation_web",
          webItems.map((e) => e.toJson()).toList(),
        );
      }).catchError((e, s) {
        debugPrint('desktop_drop_web: $e $s');
      });
    }.toJS);

    web.window.ondragenter = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('entered', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);

    web.window.ondragover = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('updated', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);

    web.window.ondragleave = ((web.DragEvent event) {
      event.preventDefault();
      channel.invokeMethod('exited', [
        event.clientX.toDouble(),
        event.clientY.toDouble(),
      ]);
    }.toJS);
  }

  Future<dynamic> handleMethodCall(MethodCall call) async {
    throw PlatformException(
      code: 'Unimplemented',
      details: 'desktop_drop for web doesn\'t implement \'${call.method}\'',
    );
  }
}

extension DataTransferItemListExt on web.DataTransferItemList {
  external web.DataTransferItem operator [](int index);
}
