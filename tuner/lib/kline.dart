// K-Line (Honda PGM-FI) ผ่านสาย USB-serial — ย้ายมาจากเฟิร์มแวร์เกจ
// เฟรมขอ : 72 05 [cmd] [id] [cs]      cmd 0x71 = ตารางข้อมูล
// เฟรมตอบ: 02 [len] [cmd] [id] [data...] [cs]   (len = จำนวนไบต์ทั้งเฟรม)
// checksum: (0x100 - ผลรวม) & 0xFF
import 'dart:async';
import 'dart:typed_data';
import 'package:usb_serial_next/usb_serial_next.dart';

class KLine {
  final UsbSerialPort port;
  final List<int> _buf = [];
  StreamSubscription<Uint8List>? _sub;
  int rx = 0;

  KLine(this.port) {
    _sub = port.input.listen((d) {
      rx += d.length;
      _buf.addAll(d);
    }, onError: (_) {});
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  int _cs(List<int> b, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += b[i];
    return (0x100 - (s & 0xFF)) & 0xFF;
  }

  void _flush() => _buf.clear();

  Future<int?> _readByte(int timeoutMs) async {
    final end = DateTime.now().millisecondsSinceEpoch + timeoutMs;
    while (_buf.isEmpty) {
      if (DateTime.now().millisecondsSinceEpoch >= end) return null;
      await Future.delayed(const Duration(milliseconds: 2));
    }
    return _buf.removeAt(0);
  }

  // ส่งเฟรม แล้วกลืน echo (K-Line สายเส้นเดียว ได้ยินเสียงตัวเองกลับมา)
  Future<void> _send(List<int> f) async {
    _flush();
    await port.write(f);
    for (int i = 0; i < f.length; i++) {
      await _readByte(60);
    }
  }

  Future<List<int>?> _recvFrame(int to) async {
    final end = DateTime.now().millisecondsSinceEpoch + to;
    // หา start marker 0x02
    while (true) {
      final left = end - DateTime.now().millisecondsSinceEpoch;
      if (left <= 0) return null;
      final b = await _readByte(left);
      if (b == null) return null;
      if (b == 0x02) break;
    }
    final fr = <int>[0x02];
    final total = await _readByte(to);
    if (total == null || total < 4 || total > 63) return null;
    fr.add(total);
    for (int i = 2; i < total; i++) {
      final b = await _readByte(to);
      if (b == null) return null;
      fr.add(b);
    }
    if (fr[total - 1] != _cs(fr, total - 1)) return null;
    return fr;
  }

  // คืนไบต์ข้อมูล (ไม่รวม header/checksum) หรือ null ถ้าไม่สำเร็จ
  Future<List<int>?> readBlock(int cmd, int id, int to) async {
    final req = [0x72, 0x05, cmd, id, 0];
    req[4] = _cs(req, 4);
    await _send(req);
    final fr = await _recvFrame(to);
    if (fr == null || fr.length < 5 || fr[2] != cmd || fr[3] != id) return null;
    return fr.sublist(4, fr.length - 1);
  }

  // เริ่มการสื่อสารกับ ECU: wake-up pulse -> FE 04 72 8C -> session 72 05 00 F0 99
  Future<bool> init() async {
    _flush();
    // ปิด session เก่า
    await port.write([0x72, 0x05, 0x00, 0xF1, 0x98]);
    await Future.delayed(const Duration(milliseconds: 100));
    _flush();
    // wake-up pulse: ดึง K-line ต่ำ 70ms ผ่าน break แล้วปล่อยสูง 140ms
    try {
      await port.setBreak(true);
      await Future.delayed(const Duration(milliseconds: 70));
      await port.setBreak(false);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 140));
    _flush();
    // init communication
    await _send([0xFE, 0x04, 0x72, 0x8C]);
    final r = <int>[];
    for (int i = 0; i < 4; i++) {
      final b = await _readByte(1000);
      if (b == null) return false;
      r.add(b);
    }
    if (!(r[0] == 0x0E && r[1] == 0x04 && r[2] == 0x72 && r[3] == _cs(r, 3))) return false;
    // start session
    await _send([0x72, 0x05, 0x00, 0xF0, 0x99]);
    final s = <int>[];
    for (int i = 0; i < 4; i++) {
      final b = await _readByte(1000);
      if (b == null) return false;
      s.add(b);
    }
    return s[0] == 0x02 && s[1] == 0x04 && s[2] == 0x00 && s[3] == _cs(s, 3);
  }

  // อ่าน ECM ID (ตาราง 0x00, 5 ไบต์แรก) ลองซ้ำ 3 ครั้ง
  Future<List<int>?> readEcuId() async {
    for (int a = 0; a < 3; a++) {
      final d = await readBlock(0x71, 0x00, 300);
      if (d != null && d.length >= 5) return d.sublist(0, 5);
      await Future.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }
}
