import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _codec = StandardMethodCodec();

Future<void> _deliver(String channel, MethodCall call) {
  final completer = Completer<ByteData?>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel,
        _codec.encodeMethodCall(call),
        completer.complete,
      );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), (
          call,
        ) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), null);
  });

  test(
    'attachView sends the view id and handle, and its events carry the id',
    () async {
      await DesktopDrop.instance.attachView(viewId: 7, handle: 0x1234);
      addTearDown(() => DesktopDrop.instance.detachView(viewId: 7));
      expect(calls.single.method, 'attachView');
      expect(calls.single.arguments, {'viewId': 7, 'handle': 0x1234});

      final events = <DropEvent>[];
      void listener(DropEvent event) => events.add(event);
      DesktopDrop.instance.addRawDropEventListener(listener);
      addTearDown(
        () => DesktopDrop.instance.removeRawDropEventListener(listener),
      );

      await _deliver(
        'desktop_drop/view/7',
        const MethodCall('entered', [1.0, 2.0]),
      );
      await _deliver(
        'desktop_drop/view/7',
        const MethodCall('performOperation', ['/tmp/a.txt']),
      );
      await _deliver('desktop_drop', const MethodCall('entered', [3.0, 4.0]));

      expect(events.map((event) => event.viewId), [7, 7, null]);
      final done = events[1] as DropDoneEvent;
      expect(done.location, const Offset(1, 2));
      expect(done.files.single.path, '/tmp/a.txt');
    },
  );

  test('detachView stops the view channel and tells the platform', () async {
    await DesktopDrop.instance.attachView(viewId: 8, handle: 0x5678);
    await DesktopDrop.instance.detachView(viewId: 8);
    expect(calls.map((call) => call.method), ['attachView', 'detachView']);
    expect(calls.last.arguments, {'viewId': 8});

    final events = <DropEvent>[];
    void listener(DropEvent event) => events.add(event);
    DesktopDrop.instance.addRawDropEventListener(listener);
    addTearDown(
      () => DesktopDrop.instance.removeRawDropEventListener(listener),
    );
    await _deliver(
      'desktop_drop/view/8',
      const MethodCall('entered', [1.0, 2.0]),
    );
    expect(events, isEmpty);

    await DesktopDrop.instance.detachView(viewId: 8);
    expect(
      calls,
      hasLength(2),
      reason: 'a detached view is not detached twice',
    );
  });

  testWidgets('a DropTarget takes only its own view\'s events', (tester) async {
    final viewId = tester.view.viewId;
    final otherViewId = viewId + 1;
    final done = <DropDoneDetails>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DropTarget(onDragDone: done.add, child: const SizedBox.expand()),
      ),
    );
    await tester.runAsync(() async {
      await DesktopDrop.instance.attachView(viewId: viewId, handle: 1);
      await DesktopDrop.instance.attachView(viewId: otherViewId, handle: 2);
    });
    addTearDown(() async {
      await DesktopDrop.instance.detachView(viewId: viewId);
      await DesktopDrop.instance.detachView(viewId: otherViewId);
    });

    for (final id in [otherViewId, viewId]) {
      await tester.runAsync(() async {
        await _deliver(
          'desktop_drop/view/$id',
          const MethodCall('entered', [10.0, 10.0]),
        );
        await _deliver(
          'desktop_drop/view/$id',
          MethodCall('performOperation', ['/tmp/$id.txt']),
        );
      });
    }

    expect(done.map((details) => details.files.single.path), [
      '/tmp/$viewId.txt',
    ]);
  });
}
