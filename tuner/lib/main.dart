// TIWSHOP TUNER — แอพช่าง: จูน ECU ผ่านสาย USB (ตรงเข้า ECU) และเชื่อมต่อเกจผ่านบลูทูธ
// ขั้น 1: เชื่อมต่อ + พิสูจน์สาย/เกจ (อ่านอย่างเดียว ยังไม่เขียน ECU)
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:usb_serial_next/usb_serial_next.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'kline.dart';
import 'ecu_db.dart';
import 'tune.dart';

// GATT ของเกจ TIWSHOP (ตรงกับเฟิร์มแวร์)
const _suffix = '-5a41-5201-9c11-2a52a1c0de01';
final Guid kGaugeSvc = Guid('7a0f0001$_suffix');

const kBg = Color(0xFF0E1116);
const kCard = Color(0xFF171C24);
const kRed = Color(0xFFE23A3A);
const kCyan = Color(0xFF18D8FF);
const kGreen = Color(0xFF34D27B);
const kAmber = Color(0xFFFFC53A);
const kMut = Color(0xFF8A97A6);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TunerApp());
}

class TunerApp extends StatelessWidget {
  const TunerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TIWSHOP TUNER',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: const HomePage(),
    );
  }
}

enum Link { none, usb, ble }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Link link = Link.none;
  final List<String> _log = [];
  String status = 'ยังไม่เชื่อมต่อ';

  // USB
  UsbSerialPort? _port;
  KLine? _kl;
  StreamSubscription? _usbEv;
  bool _busy = false;

  // BLE
  BluetoothDevice? _dev;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // live cache สำหรับโหมด LIVE ในหน้าจูน (ดึงจากสาย)
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
      _usbEv = UsbSerial.instance.deviceEvents.listen((event) {
        if (event is UsbDeviceDetached) {
          if (link == Link.usb) {
            _say('ถอดสาย USB แล้ว');
            _disconnect();
          }
        } else if (event is UsbDeviceAttached) {
          _say('เสียบสาย USB');
        }
      });
    }
  }

  @override
  void dispose() {
    _usbEv?.cancel();
    _disconnect();
    super.dispose();
  }

  // ---------- USB (จูนผ่านสาย ตรงเข้า ECU) ----------
  Future<void> _connectUsb() async {
    if (!UsbSerial.isSupported) {
      _say('เครื่องนี้ไม่รองรับ USB-OTG');
      return;
    }
    await _disconnect();
    final usb = UsbSerial.instance;
    final all = await usb.listDevices();
    final devs = all.where((d) => d.isSerial).toList();
    if (devs.isEmpty) {
      _say('ไม่พบสาย USB — เสียบสาย FTDI/CH340/CP210x แล้วลองใหม่ (ต้องรองรับ USB-OTG)');
      return;
    }
    final d = devs.length == 1 ? devs.first : await _pickUsb(devs);
    if (d == null) return;
    final name = 'USB ${d.vendorId.toRadixString(16)}:${d.productId.toRadixString(16)}';
    _say('พบ: $name${d.serialNumber != null ? '  S/N ${d.serialNumber}' : ''}');
    try {
      // K-Line เริ่มที่ 10400 8N1 (ภายหลังจูนจริงจะมีสลับความเร็ว)
      final port = await usb.open(
        d,
        config: const SerialConfig(baudRate: 10400, dtr: true, rts: true),
      );
      _port = port;
      _kl = KLine(port);
      setState(() {
        link = Link.usb;
        status = 'ต่อสายแล้ว: $name';
      });
      _say('เปิดพอร์ต 10400 8N1 สำเร็จ — กด "อ่าน ECM ID" เพื่อต่อ ECU');
    } on SerialException catch (e) {
      if (e.error == SerialError.permissionDenied) {
        _say('ยังไม่ได้อนุญาต — กด "อนุญาต/OK" ตอน Android ถาม แล้วลองใหม่');
      } else {
        _say('เปิดพอร์ตไม่สำเร็จ: ${e.message}');
      }
    }
  }

  Future<dynamic> _pickUsb(List devs) {
    return showModalBottomSheet<dynamic>(
      context: context,
      backgroundColor: kCard,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(14), child: Text('เลือกสาย USB', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          for (final d in devs)
            ListTile(
              leading: const Icon(Icons.usb, color: kCyan),
              title: Text('USB ${d.vendorId.toRadixString(16)}:${d.productId.toRadixString(16)}'),
              subtitle: d.serialNumber != null ? Text('S/N ${d.serialNumber}') : null,
              onTap: () => Navigator.pop(context, d),
            ),
        ]),
      ),
    );
  }

  // ---------- BLE (เชื่อมต่อเกจ) ----------
  Future<void> _connectBle() async {
    await _disconnect();
    if (await FlutterBluePlus.isSupported == false) {
      _say('เครื่องนี้ไม่รองรับบลูทูธ');
      return;
    }
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
    } catch (_) {}
    _say('กำลังค้นหาเกจ…');
    final done = Completer<BluetoothDevice?>();
    _scanSub = FlutterBluePlus.scanResults.listen((rs) {
      if (rs.isNotEmpty && !done.isCompleted) done.complete(rs.first.device);
    });
    try {
      await FlutterBluePlus.startScan(withServices: [kGaugeSvc], timeout: const Duration(seconds: 10));
    } catch (e) {
      _say('ค้นหาไม่สำเร็จ: $e');
      return;
    }
    final dev = await done.future.timeout(const Duration(seconds: 11), onTimeout: () => null);
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (dev == null) {
      _say('ไม่พบเกจ — เปิดเกจแล้วลองใหม่');
      return;
    }
    final nm = dev.platformName.isEmpty ? dev.remoteId.str : dev.platformName;
    _say('พบเกจ: $nm');
    try {
      await dev.connect(timeout: const Duration(seconds: 10));
      await dev.discoverServices();
      _dev = dev;
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && link == Link.ble) {
          _say('เกจตัดการเชื่อมต่อ');
          _disconnect();
        }
      });
      setState(() {
        link = Link.ble;
        status = 'ต่อเกจแล้ว: $nm';
      });
      _say('เชื่อมต่อเกจสำเร็จ');
    } catch (e) {
      _say('เชื่อมต่อเกจไม่สำเร็จ: $e');
    }
  }

  Future<void> _readId() async {
    final kl = _kl;
    if (kl == null || _busy) return;
    setState(() => _busy = true);
    try {
      _say('เริ่มเชื่อมต่อ ECU (init)…');
      final ok = await kl.init();
      if (!ok) {
        _say('ต่อ ECU ไม่สำเร็จ — เช็กวงจร K-Line / ไฟ 12V / การต่อสาย');
        return;
      }
      _say('init สำเร็จ · กำลังอ่าน ECM ID…');
      final id = await kl.readEcuId();
      if (id == null) {
        _say('อ่าน ECM ID ไม่ได้ (ลองใหม่อีกครั้ง)');
        return;
      }
      final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      _say('ECM ID: $hex');
      final model = ecuModelFromId(id);
      kl.profile = KLine.profileFromName(model ?? '');
      _say(model != null ? '✓ รุ่น: $model' : 'รุ่น: ยังไม่รู้จัก (ไม่มีในฐานข้อมูล)');
    } catch (e) {
      _say('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startLivePoll() async {
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

  void _stopLivePoll() {
    _liveTimer?.cancel();
    _liveTimer = null;
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

  Future<void> _openTuneFromFiles() async {
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
    final cable = link == Link.usb;
    if (cable) await _startLivePoll();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => TunePage(
          fileName: bf.name,
          bin: Uint8List.fromList(bin),
          xdf: doc,
          getRpm: cable ? () => _liveCache?.rpm : null,
          getTps: cable ? () => _liveCache?.tps : null,
          onSave: (name, bytes) async => _saveBin(name, bytes),
        )));
    _stopLivePoll();
  }

  Future<void> _disconnect() async {
    _stopLivePoll();
    await _kl?.dispose();
    _kl = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _dev?.disconnect();
    } catch (_) {}
    _dev = null;
    if (mounted) {
      setState(() {
        link = Link.none;
        status = 'ยังไม่เชื่อมต่อ';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = link != Link.none;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        title: Row(children: [
          const Text('TIWSHOP ', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
          Text('TUNER', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1, color: kRed)),
        ]),
        actions: [
          if (connected)
            TextButton.icon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off, color: kAmber, size: 18),
              label: const Text('ตัดการเชื่อมต่อ', style: TextStyle(color: kAmber)),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(connected ? Icons.check_circle : Icons.circle_outlined, color: connected ? kGreen : kMut),
              const SizedBox(width: 10),
              Expanded(child: Text(status, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
              if (link == Link.usb) Text('RX ${_kl?.rx ?? 0} B', style: const TextStyle(color: kMut, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _connectCard(
              icon: Icons.usb, color: kCyan, title: 'จูนผ่านสาย', sub: 'USB → ECU ตรง',
              active: link == Link.usb, onTap: connected ? null : _connectUsb)),
            const SizedBox(width: 12),
            Expanded(child: _connectCard(
              icon: Icons.bluetooth, color: kGreen, title: 'เชื่อมต่อเกจ', sub: 'บลูทูธ',
              active: link == Link.ble, onTap: connected ? null : _connectBle)),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _openTuneFromFiles,
              style: OutlinedButton.styleFrom(foregroundColor: kAmber, side: const BorderSide(color: kAmber)),
              icon: const Icon(Icons.tune),
              label: const Text('จูนไฟล์ (เปิด BIN + XDF)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
          if (link == Link.usb) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _readId,
                style: ElevatedButton.styleFrom(backgroundColor: kCyan, foregroundColor: Colors.black),
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.memory),
                label: Text(_busy ? 'กำลังอ่าน…' : 'อ่าน ECM ID / รู้จักรุ่น', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () {
                  final kl = _kl;
                  if (kl != null) Navigator.push(context, MaterialPageRoute(builder: (_) => LivePage(kl)));
                },
                style: OutlinedButton.styleFrom(foregroundColor: kGreen, side: const BorderSide(color: kGreen)),
                icon: const Icon(Icons.speed),
                label: const Text('ดูค่าการทำงาน (Live)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ],
          const SizedBox(height: 14),
          const Align(alignment: Alignment.centerLeft, child: Text('บันทึก', style: TextStyle(color: kMut, fontWeight: FontWeight.bold))),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white10)),
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(_log[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFBFD0DE))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text('ขั้น 1: ทดสอบการเชื่อมต่อ · อ่านค่า/จูน/อัด จะเพิ่มในขั้นถัดไป',
              style: TextStyle(color: kMut, fontSize: 11)),
          const Text('จัดทำโดย ช่างทิวเมืองเลย 0810124526', style: TextStyle(color: kMut, fontSize: 11)),
        ]),
      ),
    );
  }

  Widget _connectCard({required IconData icon, required Color color, required String title, required String sub, required bool active, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.18) : kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? color : Colors.white10, width: active ? 2 : 1),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 34),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          Text(sub, style: const TextStyle(color: kMut, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ---------- ค่าการทำงาน (Live) ----------
class LivePage extends StatefulWidget {
  final KLine kl;
  const LivePage(this.kl, {super.key});
  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
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
      if (mounted) setState(() => _msg = 'อ่านค่าไม่ได้ — เช็กการต่อ ECU / ไฟ 12V');
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
      appBar: AppBar(backgroundColor: kBg, title: const Text('ค่าการทำงาน'), actions: [
        Padding(padding: const EdgeInsets.only(right: 12), child: Center(child: Text(_msg, style: const TextStyle(color: kMut, fontSize: 12)))),
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
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(t[0], style: const TextStyle(color: kMut, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(t[1], style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: kCyan)),
                  if (t[2].isNotEmpty) Text(t[2], style: const TextStyle(color: kMut, fontSize: 11)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
