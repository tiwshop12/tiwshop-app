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

  void flush() => _flush();

  // ===================== คำสั่งสำหรับโปรแกรมอัด (flash) =====================
  // ส่งเฟรม (รวม checksum ท้ายแล้ว) -> กลืน echo -> อ่านคำตอบ [b0][len][..][cs]  (cs = cs8Honda)
  // คืนคำตอบทั้งเฟรม (g_rb) หรือ null ถ้าไม่ตอบ/checksum ผิด
  Future<List<int>?> flCmd(List<int> frame, {int sleepMs = 0}) async {
    await _send(frame);
    if (sleepMs > 0) await Future.delayed(Duration(milliseconds: sleepMs));
    int to = 60 + 2 * frame.length;
    if (to < 250) to = 250;
    final b0 = await _readByte(to);
    if (b0 == null) return null;
    final len = await _readByte(200);
    if (len == null || len < 4 || len > 160) return null;
    final r = <int>[b0, len];
    for (int i = 2; i < len; i++) {
      final b = await _readByte(200);
      if (b == null) return null;
      r.add(b);
    }
    if (r[len - 1] != _cs(r, len - 1)) return null;
    return r;
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

  // ---------- ค่าการทำงาน (live data) ----------
  // โปรไฟล์ถอดรหัส: 0=WAVE 1=LEAD 2=PCX 3=GIORNO (ย้ายจาก profileFromName ของเฟิร์มแวร์)
  int profile = 0; // BM_WAVE
  static int profileFromName(String nm) {
    if (nm.contains('PCX') || nm.contains('ADV')) return 2;
    if (nm.contains('Click 150') || nm.contains('Click 160')) return 2;
    if (nm.contains('Lead 125 4V')) return 1;
    if (nm.contains('Giorno')) return 3;
    return 0; // WAVE และกลุ่มเลย์เอาต์มาตรฐาน
  }

  int? _tableA; // ตารางเครื่องยนต์ที่กล็อกได้

  // หา/ล็อกตารางเครื่องยนต์ (PCX ลอง 0x11 ก่อน, อื่น ๆ 0x17 ก่อน แล้วไล่รายการ)
  Future<int?> pickEngineTable() async {
    final cands = <int>[profile == 2 ? 0x11 : 0x17, 0x10, 0x11, 0x13, 0x17];
    final seen = <int>{};
    for (final id in cands) {
      if (!seen.add(id)) continue;
      final d = await readBlock(0x71, id, 400);
      if (d != null && d.length > 0) {
        _tableA = id;
        return id;
      }
    }
    return null;
  }

  Future<Live?> readEngine([int? id]) async {
    final t = id ?? _tableA;
    if (t == null) return null;
    final d = await readBlock(0x71, t, 1000);
    if (d == null) return null;
    return _decodeEngine(t, d);
  }

  Live? _decodeEngine(int id, List<int> d) {
    switch (id) {
      case 0x10:
      case 0x11:
      case 0x13:
        return profile == 2 ? _decPcx(d) : _decStd(d);
      case 0x17:
        return _dec17(d);
      default:
        return null;
    }
  }

  double? _t(int v) => v == 0xFF ? null : (v - 40).toDouble();

  Live? _decStd(List<int> d) {
    if (d.length < 18) return null;
    return Live(
      rpm: ((d[0] << 8) | d[1]).toDouble(),
      tpsV: d[2] * 5.0 / 256.0,
      tps: d[3] * 0.5,
      ect: d[5] - 40.0,
      iat: d[7] - 40.0,
      map: d[9].toDouble(),
      batt: d[12] * 0.1,
      inj: ((d[14] << 8) | d[15]) / 200.0,
      ign: -64.0 + d[16] * 0.5,
      speed: d[17].toDouble(),
    );
  }

  Live? _decPcx(List<int> d) {
    if (d.length < 18) return null;
    return Live(
      rpm: ((d[0] << 8) | d[1]).toDouble(),
      tpsV: d[2] * 5.0 / 256.377,
      tps: d[3] * 0.5,
      ect: _t(d[5]),
      iat: _t(d[7]),
      map: d[9].toDouble(),
      batt: d[12] / 10.0,
      speed: d[13].toDouble(),
      inj: ((d[14] << 8) | d[15]) / 250.0,
      ign: (d[16] - 128.0) / 2.0,
      ltft: d[17] / 128.255,
    );
  }

  Live? _dec17(List<int> d) {
    if (d.length < 16) return null;
    final tV = d[4] * 5.0 / 255.0;
    final tC = _t(d[5]);
    final rawInj = (d[11] << 8) | d[12];
    final isWave = profile == 0;
    return Live(
      rpm: ((d[0] << 8) | d[1]).toDouble(),
      tpsV: d[2] * 5.0 / 255.0,
      tps: d[3] * 0.5,
      ect: isWave ? null : tC,
      ectV: isWave ? null : tV,
      eot: isWave ? tC : null,
      eotV: isWave ? tV : null,
      batt: d[10] * 0.1,
      inj: profile == 1 ? rawInj / 250.0 : rawInj * 0.003921,
      ign: (d[13] - 128.0) * 0.5,
      ltft: d.length > 14 ? d[14] / 128.255 : null,
      speed: (!isWave && d.length > 15 && d[15] != 0xFF) ? d[15].toDouble() : null,
    );
  }
}

class Live {
  final double? rpm, tps, tpsV, ect, ectV, eot, eotV, iat, map, batt, inj, ign, speed, ltft;
  Live({this.rpm, this.tps, this.tpsV, this.ect, this.ectV, this.eot, this.eotV, this.iat, this.map, this.batt, this.inj, this.ign, this.speed, this.ltft});
}
