// จูนผ่านสาย USB -> ECU (Android) : ต่อสาย FTDI/CH340 เข้าวงจร K-Line แล้วอ่าน/จูน ECU โดยตรง
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial_next/usb_serial_next.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'kline.dart';
import 'ecu_models.dart';
import 'tune.dart';
import 'flash_engine.dart';

const bool cableSupported = true;

// ---------- โหมดเชื่อมต่อผ่านสาย (ให้ทั้งแอพใช้เหมือน BLE) ----------
abstract class CableSession {
  Future<bool> connect();
  Future<bool> reconnect(); // ต่อ ECU ใหม่ (ใช้พอร์ตเดิม) หลังอัด/ปิดเปิดกุญแจ
  String? get ecmIdHex;
  int? get flashCount; // จำนวนครั้งที่กล่องถูกเขียน
  Future<Map<String, double?>?> readLive();
  Future<bool> flash(Uint8List bin, int vendorReq, void Function(int state, int pct) onProgress, void Function(String msg) onLog);
  Future<void> dispose();
}

CableSession? makeCableSession() => UsbSerial.isSupported ? _CableSessionImpl() : null;

class _CableSessionImpl implements CableSession {
  UsbSerialPort? _port;
  KLine? _kl;
  final List<int> _ecm = [];
  int? _flashCount;

  @override
  String? get ecmIdHex => _ecm.length >= 5 ? _ecm.take(5).map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase() : null;

  @override
  int? get flashCount => _flashCount;

  // อ่านรหัสกล่อง + จำนวนแฟลช + ล็อกตาราง (ใช้ตอน connect และ reconnect)
  Future<void> _ident() async {
    final kl = _kl!;
    final id = await kl.readEcuId();
    if (id != null) {
      _ecm
        ..clear()
        ..addAll(id);
      kl.profile = KLine.profileFromName(ecuModelFromId(id) ?? '');
    }
    // จำนวนแฟลช: Keihin 7D 06 01 01 03 78 ; ถ้าไม่ตอบ ลอง Shindengen 7B 06 02 01 03 79 ; ค่า = reply[6]
    _flashCount = null;
    var r = await kl.flCmd([0x7D, 0x06, 0x01, 0x01, 0x03, 0x78]);
    r ??= await kl.flCmd([0x7B, 0x06, 0x02, 0x01, 0x03, 0x79], sleepMs: 150);
    if (r != null && r.length >= 7) _flashCount = r[6];
    await kl.pickEngineTable();
  }

  @override
  Future<bool> connect() async {
    final usb = UsbSerial.instance;
    final devs = (await usb.listDevices()).where((d) => d.isSerial).toList();
    if (devs.isEmpty) return false;
    try {
      _port = await usb.open(devs.first, config: const SerialConfig(baudRate: 10400, dtr: true, rts: true));
    } catch (_) {
      return false;
    }
    final kl = KLine(_port!);
    _kl = kl;
    if (!await kl.init()) return false;
    await _ident();
    return true;
  }

  @override
  Future<bool> reconnect() async {
    final kl = _kl;
    if (kl == null) return false;
    if (!await kl.init()) return false;
    await _ident();
    return true;
  }

  @override
  Future<Map<String, double?>?> readLive() async {
    final kl = _kl;
    if (kl == null) return null;
    final lv = await kl.readEngine();
    if (lv == null) return null;
    return {
      'rpm': lv.rpm, 'tps': lv.tps, 'ect': lv.ect ?? lv.eot, 'eot': lv.eot,
      'iat': lv.iat, 'map': lv.map, 'batt': lv.batt, 'inj': lv.inj,
      'ign': lv.ign, 'speed': lv.speed, 'ltft': lv.ltft,
    };
  }

  @override
  Future<bool> flash(Uint8List bin, int vendorReq, void Function(int, int) onProgress, void Function(String) onLog) async {
    final kl = _kl;
    if (kl == null) return false;
    final eng = FlashEngine(kl, bin, onProgress: onProgress, onLog: onLog);
    final res = await eng.run(vendorReq: vendorReq);
    return res.ok;
  }

  @override
  Future<void> dispose() async {
    await _kl?.dispose();
    _kl = null;
    try { await _port?.close(); } catch (_) {}
    _port = null;
  }
}

String _failMsg(int code) {
  switch (code) {
    case 1: return 'ไฟล์ไม่ถูกต้อง/เล็กเกินไป';
    case 2: return 'ต่อกล่อง ECU ไม่ได้ (เช็กสาย/วงจร K-Line/ไฟ 12V)';
    case 5: return 'ปลดล็อค/ลบข้อมูลไม่สำเร็จ';
    case 6: return 'เขียนข้อมูลไม่สำเร็จ (กล่องอาจค้าง — ลองอัดซ้ำ)';
    case 7: return 'ชนิดกล่องไม่ตรงกับไฟล์';
    case 8: return 'ไฟล์ไม่ใช่ของกล่องรุ่นนี้ (checksum เกินขนาดไฟล์)';
    default: return 'ผิดพลาด';
  }
}

// อัดไฟล์เข้า ECU ผ่านสาย USB โดยตรง (เรียกจากหน้า FLASH ECU)
Future<bool> runCableFlash(BuildContext context, Uint8List bin, String fileName, int vendorReq) async {
  if (!UsbSerial.isSupported) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('เครื่องนี้ไม่รองรับ USB-OTG')));
    return false;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: _card,
      title: const Text('อัดผ่านสาย USB', style: TextStyle(color: _amber)),
      content: Text(
        'ไฟล์: $fileName\n\n'
        '• ต้องมีวงจร K-Line (L9637D) + ไฟ 12V เข้ากล่อง\n'
        '• ห้ามถอดสาย/ดับกุญแจระหว่างอัด\n'
        '• ทดสอบกับกล่องสำรองก่อนใช้จริง เขียนพลาดกล่องพังถาวรได้\n\n'
        'ยืนยันเริ่มอัด?',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ยกเลิก')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), style: ElevatedButton.styleFrom(backgroundColor: _amber, foregroundColor: Colors.black), child: const Text('เริ่มอัด')),
      ],
    ),
  );
  if (go != true) return false;

  final usb = UsbSerial.instance;
  final devs = (await usb.listDevices()).where((d) => d.isSerial).toList();
  if (devs.isEmpty) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ไม่พบสาย USB — เสียบ FTDI/CH340 ผ่าน OTG')));
    return false;
  }
  UsbSerialPort port;
  try {
    port = await usb.open(devs.first, config: const SerialConfig(baudRate: 10400, dtr: true, rts: true));
  } on SerialException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.error == SerialError.permissionDenied ? 'ยังไม่ได้อนุญาต USB' : 'เปิดพอร์ตไม่ได้')));
    return false;
  }
  final kl = KLine(port);
  final prog = _FlashProgress();
  final eng = FlashEngine(kl, bin, onProgress: prog.set, onLog: prog.log);
  if (context.mounted) {
    showDialog(context: context, barrierDismissible: false, builder: (_) => _FlashDialog(prog));
  }
  FlashResult res;
  try {
    res = await eng.run(vendorReq: vendorReq);
  } catch (_) {
    res = FlashResult(false, 99);
  } finally {
    await kl.dispose();
    try { await port.close(); } catch (_) {}
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop(); // ปิด dialog progress
  if (context.mounted) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: _card,
      title: Text(res.ok ? 'อัดสำเร็จ ✓' : 'อัดไม่สำเร็จ', style: TextStyle(color: res.ok ? _green : const Color(0xFFE23A3A))),
      content: Text(res.ok ? 'เขียนไฟล์เข้ากล่องเรียบร้อย' : _failMsg(res.failCode), style: const TextStyle(fontSize: 14)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ตกลง'))],
    ));
  }
  return res.ok;
}

class _FlashProgress extends ChangeNotifier {
  int state = 0, pct = 0;
  final List<String> logs = [];
  void set(int s, int p) { state = s; pct = p; notifyListeners(); }
  void log(String m) { logs.insert(0, m); notifyListeners(); }
}

const _flStateNames = ['รอ', 'เริ่มต้น', 'ปลดล็อค', 'ลบข้อมูล', 'กำลังเขียน', 'ตรวจสอบ/ปิดงาน', 'สำเร็จ', 'ล้มเหลว'];

class _FlashDialog extends StatelessWidget {
  final _FlashProgress prog;
  const _FlashDialog(this.prog);
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _card,
      title: const Text('กำลังอัด…', style: TextStyle(color: _cyan)),
      content: AnimatedBuilder(
        animation: prog,
        builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_flStateNames[prog.state.clamp(0, 7)], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: prog.pct / 100.0, minHeight: 10, backgroundColor: Colors.white12, color: _cyan)),
          const SizedBox(height: 6),
          Text('${prog.pct}%', style: const TextStyle(color: _mut)),
          const SizedBox(height: 10),
          SizedBox(height: 120, child: ListView(children: [for (final l in prog.logs) Text(l, style: const TextStyle(fontSize: 11, color: _mut))])),
          const SizedBox(height: 8),
          const Text('ห้ามถอดสาย / ดับกุญแจ', style: TextStyle(color: Color(0xFFE23A3A), fontSize: 12)),
        ]),
      ),
    );
  }
}

const _bg = Color(0xFF0E1116);
const _card = Color(0xFF171C24);
const _cyan = Color(0xFF18D8FF);
const _green = Color(0xFF34D27B);
const _amber = Color(0xFFFFC53A);
const _mut = Color(0xFF8A97A6);

class CableTunePage extends StatefulWidget {
  const CableTunePage({super.key});
  @override
  State<CableTunePage> createState() => _CableTunePageState();
}

class _CableTunePageState extends State<CableTunePage> {
  UsbSerialPort? _port;
  KLine? _kl;
  StreamSubscription? _usbEv;
  bool _busy = false;
  bool _connected = false;
  String status = 'ยังไม่ต่อสาย';
  final List<String> _log = [];
  Live? _liveCache;
  Timer? _liveTimer;

  void _say(String s) {
    final t = TimeOfDay.now();
    setState(() {
      _log.insert(0, '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}  $s');
      if (_log.length > 200) _log.removeLast();
    });
  }

  @override
  void initState() {
    super.initState();
    if (UsbSerial.isSupported) {
      _usbEv = UsbSerial.instance.deviceEvents.listen((e) {
        if (e is UsbDeviceDetached && _connected) {
          _say('ถอดสาย USB แล้ว');
          _disconnect();
        }
      });
    }
  }

  @override
  void dispose() {
    _usbEv?.cancel();
    _stopLive();
    _kl?.dispose();
    _port?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!UsbSerial.isSupported) {
      _say('เครื่องนี้ไม่รองรับ USB-OTG');
      return;
    }
    await _disconnect();
    final usb = UsbSerial.instance;
    final devs = (await usb.listDevices()).where((d) => d.isSerial).toList();
    if (devs.isEmpty) {
      _say('ไม่พบสาย — เสียบ FTDI/CH340/CP210x ผ่าน OTG แล้วลองใหม่');
      return;
    }
    final d = devs.first;
    final name = 'USB ${d.vendorId.toRadixString(16)}:${d.productId.toRadixString(16)}';
    try {
      final port = await usb.open(d, config: const SerialConfig(baudRate: 10400, dtr: true, rts: true));
      _port = port;
      _kl = KLine(port);
      setState(() {
        _connected = true;
        status = 'ต่อสายแล้ว: $name';
      });
      _say('เปิดพอร์ต 10400 8N1 — กด "อ่าน ECM ID" เพื่อต่อ ECU');
    } on SerialException catch (e) {
      _say(e.error == SerialError.permissionDenied ? 'ยังไม่ได้อนุญาต — กดอนุญาตแล้วลองใหม่' : 'เปิดพอร์ตไม่สำเร็จ: ${e.message}');
    }
  }

  Future<void> _readId() async {
    final kl = _kl;
    if (kl == null || _busy) return;
    setState(() => _busy = true);
    try {
      _say('เริ่มเชื่อมต่อ ECU (init)…');
      if (!await kl.init()) {
        _say('ต่อ ECU ไม่สำเร็จ — เช็กวงจร K-Line / ไฟ 12V / การต่อสาย');
        return;
      }
      _say('init สำเร็จ · กำลังอ่าน ECM ID…');
      final id = await kl.readEcuId();
      if (id == null) {
        _say('อ่าน ECM ID ไม่ได้');
        return;
      }
      final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      _say('ECM ID: $hex');
      final model = ecuModelFromId(id);
      kl.profile = KLine.profileFromName(model ?? '');
      _say(model != null ? '✓ รุ่น: $model' : 'รุ่น: ยังไม่รู้จัก');
    } catch (e) {
      _say('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startLive() async {
    final kl = _kl;
    if (kl == null) return;
    try { await kl.pickEngineTable(); } catch (_) {}
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      try {
        final lv = await kl.readEngine();
        if (lv != null) _liveCache = lv;
      } catch (_) {}
    });
  }

  void _stopLive() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  Future<void> _openLive() async {
    final kl = _kl;
    if (kl == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => _CableLivePage(kl)));
  }

  Future<void> _saveBin(String name, Uint8List bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safe = name.toLowerCase().endsWith('.bin') ? name : '$name.bin';
      final f = File('${dir.path}/$safe');
      await f.writeAsBytes(bytes);
      _say('บันทึก BIN ที่แก้แล้ว: ${f.path}');
    } catch (e) {
      _say('บันทึกไม่สำเร็จ: $e');
    }
  }

  Future<void> _openTune() async {
    final binRes = await FilePicker.platform.pickFiles(withData: true, dialogTitle: 'เลือกไฟล์ BIN');
    if (binRes == null || binRes.files.isEmpty) return;
    final bf = binRes.files.first;
    final bin = bf.bytes;
    if (bin == null) {
      _say('อ่านไฟล์ BIN ไม่ได้');
      return;
    }
    final xdfRes = await FilePicker.platform.pickFiles(withData: true, dialogTitle: 'เลือกไฟล์ XDF');
    if (xdfRes == null || xdfRes.files.isEmpty) {
      _say('ยังไม่ได้เลือก XDF');
      return;
    }
    final xb = xdfRes.files.first.bytes;
    if (xb == null) {
      _say('อ่านไฟล์ XDF ไม่ได้');
      return;
    }
    final doc = XdfDoc.parse(String.fromCharCodes(xb));
    if (doc.items.isEmpty) {
      _say('XDF นี้ไม่มีพารามิเตอร์ หรือเป็นแบบเข้ารหัส');
      return;
    }
    if (!mounted) return;
    final cable = _connected;
    if (cable) await _startLive();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TunePage(
          fileName: bf.name,
          bin: Uint8List.fromList(bin),
          xdf: doc,
          getRpm: cable ? () => _liveCache?.rpm : null,
          getTps: cable ? () => _liveCache?.tps : null,
          onSave: (name, bytes) async => _saveBin(name, bytes),
        )));
    _stopLive();
  }

  Future<void> _disconnect() async {
    _stopLive();
    await _kl?.dispose();
    _kl = null;
    try { await _port?.close(); } catch (_) {}
    _port = null;
    if (mounted) {
      setState(() {
        _connected = false;
        status = 'ยังไม่ต่อสาย';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('จูนผ่านสาย (USB → ECU)'),
        actions: [
          if (_connected)
            TextButton.icon(onPressed: _disconnect, icon: const Icon(Icons.link_off, color: _amber, size: 18), label: const Text('ตัดสาย', style: TextStyle(color: _amber))),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(_connected ? Icons.check_circle : Icons.circle_outlined, color: _connected ? _green : _mut),
              const SizedBox(width: 10),
              Expanded(child: Text(status, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ]),
          ),
          const SizedBox(height: 12),
          if (!_connected)
            SizedBox(height: 50, child: ElevatedButton.icon(
              onPressed: _connect,
              style: ElevatedButton.styleFrom(backgroundColor: _cyan, foregroundColor: Colors.black),
              icon: const Icon(Icons.usb),
              label: const Text('ต่อสาย USB', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            )),
          if (_connected) ...[
            SizedBox(height: 48, child: ElevatedButton.icon(
              onPressed: _busy ? null : _readId,
              style: ElevatedButton.styleFrom(backgroundColor: _cyan, foregroundColor: Colors.black),
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black)) : const Icon(Icons.memory),
              label: Text(_busy ? 'กำลังอ่าน…' : 'อ่าน ECM ID / รู้จักรุ่น', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            )),
            const SizedBox(height: 8),
            SizedBox(height: 48, child: OutlinedButton.icon(
              onPressed: _busy ? null : _openLive,
              style: OutlinedButton.styleFrom(foregroundColor: _green, side: const BorderSide(color: _green)),
              icon: const Icon(Icons.speed),
              label: const Text('ดูค่าการทำงาน (Live)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            )),
          ],
          const SizedBox(height: 8),
          SizedBox(height: 48, child: OutlinedButton.icon(
            onPressed: _busy ? null : _openTune,
            style: OutlinedButton.styleFrom(foregroundColor: _amber, side: const BorderSide(color: _amber)),
            icon: const Icon(Icons.tune),
            label: const Text('จูนไฟล์ (เปิด BIN + XDF)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          )),
          const SizedBox(height: 14),
          const Align(alignment: Alignment.centerLeft, child: Text('บันทึก', style: TextStyle(color: _mut, fontWeight: FontWeight.bold))),
          const SizedBox(height: 6),
          Expanded(child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white10)),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(_log[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFBFD0DE)))),
            ),
          )),
          const Text('ต้องมีวงจร K-Line (L9637D) คั่นระหว่างสาย FTDI กับ ECU · ไฟ 12V', style: TextStyle(color: _mut, fontSize: 11)),
        ]),
      ),
    );
  }
}

class _CableLivePage extends StatefulWidget {
  final KLine kl;
  const _CableLivePage(this.kl);
  @override
  State<_CableLivePage> createState() => _CableLivePageState();
}

class _CableLivePageState extends State<_CableLivePage> {
  Timer? _timer;
  Live? _live;
  String _msg = 'กำลังเริ่ม…';
  bool _poll = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _msg = 'กำลังหาตารางข้อมูล…');
    var t = await widget.kl.pickEngineTable();
    if (t == null) {
      setState(() => _msg = 'เชื่อมต่อ ECU ใหม่…');
      if (await widget.kl.init()) t = await widget.kl.pickEngineTable();
    }
    if (t == null) {
      if (mounted) setState(() => _msg = 'อ่านค่าไม่ได้ — เช็กการต่อ ECU');
      return;
    }
    if (mounted) setState(() => _msg = 'ตาราง 0x${t!.toRadixString(16).toUpperCase()}');
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (_poll) return;
      _poll = true;
      try {
        final lv = await widget.kl.readEngine();
        if (lv != null && mounted) setState(() => _live = lv);
      } catch (_) {}
      _poll = false;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _f(double? v, int dp, [String suf = '']) => v == null ? '—' : '${v.toStringAsFixed(dp)}$suf';

  @override
  Widget build(BuildContext context) {
    final lv = _live;
    final tiles = <List<String>>[
      ['รอบเครื่อง', _f(lv?.rpm, 0), 'rpm'],
      ['TPS', _f(lv?.tps, 1, '%'), _f(lv?.tpsV, 2, ' V')],
      ['อุณหภูมิ', _f(lv?.ect ?? lv?.eot, 1, '°C'), lv?.eot != null ? 'น้ำมันเครื่อง' : 'น้ำ/เครื่อง'],
      ['IAT อากาศ', _f(lv?.iat, 1, '°C'), ''],
      ['MAP', _f(lv?.map, 0), ''],
      ['แบตเตอรี่', _f(lv?.batt, 1, ' V'), ''],
      ['หัวฉีด', _f(lv?.inj, 2, ' ms'), ''],
      ['องศาไฟ', _f(lv?.ign, 1, '°'), ''],
      ['ความเร็ว', _f(lv?.speed, 0, ' กม/ชม'), ''],
      ['LTFT', _f(lv?.ltft, 2), ''],
    ];
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bg, title: const Text('ค่าการทำงาน'), actions: [
        Padding(padding: const EdgeInsets.only(right: 12), child: Center(child: Text(_msg, style: const TextStyle(color: _mut, fontSize: 12)))),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.count(
          crossAxisCount: 2,
          childAspectRatio: 1.7,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            for (final t in tiles)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(t[0], style: const TextStyle(color: _mut, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(t[1], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _cyan)),
                  if (t[2].isNotEmpty) Text(t[2], style: const TextStyle(color: _mut, fontSize: 11)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
