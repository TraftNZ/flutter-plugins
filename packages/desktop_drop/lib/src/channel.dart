import 'dart:convert';

import 'package:dbus/dbus.dart';
import 'package:desktop_drop/src/drop_item.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:universal_platform/universal_platform.dart';

import 'events.dart';
import 'web_drop_item.dart';

typedef RawDropListener = void Function(DropEvent);

class DesktopDrop {
  static const MethodChannel _channel = MethodChannel('desktop_drop');

  DesktopDrop._();

  static final instance = DesktopDrop._();

  final _listeners = <RawDropListener>{};

  var _inited = false;

  /// The last drag position, per view; null keys the shared channel.
  final _offsets = <int?, Offset>{};

  /// The channels of the views attached with [attachView].
  final _viewChannels = <int, MethodChannel>{};

  static String _viewChannelName(int viewId) => 'desktop_drop/view/$viewId';

  void init() {
    if (_inited) {
      return;
    }
    _inited = true;
    _channel.setMethodCallHandler((call) => _handleCall(call, null));
  }

  Future<void> _handleCall(MethodCall call, int? viewId) async {
    try {
      return await _handleMethodChannel(call, viewId);
    } catch (e, s) {
      debugPrint('_handleMethodChannel: $e $s');
    }
  }

  /// Desktop: makes the native window [handle] a drop target whose events
  /// carry [viewId], for an app that creates its own windows.
  ///
  /// [handle] is the window's native handle: the `FlView` on Linux, the
  /// `NSWindow` on macOS and the top-level `HWND` on Windows. Without this
  /// only the plugin registrar's view accepts drops, and its events carry
  /// no view id. Destroying the window detaches it.
  Future<void> attachView({required int viewId, required int handle}) async {
    init();
    final channel = _viewChannels.putIfAbsent(
      viewId,
      () => MethodChannel(_viewChannelName(viewId)),
    );
    channel.setMethodCallHandler((call) => _handleCall(call, viewId));
    try {
      await _channel.invokeMethod<void>('attachView', {
        'viewId': viewId,
        'handle': handle,
      });
    } catch (_) {
      _releaseView(viewId);
      rethrow;
    }
  }

  /// Stops the window attached as [viewId] accepting drops while it stays
  /// open.
  Future<void> detachView({required int viewId}) async {
    if (!_viewChannels.containsKey(viewId)) return;
    _releaseView(viewId);
    await _channel.invokeMethod<void>('detachView', {'viewId': viewId});
  }

  void _releaseView(int viewId) {
    _viewChannels.remove(viewId)?.setMethodCallHandler(null);
    _offsets.remove(viewId);
  }

  /// macOS: Attempt to start security-scoped access for a bookmarked URL.
  ///
  /// Pass the [DropItem.extraAppleBookmark] bytes from a dropped file that
  /// originated outside the app container. Returns `true` if access began.
  ///
  /// If [bookmark] is empty, this function returns `false` and does not
  /// invoke the platform call. Promise files written under your container do
  /// not require security-scoped access.
  Future<bool> startAccessingSecurityScopedResource({
    required Uint8List bookmark,
  }) async {
    if (bookmark.isEmpty) return false;
    Map<String, dynamic> resultMap = {};
    resultMap["apple-bookmark"] = bookmark;
    final bool? result = await _channel.invokeMethod(
      "startAccessingSecurityScopedResource",
      resultMap,
    );
    if (result == null) return false;
    return result;
  }

  /// macOS: Stop security-scoped access previously started.
  ///
  /// If [bookmark] is empty, this function returns `true` and does not
  /// invoke the platform call, acting as a no-op.
  Future<bool> stopAccessingSecurityScopedResource({
    required Uint8List bookmark,
  }) async {
    if (bookmark.isEmpty) return true;
    Map<String, dynamic> resultMap = {};
    resultMap["apple-bookmark"] = bookmark;
    final bool result = await _channel.invokeMethod(
      "stopAccessingSecurityScopedResource",
      resultMap,
    );
    return result;
  }

  Future<void> _handleMethodChannel(MethodCall call, int? viewId) async {
    switch (call.method) {
      case "entered":
        final position = (call.arguments as List).cast<double>();
        _offsets[viewId] = Offset(position[0], position[1]);
        _notifyEvent(
          DropEnterEvent(viewId: viewId, location: _offsets[viewId]!),
        );
        break;
      case "updated":
        if (!_offsets.containsKey(viewId) && UniversalPlatform.isLinux) {
          final position = (call.arguments as List).cast<double>();
          _offsets[viewId] = Offset(position[0], position[1]);
          _notifyEvent(
            DropEnterEvent(viewId: viewId, location: _offsets[viewId]!),
          );
          return;
        }
        final position = (call.arguments as List).cast<double>();
        _offsets[viewId] = Offset(position[0], position[1]);
        _notifyEvent(
          DropUpdateEvent(viewId: viewId, location: _offsets[viewId]!),
        );
        break;
      case "exited":
        _notifyEvent(
          DropExitEvent(
            viewId: viewId,
            location: _offsets[viewId] ?? Offset.zero,
          ),
        );
        _offsets.remove(viewId);
        break;
      case "performOperation":
        final paths = (call.arguments as List).cast<String>();
        _notifyEvent(
          DropDoneEvent(
            viewId: viewId,
            location: _offsets[viewId] ?? Offset.zero,
            files: paths.map((e) => DropItemFile(e)).toList(),
          ),
        );
        _offsets.remove(viewId);
        break;
      case "performOperation_macos":
        final items = (call.arguments as List).cast<Map>();
        _notifyEvent(
          DropDoneEvent(
            viewId: viewId,
            location: _offsets[viewId] ?? Offset.zero,
            files: items.map((raw) {
              final path = raw["path"] as String;
              final bookmark = raw["apple-bookmark"] as Uint8List?;
              final isDir = (raw["isDirectory"] as bool?) ?? false;
              final fromPromise = (raw["fromPromise"] as bool?) ?? false;
              if (isDir) {
                return DropItemDirectory(
                  path,
                  const [],
                  extraAppleBookmark: bookmark,
                  fromPromise: fromPromise,
                );
              }
              return DropItemFile(
                path,
                extraAppleBookmark: bookmark,
                fromPromise: fromPromise,
              );
            }).toList(),
          ),
        );
        _offsets.remove(viewId);
        break;

      case "performOperation_linux":
        // gtk notify 'exit' before 'performOperation'.
        final text = (call.arguments as List<dynamic>)[0] as String;
        final offset = ((call.arguments as List<dynamic>)[1] as List<dynamic>)
            .cast<double>();
        final paths = const LineSplitter()
            .convert(text)
            .map((e) {
              try {
                final uri = Uri.tryParse(e);
                if (uri == null || !uri.hasScheme) {
                  // No scheme = likely a portal key
                  return '';
                }
                if (uri.scheme == 'file') {
                  return uri.toFilePath();
                }
                // smb://, http://, etc. - keep as-is (not portal keys)
                return e;
              } catch (error, stacktrace) {
                debugPrint('failed to parse linux path: $error $stacktrace');
              }
              return '';
            })
            .where((e) => e.isNotEmpty);
        _notifyEvent(
          DropDoneEvent(
            viewId: viewId,
            location: Offset(offset[0], offset[1]),
            files: paths.map((e) => DropItemFile(e)).toList(),
            rawText: text,
          ),
        );
        break;
      case "performOperation_portal":
        // The portal target carries a one-time transfer key instead of
        // file paths. Resolve it against org.freedesktop.portal.FileTransfer
        // so consumers receive paths they can open directly.
        final portalText = (call.arguments as List<dynamic>)[0] as String;
        final portalOffset =
            ((call.arguments as List<dynamic>)[1] as List<dynamic>)
                .cast<double>();
        final paths = await _resolvePortalFiles(portalText);
        _notifyEvent(
          DropDoneEvent(
            viewId: viewId,
            location: Offset(portalOffset[0], portalOffset[1]),
            files: paths.map((e) => DropItemFile(e)).toList(),
            rawText: portalText,
          ),
        );
        break;
      case "performOperation_web":
        final results = (call.arguments as List)
            .cast<Map>()
            .map((e) => WebDropItem.fromJson(e.cast<String, dynamic>()))
            .map((e) => e.toDropItem())
            .toList();
        _notifyEvent(
          DropDoneEvent(
            viewId: viewId,
            location: _offsets[viewId] ?? Offset.zero,
            files: results,
          ),
        );
        _offsets.remove(viewId);
        break;
      default:
        throw UnimplementedError('${call.method} not implement.');
    }
  }

  /// Resolves an XDG FileTransfer portal key into document-portal paths.
  ///
  /// RetrieveFiles exports each dropped file for this application and
  /// returns paths under /run/user/$UID/doc that are readable both inside
  /// and outside a Flatpak sandbox. On any failure an empty list is
  /// returned; rawText still carries the key for callers that implement
  /// their own resolution.
  Future<List<String>> _resolvePortalFiles(String key) async {
    DBusClient? client;
    try {
      client = DBusClient.session();
      final result = await client.callMethod(
        destination: 'org.freedesktop.portal.Documents',
        path: DBusObjectPath('/org/freedesktop/portal/documents'),
        interface: 'org.freedesktop.portal.FileTransfer',
        name: 'RetrieveFiles',
        values: [DBusString(key), DBusDict.stringVariant({})],
      );
      if (result.values.isEmpty || result.values.first is! DBusArray) {
        return const [];
      }
      return (result.values.first as DBusArray).children
          .map((value) => value.asString())
          .toList();
    } catch (error) {
      debugPrint('desktop_drop: failed to resolve portal transfer: $error');
      return const [];
    } finally {
      await client?.close();
    }
  }

  void _notifyEvent(DropEvent event) {
    for (final listener in _listeners) {
      listener(event);
    }
  }

  void addRawDropEventListener(RawDropListener listener) {
    assert(!_listeners.contains(listener));
    _listeners.add(listener);
  }

  void removeRawDropEventListener(RawDropListener listener) {
    assert(_listeners.contains(listener));
    _listeners.remove(listener);
  }
}
