// TIWSHOP TUNER — แอพช่าง: จูน ECU ผ่านสาย USB (ตรงเข้า ECU) และเชื่อมต่อเกจผ่านบลูทูธ
// ขั้น 1: เชื่อมต่อ + พิสูจน์สาย/เกจ (อ่านอย่างเดียว ยังไม่เขียน ECU)
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:usb_serial_next/usb_serial_next.dart';

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
  StreamSubscription<Uint8List>? _usbRx;
  StreamSubscription? _usbEv;

  // BLE
  BluetoothDevice? _dev;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  int _rxBytes = 0;

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
      _rxBytes = 0;
      _usbRx = port.input.listen((data) {
        _rxBytes += data.length;
        setState(() {});
      }, onError: (Object e) {
        _say('สาย USB ขัดข้อง: $e');
      });
      setState(() {
        link = Link.usb;
        status = 'ต่อสายแล้ว: $name';
      });
      _say('เปิดพอร์ต 10400 8N1 สำเร็จ — พร้อมต่อขั้นต่อไป (อ่าน ECM ID)');
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

  Future<void> _disconnect() async {
    await _usbRx?.cancel();
    _usbRx = null;
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
              if (link == Link.usb) Text('RX $_rxBytes B', style: const TextStyle(color: kMut, fontSize: 12)),
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
