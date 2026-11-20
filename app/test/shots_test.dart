// ถ่ายรูปหน้าจอแอพทุกหน้า -> build/shots/*.png  (รันใน GitHub Actions: .github/workflows/app-shots.yml)
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gauge/main.dart';
import 'package:gauge/tune.dart';

final _root = GlobalKey();
const _out = 'build/shots';
final _docs = Directory('${Directory.systemTemp.path}/tiw_docs');

Future<void> _fonts() async {
  final fd = Platform.environment['SHOT_FONTS'] ?? 'build/fonts';
  Future<void> fam(String name, List<String> files) async {
    final l = FontLoader(name);
    var n = 0;
    for (final p in files) {
      final f = File(p);
      if (f.existsSync()) { l.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync()))); n++; }
    }
    if (n > 0) await l.load();
    // ignore: avoid_print
    print('font $name: $n files');
  }
  await fam('Roboto', ['$fd/Roboto-Regular.ttf', '$fd/Roboto-Medium.ttf', '$fd/Roboto-Bold.ttf']);
  await fam('NotoThai', ['$fd/NotoSansThai-Regular.ttf', '$fd/NotoSansThai-Bold.ttf']);
  await fam('MaterialIcons', ['$fd/MaterialIcons-Regular.otf']);
  await fam('Ethnocentric', ['assets/fonts/ethnocentric_rg.ttf']);
  await fam('monospace', ['$fd/RobotoMono-Regular.ttf', '$fd/DejaVuSansMono.ttf']);
}

ThemeData _theme() {
  final b = ThemeData.dark();
  const fb = ['NotoThai'];
  return b.copyWith(
    scaffoldBackgroundColor: Colors.black,
    textTheme: b.textTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: fb),
    primaryTextTheme: b.primaryTextTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: fb),
  );
}

Widget _app(Widget home) => RepaintBoundary(
      key: _root,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: _theme(), home: home),
    );

void _view(WidgetTester t, {bool portrait = false}) {
  t.view.physicalSize = portrait ? const Size(1080, 2400) : const Size(2400, 1080);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

Future<void> _real(WidgetTester t, int ms) => t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));

Future<void> _settle(WidgetTester t) async {
  for (int k = 0; k < 2; k++) {
    await t.runAsync(() async {
      for (final e in find.byType(Image).evaluate().toList()) {
        try { await precacheImage((e.widget as Image).image, e); } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 150));
    });
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await _settle(t);
  final ro = _root.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await t.runAsync(() async {
    final img = await ro.toImage(pixelRatio: 2.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('$_out/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bd!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('shot $name');
}

// ไม่ให้ error ระหว่างวาด (เช่นล้นจอ) ทำให้หยุดถ่าย
void _quiet() {
  final old = FlutterError.onError;
  FlutterError.onError = (d) => debugPrint('UI error: ${d.exceptionAsString().split('\n').first}');
  addTearDown(() => FlutterError.onError = old);
}

Future<void> _tapText(WidgetTester t, String s) async {
  final f = find.text(s);
  if (f.evaluate().isEmpty) { debugPrint('no text "$s"'); return; }
  await t.tap(f.first, warnIfMissed: false);
  await t.pump(const Duration(milliseconds: 400));
}

NavigatorState _nav(WidgetTester t) => t.state<NavigatorState>(find.byType(Navigator).first);

Future<void> _pop(WidgetTester t) async {
  _nav(t).maybePop();
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    kShotMode = true;
    SharedPreferences.setMockInitialValues({});
    _docs.createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (c) async => _docs.path);
    // ไฟล์ของฉัน: ใส่ไฟล์ตัวอย่าง 2 ไฟล์
    final bins = Directory('${_docs.path}/bins')..createSync(recursive: true);
    File('assets/tunelib/m33_0.bin').copySync('${bins.path}/PCX160_2023_stock.bin');
    File('assets/tunelib/m33_0.bin').copySync('${bins.path}/PCX160_2023_tuned.bin');
    final xd = Directory('${_docs.path}/xdf')..createSync(recursive: true);
    File('assets/tunelib/m33.xdf').copySync('${xd.path}/K1ZP-T51_PCX160.xdf');
    await _fonts();
    await Cfg.i.load();
  });

  testWidgets('01 splash', (t) async {
    _view(t); _quiet();
    await t.pumpWidget(_app(const SplashPage()));
    await t.pump(const Duration(milliseconds: 1100));
    await _shot(t, 'app_01_splash');
    await t.pump(const Duration(seconds: 3));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('02 gauge pages', (t) async {
    _view(t); _quiet();
    await t.pumpWidget(_app(const GaugePage()));
    await t.pump(const Duration(milliseconds: 300));
    final c = GaugeController.last!;
    c.link = LinkState.connected;
    c.gaugeName = 'TIWSHOP-9A78';
    c.gpsOk = true;
    c.toggleDemo();
    // ให้ DEMO วิ่ง ~22 วิ (เวลาจริง) -> มีค่าเปลี่ยน กราฟ / DRAG / TOP SPEED มีข้อมูล
    for (int i = 0; i < 300; i++) {
      await _real(t, 70);
      await t.pump(const Duration(milliseconds: 70));
      c.link = LinkState.connected;
      c.gpsOk = true;
    }
    final pv = t.widget<PageView>(find.byType(PageView)).controller!;
    const names = ['dash', 'main', 'grid', 'graph', 'afr', 'drag', 'dtc', 'topspeed'];
    for (int p = 0; p < 8; p++) {
      pv.jumpToPage(p);
      for (int i = 0; i < 6; i++) { await _real(t, 60); await t.pump(const Duration(milliseconds: 60)); }
      await _shot(t, 'app_02_gauge_${p + 1}_${names[p]}');
    }
    // หน้าต่างเลือกค่าในช่อง
    pv.jumpToPage(1);
    await t.pump(const Duration(milliseconds: 300));
    final ctx = t.element(find.byType(PageView));
    // ignore: unawaited_futures
    pickKey(ctx, Cfg.i.dash, 0);
    await t.pump(const Duration(milliseconds: 500));
    await _shot(t, 'app_03_pickkey');
    await _pop(t);
    // ตั้งค่า
    await t.tap(find.byIcon(Icons.settings).first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 600));
    await _shot(t, 'app_04_settings_1');
    final sc = find.byType(Scrollable);
    for (int k = 2; k <= 6; k++) {
      if (sc.evaluate().isEmpty) break;
      await t.drag(sc.first, const Offset(0, -330), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 500));
      await _shot(t, 'app_04_settings_$k');
    }
    await _pop(t);
    // AFR LOG
    // ignore: unawaited_futures
    _nav(t).push(MaterialPageRoute(builder: (_) => AfrLogPage(c: c)));
    await t.pump(const Duration(milliseconds: 500));
    for (int i = 0; i < 6; i++) { await _real(t, 60); await t.pump(const Duration(milliseconds: 60)); }
    await _shot(t, 'app_05_afrlog');
    c.toggleDemo();
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('03 flash ecu', (t) async {
    _view(t); _quiet();
    final c = GaugeController();
    c.link = LinkState.connected;
    c.gaugeName = 'TIWSHOP-9A78';
    c.t = Telemetry(fresh: true, state: 2, proto: 1, rpm: 0, batt: 12.6, flashSup: true, ecmId: '0105050D01');
    await t.pumpWidget(_app(FlashPage(c: c)));
    for (int i = 0; i < 8; i++) { await _real(t, 120); await t.pump(const Duration(milliseconds: 100)); }
    await _shot(t, 'app_06_flash_library');
    await _tapText(t, 'ไฟล์ของฉัน');
    for (int i = 0; i < 4; i++) { await _real(t, 100); await t.pump(const Duration(milliseconds: 100)); }
    await _shot(t, 'app_07_flash_myfiles');
    await _tapText(t, 'XDF');
    for (int i = 0; i < 4; i++) { await _real(t, 100); await t.pump(const Duration(milliseconds: 100)); }
    await _shot(t, 'app_08_flash_xdf');
    // ระหว่างเขียนกล่อง
    c.t = Telemetry(fresh: true, state: 2, proto: 1, batt: 12.6, flashSup: true, flashState: 4, flashPct: 62, flashVendor: 1, fileRx: 2, ecmId: '0105050D01');
    c.notifyListeners();
    await _tapText(t, 'คลังจูน');
    for (int i = 0; i < 4; i++) { await _real(t, 100); await t.pump(const Duration(milliseconds: 100)); }
    await _shot(t, 'app_09_flash_writing');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('04 tune', (t) async {
    _view(t); _quiet();
    final xdf = XdfDoc.parse(String.fromCharCodes(File('assets/tunelib/m33.xdf').readAsBytesSync()));
    final bin = File('assets/tunelib/m33_0.bin').readAsBytesSync();
    await t.pumpWidget(_app(TunePage(fileName: 'PCX160_2023.bin', bin: bin, xdf: xdf, onSave: (n, b) async {}, getRpm: () => 4250, getTps: () => 18)));
    await t.pump(const Duration(milliseconds: 600));
    await _shot(t, 'app_10_tune_table');
    // กดค้างแล้วลาก = เลือกหลายช่อง
    final grid = find.byType(GestureDetector).evaluate().where((e) => (e.widget as GestureDetector).onLongPressStart != null).toList();
    if (grid.isNotEmpty) {
      final box = grid.first.renderObject as RenderBox;
      final p0 = box.localToGlobal(const Offset(120, 60));
      final g = await t.startGesture(p0);
      await t.pump(const Duration(milliseconds: 700));
      await g.moveTo(p0 + const Offset(170, 90));
      await t.pump(const Duration(milliseconds: 100));
      await g.moveTo(p0 + const Offset(260, 140));
      await t.pump(const Duration(milliseconds: 100));
      await g.up();
      await t.pump(const Duration(milliseconds: 300));
      await _shot(t, 'app_11_tune_multiselect');
    }
    await _tapText(t, '3D');
    await t.pump(const Duration(milliseconds: 500));
    await _shot(t, 'app_12_tune_3d');
    await _tapText(t, 'พรีวิว');
    await t.pump(const Duration(seconds: 2));
    await _shot(t, 'app_13_tune_3d_preview');
    await _tapText(t, 'หยุด');
    // รายการพารามิเตอร์ทั้งหมด
    await t.tap(find.byIcon(Icons.arrow_drop_down).first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 600));
    await _shot(t, 'app_14_tune_list');
    final patchChip = find.textContaining('แพตช์ ');
    if (patchChip.evaluate().isNotEmpty) {
      await t.tap(patchChip.first, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 500));
      await _shot(t, 'app_15_tune_list_patch');
      // เปิดแพตช์ตัวแรก
      final tiles = find.byType(ListTile);
      if (tiles.evaluate().isNotEmpty) {
        await t.tap(tiles.first, warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 600));
        await _shot(t, 'app_16_tune_patch');
      }
    }
    // FLAG
    await t.tap(find.byIcon(Icons.arrow_drop_down).first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 600));
    final flagChip = find.textContaining('FLAG ');
    if (flagChip.evaluate().isNotEmpty) {
      await t.tap(flagChip.first, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 500));
      await _shot(t, 'app_17_tune_list_flag');
      final tiles = find.byType(ListTile);
      if (tiles.evaluate().isNotEmpty) {
        await t.tap(tiles.first, warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 600));
        await _shot(t, 'app_18_tune_flag');
      }
    }
    // ขนาดหน้าจูน
    await t.tap(find.byIcon(Icons.format_size).first, warnIfMissed: false);
    await t.pump(const Duration(milliseconds: 600));
    await _shot(t, 'app_19_tune_size');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
