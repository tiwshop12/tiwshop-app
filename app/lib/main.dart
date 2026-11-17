import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'ecu_db.dart';
import 'tune.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'flash_page.dart';

// ---------- BLE UUIDs (ต้องตรงกับ BleGauge.h) ----------
final Guid kSvc = Guid('7a0f0001-5a41-5201-9c11-2a52a1c0de01');
final Guid kData = Guid('7a0f0002-5a41-5201-9c11-2a52a1c0de01');
final Guid kCmd = Guid('7a0f0003-5a41-5201-9c11-2a52a1c0de01');
final Guid kImg = Guid('7a0f0004-5a41-5201-9c11-2a52a1c0de01');
final Guid kFile = Guid('7a0f0005-5a41-5201-9c11-2a52a1c0de01'); // ส่งไฟล์ .bin ไปเขียนกล่อง ECU

const kFont = 'Ethnocentric';
const kGreen = Color(0xFF3CFF8A);
const kAmber = Color(0xFFFFB020);
const kBad = Color(0xFFFF4D4D);
const kMaxRpm = 15000.0;
const kZoneRpm = 12000.0;

// ---------- ธีมสี ----------
class AppTheme {
  final String name;
  final Color c; // สีหลัก
  final Color c2; // สีอ่อน/โซนแดงไลน์
  const AppTheme(this.name, this.c, this.c2);
}

const kThemes = <AppTheme>[
  AppTheme('แดง', Color(0xFFFF2A2A), Color(0xFFFF8A8A)),
  AppTheme('ม่วง', Color(0xFFB04CFF), Color(0xFFDDB0FF)),
  AppTheme('ฟ้า', Color(0xFF2EB8FF), Color(0xFFA2E3FF)),
  AppTheme('เขียวนีออน', Color(0xFF39FF14), Color(0xFFB4FF9E)),
  AppTheme('ชมพู', Color(0xFFFF4FD8), Color(0xFFFFAEEF)),
  AppTheme('น้ำเงิน', Color(0xFF2A5BFF), Color(0xFFAFC2FF)),
];

// ---------- พื้นหลัง (ตั้งค่า > พื้นหลัง) : เหมือนเกจ TIWSHOP ----------
// color == null และ i == 0 = รูปเดิม (เขียว) | สีอื่น = รูปเดียวกันย้อมสี | ขาวดำ = ย้อมขาว | ดำล้วน = พื้นดำ (เร็วที่สุด)
class BgOpt {
  final String name;
  final Color? color;
  const BgOpt(this.name, this.color);
}

const kBgs = <BgOpt>[
  BgOpt('เดิม', null),
  BgOpt('แดง', Color(0xFFFF2A2A)),
  BgOpt('ส้ม', Color(0xFFFF8A1E)),
  BgOpt('เหลือง', Color(0xFFFFE01A)),
  BgOpt('ฟ้า', Color(0xFF18D8FF)),
  BgOpt('น้ำเงิน', Color(0xFF1E6BFF)),
  BgOpt('ม่วง', Color(0xFFA14DFF)),
  BgOpt('ชมพู', Color(0xFFFF2BD6)),
  BgOpt('ขาวดำ', Color(0xFFFFFFFF)),
  BgOpt('ดำล้วน', Color(0xFF000000)),
];

// เวอร์ชันเฟิร์มแวร์ที่แอพรุ่นนี้ออกแบบมาให้ใช้คู่กัน (แสดงเทียบในหน้า SETTING)
const kAppFw = '1.3.0';

// ---------- ค่าคีย์ที่แสดงได้ (เหมือน TEST1 + TOP SPD) ----------
const int kTps = 0, kTemp = 1, kBatt = 2, kAfr = 3, kInj = 4, kIgn = 5, kRpm = 6, kMap = 7,
    kSpd = 8, kEot = 9, kIat = 10, kO2 = 11, kStft = 12, kLtft = 13, kTop = 14;

class KeyDef {
  final String name, unit;
  final int dec;
  const KeyDef(this.name, this.unit, this.dec);
}

const kKeys = <KeyDef>[
  KeyDef('TPS', '%', 1), KeyDef('W.TEMP', '°C', 0), KeyDef('BATT', 'V', 1), KeyDef('AFR', '', 1),
  KeyDef('INJ', 'ms', 2), KeyDef('IGN', '°BTDC', 1), KeyDef('RPM', 'rpm', 0), KeyDef('MAP', 'kPa', 0),
  KeyDef('SPD', 'km/h', 0), KeyDef('EOT', '°C', 0), KeyDef('IAT', '°C', 0), KeyDef('O2', 'V', 2),
  KeyDef('STFT', '', 3), KeyDef('LTFT', '', 3), KeyDef('TOP SPD', 'km/h', 0),
];

// สีค่าคงที่ (ไม่เปลี่ยนตามธีม)
const kTpsBlue = Color(0xFF3D6BFF);
const kBattRed = Color(0xFFFF3B3B);
const kAfrLow = Color(0xFF2EB8FF); // < 13  ฟ้า
const kAfrOk = Color(0xFF3CFF8A); // 13-14.7 เขียว
const kAfrHigh = Color(0xFFFF3B3B); // > 14.7 แดง

Color afrColor(double v) => v < 13.0 ? kAfrLow : (v <= 14.7 ? kAfrOk : kAfrHigh);

// ---------- คำอธิบาย DTC Honda (ตรงกับ DTC_TABLE ในเฟิร์มแวร์เกจ) : (อังกฤษ, ไทย) ----------
const Map<int, (String, String)> kDtcDesc = {
  101: ('MAP sensor low voltage', 'เซนเซอร์ MAP แรงดันต่ำ'),
  102: ('MAP sensor high voltage', 'เซนเซอร์ MAP แรงดันสูง'),
  201: ('MAP sensor performance', 'เซนเซอร์ MAP ทำงานผิดปกติ'),
  601: ('Baro sensor low voltage', 'เซนเซอร์ความดันบรรยากาศ แรงดันต่ำ'),
  602: ('Baro sensor high voltage', 'เซนเซอร์ความดันบรรยากาศ แรงดันสูง'),
  701: ('ECT sensor low voltage', 'เซนเซอร์อุณหภูมิน้ำ (ECT) แรงดันต่ำ'),
  702: ('ECT sensor high voltage', 'เซนเซอร์อุณหภูมิน้ำ (ECT) แรงดันสูง'),
  801: ('TP sensor low voltage', 'เซนเซอร์ลิ้นเร่ง (TP) แรงดันต่ำ'),
  802: ('TP sensor high voltage', 'เซนเซอร์ลิ้นเร่ง (TP) แรงดันสูง'),
  901: ('IAT sensor low voltage', 'เซนเซอร์อุณหภูมิอากาศ (IAT) แรงดันต่ำ'),
  902: ('IAT sensor high voltage', 'เซนเซอร์อุณหภูมิอากาศ (IAT) แรงดันสูง'),
  1101: ('VS sensor no signal', 'เซนเซอร์ความเร็ว (VS) ไม่มีสัญญาณ'),
  1201: ('No.1 primary injector', 'หัวฉีดหลัก สูบ 1'),
  1301: ('No.2 primary injector', 'หัวฉีดหลัก สูบ 2'),
  1401: ('No.3 primary injector', 'หัวฉีดหลัก สูบ 3'),
  1501: ('No.4 primary injector', 'หัวฉีดหลัก สูบ 4'),
  1601: ('No.1 secondary injector', 'หัวฉีดรอง สูบ 1'),
  1701: ('No.2 secondary injector', 'หัวฉีดรอง สูบ 2'),
  1801: ('CMP sensor no signal', 'เซนเซอร์เพลาลูกเบี้ยว (CMP) ไม่มีสัญญาณ'),
  1901: ('CKP sensor no signal', 'เซนเซอร์เพลาข้อเหวี่ยง (CKP) ไม่มีสัญญาณ'),
  2101: ('O2 sensor 1 low voltage', 'เซนเซอร์ O2 ตัวที่ 1 แรงดันต่ำ'),
  2102: ('O2 sensor 1 high voltage', 'เซนเซอร์ O2 ตัวที่ 1 แรงดันสูง'),
  2201: ('O2 sensor 2 low voltage', 'เซนเซอร์ O2 ตัวที่ 2 แรงดันต่ำ'),
  2202: ('O2 sensor 2 high voltage', 'เซนเซอร์ O2 ตัวที่ 2 แรงดันสูง'),
};
(String, String)? dtcDesc(int code, int sub) => kDtcDesc[code * 100 + sub];

/// สีไล่เฉดเขียว -> เหลือง -> แดง ตามตำแหน่งรอบเครื่อง เทียบกับ SHIFT RPM
Color rpmColor(double rpm, int shift) {
  final t = (rpm / math.max(1, shift)).clamp(0.0, 1.0).toDouble();
  const g = Color(0xFF29E868), y = Color(0xFFFFD21F), r = Color(0xFFFF2A2A);
  return t < 0.65 ? Color.lerp(g, y, t / 0.65)! : Color.lerp(y, r, (t - 0.65) / 0.35)!;
}

// ---------- การตั้งค่าที่บันทึกในเครื่อง ----------
class Cfg extends ChangeNotifier {
  static final Cfg i = Cfg._();
  Cfg._();
  int themeIdx = 3;
  int bgIdx = 0; // พื้นหลัง (kBgs)
  int shift = 10000; // SHIFT LIGHT RPM
  int tempWarn = 105; // °C
  bool speedGps = true; // true = GPS, false = ECU
  int graphOn = 15; // หน้า GRAPH: บิตเปิด-ปิดเส้นกราฟ RPM/TPS/GPS/AFR
  List<int> main = [kTps, kAfr, kIgn, kTemp, kEot, kBatt, kIat]; // ซ้าย 3 (0-2) + ขวา 3 (3-5) | ช่องที่ 7 เก็บไว้ (ไม่แสดง) ให้ค่าที่บันทึกเดิมยังเข้ากันได้
  List<int> grid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  List<int> ctr = [kSpd, kRpm]; // หน้าเกจ: [ตัวเลขกลางเกจ, ช่องใต้เกจ] — แตะเพื่อเลือกค่า (เลือกค่าที่อยู่อีกช่อง = สลับกัน)
  List<int> dash = [kInj, kIgn, kIat, kBatt, kO2, kStft, kLtft]; // หน้า DASH: รายการขวา 7 แถว

  AppTheme get t => kThemes[themeIdx];

  List<int>? _parse(String? s, int len) {
    if (s == null) return null;
    final l = s.split(',').map((e) => int.tryParse(e)).toList();
    if (l.length != len || l.any((e) => e == null || e < 0 || e >= kKeys.length)) return null;
    return l.cast<int>();
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt('theme') ?? 3; // TIWSHOP: ค่าเริ่มต้น = เขียวนีออน
      themeIdx = (v >= 0 && v < kThemes.length) ? v : 0;
      final b = p.getInt('bg') ?? 0;
      bgIdx = (b >= 0 && b < kBgs.length) ? b : 0;
      shift = (p.getInt('shift') ?? 10000).clamp(1000, 15000).toInt();
      tempWarn = (p.getInt('tempWarn') ?? 105).clamp(60, 150).toInt();
      speedGps = p.getBool('speedGps') ?? true;
      graphOn = (p.getInt('gon') ?? 15) & 15;
      main = _parse(p.getString('main'), 7) ?? main;
      grid = _parse(p.getString('grid'), 12) ?? grid;
      ctr = _parse(p.getString('ctr'), 2) ?? ctr;
      dash = _parse(p.getString('dash'), 7) ?? dash;
    } catch (_) {}
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('theme', themeIdx);
      await p.setInt('bg', bgIdx);
      await p.setInt('shift', shift);
      await p.setInt('tempWarn', tempWarn);
      await p.setBool('speedGps', speedGps);
      await p.setInt('gon', graphOn);
      await p.setString('main', main.join(','));
      await p.setString('grid', grid.join(','));
      await p.setString('ctr', ctr.join(','));
      await p.setString('dash', dash.join(','));
    } catch (_) {}
  }

  Future<void> setTheme(int v) {
    themeIdx = v;
    return _save();
  }

  Future<void> setBg(int v) {
    bgIdx = v;
    return _save();
  }

  Future<void> addShift(int d) {
    shift = (shift + d).clamp(1000, 15000).toInt();
    return _save();
  }

  Future<void> addTemp(int d) {
    tempWarn = (tempWarn + d).clamp(60, 150).toInt();
    return _save();
  }

  Future<void> toggleGraph(int i) {
    graphOn ^= (1 << i);
    return _save();
  }

  Future<void> toggleSpeed() {
    speedGps = !speedGps;
    return _save();
  }

  Future<void> setSpeedGps(bool v) {
    speedGps = v;
    return _save();
  }

  Future<void> setSlot(List<int> arr, int idx, int key) {
    final j = arr.indexOf(key);
    if (j >= 0 && j != idx) arr[j] = arr[idx]; // ถ้าค่านี้อยู่ช่องอื่นแล้ว ให้สลับกัน (เหมือน TEST1)
    arr[idx] = key;
    return _save();
  }
}

// ---------- DRAG LOG ----------
enum DragSt { ready, run, done }

class DragRun {
  List<double?> t = List<double?>.filled(4, null); // เวลา (วินาที) ที่ 201 / 402 / 500 / 1000 m
  List<double?> v = List<double?>.filled(4, null); // ความเร็ว (km/h) ที่ระยะนั้น
  double maxKmh = 0;
  bool get hasData => t[0] != null || maxKmh > 0;
  void clear() {
    t = List<double?>.filled(4, null);
    v = List<double?>.filled(4, null);
    maxKmh = 0;
  }

  Map<String, dynamic> toJson() => {'t': t, 'v': v, 'm': maxKmh};

  static DragRun fromJson(dynamic j) {
    final r = DragRun();
    try {
      final tt = (j['t'] as List), vv = (j['v'] as List);
      for (int i = 0; i < 4; i++) {
        r.t[i] = (tt[i] as num?)?.toDouble();
        r.v[i] = (vv[i] as num?)?.toDouble();
      }
      r.maxKmh = (j['m'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    return r;
  }
}

// ---------- ข้อมูลจาก ESP32 ----------
class Telemetry {
  final bool fresh;
  final int state, proto, bike, img;
  final double? rpm, speed, ect, iat, eot, tps, map, batt, afr, ign, inj, o2v, stft, ltft;
  final int? fwMaj, fwMin, fwPatch; // เวอร์ชันเฟิร์มแวร์เกจ (null = เฟิร์มแวร์เก่าที่ยังไม่ส่งเวอร์ชัน)
  // DTC จากเกจ (FTP FW 1.0.0, ไบต์ 34..70): dtcSup = เกจรองรับ, dtcValid = ผลอ่านใช้ได้, dtcClear 0 ว่าง 1 กำลังลบ 2 สำเร็จ 3 ไม่สำเร็จ
  final bool dtcSup, dtcValid;
  final int dtcClear;
  final List<List<int>> dtcCur, dtcSto; // [code, sub]
  // เขียนไฟล์ ECU (FW 1.3.0, ไบต์ 75..78): flashState 0 ว่าง..7, flashPct, flashVendorDet 1 Keihin 2 Shin, fileRx 0 ว่าง 1 รับ 2 สำเร็จ 3 ผิด
  final int flashState, flashPct, flashVendor, fileRx;
  final bool flashSup; // เฟิร์มแวร์รองรับการเขียนไฟล์ (แพ็กเกจยาว >= 79 ไบต์)
  final String? ecmId; // รหัส ECM 5 ไบต์ (hex) จากกล่องที่ต่ออยู่ (แพ็กเกจ >= 84)
  EcuInfo? get ecu => ecuLookup(ecmId);
  Telemetry({
    this.fresh = false, this.state = 0, this.proto = 0, this.bike = 0, this.img = 0,
    this.rpm, this.speed, this.ect, this.iat, this.eot, this.tps, this.map,
    this.batt, this.afr, this.ign, this.inj, this.o2v, this.stft, this.ltft,
    this.fwMaj, this.fwMin, this.fwPatch,
    this.dtcSup = false, this.dtcValid = false, this.dtcClear = 0, this.dtcCur = const [], this.dtcSto = const [],
    this.flashState = 0, this.flashPct = 0, this.flashVendor = 0, this.fileRx = 0, this.flashSup = false,
    this.ecmId,
  });
  String? get fwText => fwMaj == null ? null : '$fwMaj.$fwMin.$fwPatch';

  static Telemetry? parse(List<int> b) {
    if (b.length < 34 || b[0] != 1) return null;
    final d = ByteData.sublistView(Uint8List.fromList(b));
    double? f(int off, double k) {
      final v = d.getInt16(off, Endian.little);
      return v == 0x7FFF ? null : v / k;
    }

    final hasDtc = b.length >= 75 && b[34] == 1;
    final nc = hasDtc ? math.min(b[37], 16) : 0;
    final ns = hasDtc ? math.min(b[38], 16 - nc) : 0;
    return Telemetry(
      dtcSup: hasDtc, dtcValid: hasDtc && (b[35] & 1) != 0, dtcClear: hasDtc ? b[36] : 0,
      dtcCur: [for (int i = 0; i < nc; i++) [b[39 + i * 2], b[40 + i * 2]]],
      dtcSto: [for (int i = 0; i < ns; i++) [b[39 + (nc + i) * 2], b[40 + (nc + i) * 2]]],
      state: b[1], proto: b[2], fresh: (b[3] & 1) != 0, bike: b[4], img: b[5],
      rpm: f(6, 1), speed: f(8, 10), ect: f(10, 10), iat: f(12, 10),
      eot: f(14, 10), tps: f(16, 10), map: f(18, 10), batt: f(20, 100),
      afr: f(22, 100), ign: f(24, 10), inj: f(26, 100), o2v: f(28, 1000),
      stft: f(30, 1000), ltft: f(32, 1000),
      fwMaj: b.length >= 75 ? b[72] : null,
      fwMin: b.length >= 75 ? b[73] : null,
      fwPatch: b.length >= 75 ? b[74] : null,
      flashSup: b.length >= 79,
      flashState: b.length >= 79 ? b[75] : 0,
      flashPct: b.length >= 79 ? b[76] : 0,
      flashVendor: b.length >= 79 ? b[77] : 0,
      fileRx: b.length >= 79 ? b[78] : 0,
      ecmId: (b.length >= 84 && (b[79] | b[80] | b[81] | b[82] | b[83]) != 0)
          ? b.sublist(79, 84).map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase()
          : null,
    );
  }
}

enum LinkState { idle, scanning, connecting, connected }

// ---------- ตัวจัดการ BLE + GPS + Demo ----------
class GaugeController extends ChangeNotifier {
  // TIWSHOP: แจ้งหน้าจอไม่เกิน ~30 ครั้ง/วินาที (เดิมแจ้งทุกแพ็กเกจ BLE + GPS + ดาวเทียม + DEMO = วาดทั้งหน้าซ้ำถี่เกิน -> แอพหน่วง/ค้าง)
  static const int _uiMinMs = 33;
  int _lastNotifyMs = 0;
  Timer? _notifyTimer;
  bool _disposed = false;

  void _notifyNow() {
    _notifyTimer = null;
    if (_disposed) return;
    _lastNotifyMs = DateTime.now().millisecondsSinceEpoch;
    super.notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed || _notifyTimer != null) return; // มีรอบวาดรออยู่แล้ว: ค่าใหม่จะไปพร้อมรอบนั้น
    final wait = _uiMinMs - (DateTime.now().millisecondsSinceEpoch - _lastNotifyMs);
    if (wait <= 0) {
      _notifyNow();
    } else {
      _notifyTimer = Timer(Duration(milliseconds: wait), _notifyNow);
    }
  }

  Telemetry t = Telemetry();
  LinkState link = LinkState.idle;
  bool demo = false;
  bool gpsOk = false;
  double? gpsSpeed; // km/h — ค่าที่โชว์ (เลื่อนนุ่มระหว่างจุด GPS)
  double? gpsRaw;   // km/h — ค่าที่วัดได้จริง (ผ่านตัวกรองแล้ว) ใช้บันทึกความเร็วสูงสุด/DRAG
  double _gFrom = 0, _gTo = 0;
  int _gT0 = 0, _gDur = 1000, _gPrevFixMs = 0, _gSpikeN = 0, _gMoveN = 0;
  double? _gLastV;                         // ค่าก่อนหน้า (ใช้กันค่ากระโดด)
  bool _gMoving = false;                   // ยืนยันแล้วว่ารถเคลื่อนที่จริง
  final List<List<double>> _gHist = [];    // [ms, lat, lon, km/h] ย้อนหลัง ~4 วินาที (ตรวจ GPS ลอยตอนจอดนิ่ง)
  Timer? _gpsAnim;
  double topSpeed = 0;
  final Map<String, List<double>> mm = {}; // ต่ำสุด/สูงสุดของแต่ละค่า
  String? error;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd, _imgCh, _fileCh;
  bool _fileBusy = false;
  StreamSubscription? _scanSub, _dataSub, _connSub, _gpsSub, _gnssSub;
  static const EventChannel _gnss = EventChannel('mfb/gnss'); // จำนวนดาวเทียมจริงจาก Android (MainActivity.kt ที่ workflow เติมให้)
  Timer? _demoTimer, _retryTimer, _gpsWatch;
  bool _auto = false;
  String? gaugeId, gaugeName; // เกจที่เลือกไว้ (ต่อใหม่อัตโนมัติเฉพาะตัวนี้ ไม่ไปต่อเกจคันอื่น)
  int _gpsSentMs = 0, _gpsLastMs = 0;
  bool _logoBusy = false;

  // ----- หน้า GRAPH: เก็บย้อนหลัง 60 วินาที (300 ตัวอย่าง ทุก 200 ms) + MIN/MAX ของ RPM / TPS / GPS / AFR -----
  // ----- สถานะ GPS / DRAG LOG -----
  int? satUsed, satTotal; // จำนวนดาวเทียมที่ใช้คำนวณตำแหน่ง / จำนวนที่เห็นทั้งหมด (อ่านจริงจาก Android GNSS)
  int satMax = 0; // จำนวนมากสุดที่เครื่องนี้เคยจับได้
  double? gpsAccM, spdAccKmh; // ความแม่นยำตำแหน่ง (m) / ความเร็ว (km/h)
  bool _gpsTrust = false;     // fix ปัจจุบันแม่นพอให้บันทึกค่าสูงสุดไหม (รัศมี ≤25 ม. และความเร็ว ±≤4 กม./ชม.)
  static const List<double> dragDist = [201, 402, 500, 1000];
  final List<DragRun> runs = List.generate(3, (_) => DragRun());
  int dragSel = 0;
  DragSt dragSt = DragSt.ready;
  double dragMeters = 0, dragSecs = 0;
  DateTime? _dTs;
  double _dPrev = 0, _dDist = 0, _dT = 0;
  int _dStill = 0;

  // ----- นาฬิกาจับเวลาแบบวิ่งจริง (ไม่ค้างรอ GPS) -----
  /// ความเร็วที่ถือว่า "ออกตัว" (เริ่มจับเวลาเมื่อความเร็วผ่านค่านี้ขึ้นไป)
  static const double dragStartKmh = 5.0;
  /// เวลาที่แสดงบนนาฬิกา (วินาที) อัปเดต ~60 ครั้ง/วินาที เฉพาะตัวเลขนาฬิกา ไม่วาดทั้งหน้าใหม่
  final ValueNotifier<double> dragClock = ValueNotifier<double>(0);
  final Stopwatch _dSw = Stopwatch(); // นาฬิกาเครื่อง (monotonic) ใช้แสดงเวลาวิ่งระหว่างรอค่า GPS ถัดไป
  double _dSwOffset = 0; // เวลาที่ผ่านไปแล้วตั้งแต่จุดออกตัว ณ ตอนเริ่ม stopwatch
  Timer? _dTick;
  double? _rPrevKmh; // ค่า GPS ก่อนหน้าในสถานะ READY (ใช้หาจังหวะผ่าน 5 km/h)
  DateTime? _rPrevTs;

  /// พร้อมออกตัว = ค่าล่าสุดยังต่ำกว่า 5 km/h (ถ้ากำลังวิ่งอยู่แล้วต้องชะลอให้ต่ำกว่า 5 ก่อน)
  bool get dragArmed => _rPrevKmh != null && _rPrevKmh! < dragStartKmh;

  void _clockStart(double elapsedAtStart) {
    _dSwOffset = elapsedAtStart;
    _dSw
      ..reset()
      ..start();
    _dTick?.cancel();
    _dTick = Timer.periodic(const Duration(milliseconds: 16), (_) {
      dragClock.value = _dSwOffset + _dSw.elapsedMicroseconds / 1e6;
    });
    dragClock.value = elapsedAtStart;
  }

  void _clockStop(double finalSecs) {
    _dTick?.cancel();
    _dTick = null;
    _dSw.stop();
    dragClock.value = finalSecs;
  }

  bool get dragFull => runs[dragSel].hasData && dragSt != DragSt.run;

  Future<void> _dragLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      satMax = p.getInt('satMax') ?? 0;
      final sv = p.getString('drag');
      if (sv != null) {
        final l = jsonDecode(sv) as List;
        for (int i = 0; i < 3 && i < l.length; i++) {
          runs[i] = DragRun.fromJson(l[i]);
        }
      }
      dragSel = runs.indexWhere((r) => !r.hasData);
      if (dragSel < 0) dragSel = 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveSatMax() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('satMax', satMax);
    } catch (_) {}
  }

  void _startGnss() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _gnssSub?.cancel();
    _gnssSub = _gnss.receiveBroadcastStream().listen((e) {
      if (demo) return; // DEMO จำลองดาวเทียมเอง
      if (e is Map) {
        satUsed = (e['used'] as num?)?.toInt();
        satTotal = (e['visible'] as num?)?.toInt();
        if (satTotal != null && satTotal! > satMax) {
          satMax = satTotal!;
          _saveSatMax();
        }
        notifyListeners();
      }
    }, onError: (_) {});
  }

  Future<void> _dragSave() async {
    if (demo) return; // รอบที่วิ่งใน DEMO ไม่บันทึกทับ LOG จริง
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('drag', jsonEncode(runs.map((r) => r.toJson()).toList()));
    } catch (_) {}
  }

  void selectRun(int i) {
    if (dragSt == DragSt.run) return;
    dragSel = i;
    notifyListeners();
  }

  /// ล้าง LOG ทั้ง 3 RUN (ค่าจะไม่ถูกลบจนกว่าจะกดปุ่มนี้)
  void resetDragLog() {
    for (final r in runs) {
      r.clear();
    }
    dragSel = 0;
    dragSt = DragSt.ready;
    dragMeters = 0;
    dragSecs = 0;
    _clockStop(0);
    _dragSave();
    notifyListeners();
  }

  void _dragFinish() {
    final run = runs[dragSel];
    final fin = run.t[3] ?? _dT; // ถึง 1000 m = เวลาที่ 1000 m พอดี, หยุดก่อน = เวลาล่าสุด
    dragSecs = fin;
    _clockStop(run.t[0] == null ? 0 : fin);
    if (run.t[0] == null) {
      run.clear(); // ยังไม่ถึงระยะแรก = ยกเลิก ไม่บันทึก
    } else {
      _dragSave();
      final nxt = runs.indexWhere((r) => !r.hasData);
      if (nxt >= 0) dragSel = nxt; // ขยับไป RUN ว่างถัดไป
    }
    dragSt = DragSt.done;
  }

  /// เรียกทุกครั้งที่ได้ค่า GPS ใหม่ : จับเวลา/ระยะจากความเร็ว GPS (ประมาณค่า เพื่อจัดหน้าตาก่อน)
  void _dragUpdate(double kmh, DateTime ts) {
    final run = runs[dragSel];
    switch (dragSt) {
      case DragSt.ready:
        final pv = _rPrevKmh, pt = _rPrevTs;
        if (!run.hasData && pv != null && pt != null && pv < dragStartKmh && kmh >= dragStartKmh) {
          // จังหวะผ่าน 5 km/h อยู่ระหว่างค่าก่อนหน้ากับค่านี้ -> ประมาณเวลาจริงด้วยเส้นตรง
          final gap = ts.difference(pt).inMicroseconds / 1e6;
          final f = (kmh - pv) <= 0 ? 1.0 : ((dragStartKmh - pv) / (kmh - pv)).clamp(0.0, 1.0).toDouble();
          final since = (gap > 0 && gap < 2.0) ? (1 - f) * gap : 0.0; // เวลาตั้งแต่จุดออกตัวถึงค่านี้
          dragSt = DragSt.run;
          _dT = since;
          _dDist = (dragStartKmh + kmh) / 2 / 3.6 * since;
          _dTs = ts;
          _dPrev = kmh;
          _dStill = 0;
          run.clear();
          run.maxKmh = kmh;
          dragMeters = _dDist;
          dragSecs = _dT;
          // ค่า GPS มาถึงแอพช้ากว่าเวลาจริงของจุดนั้นเล็กน้อย -> ชดเชยให้นาฬิกาเริ่มตรงเวลา (จำกัดไม่เกิน 1 วินาที กันนาฬิกาเครื่อง/GPS ไม่ตรงกัน)
          final lag = DateTime.now().difference(ts).inMicroseconds / 1e6;
          _clockStart(since + ((lag > 0 && lag < 1.0) ? lag : 0.0));
        }
        _rPrevKmh = kmh;
        _rPrevTs = ts;
        break;
      case DragSt.run:
        final dt = ts.difference(_dTs ?? ts).inMicroseconds / 1e6;
        if (dt <= 0) break;
        final d = (_dPrev / 3.6 + kmh / 3.6) / 2 * dt;
        final d0 = _dDist, t0 = _dT;
        _dDist += d;
        _dT += dt;
        for (int k = 0; k < 4; k++) {
          if (run.t[k] == null && _dDist >= dragDist[k]) {
            final f = d <= 0 ? 1.0 : ((dragDist[k] - d0) / d).clamp(0.0, 1.0).toDouble();
            run.t[k] = t0 + f * dt;
            run.v[k] = _dPrev + f * (kmh - _dPrev);
          }
        }
        if (kmh > run.maxKmh) run.maxKmh = kmh;
        _dTs = ts;
        _dPrev = kmh;
        dragMeters = _dDist;
        dragSecs = _dT;
        if (run.t[3] != null) {
          _dragFinish();
        } else if (kmh < 2) {
          if (++_dStill >= 3) _dragFinish();
        } else {
          _dStill = 0;
        }
        break;
      case DragSt.done:
        if (kmh < 2) {
          dragSt = DragSt.ready; // หยุดนิ่งแล้ว พร้อมรอบถัดไป
          _rPrevKmh = kmh;
          _rPrevTs = ts;
        }
        break;
    }
  }

  static const int gN = 300;
  final List<List<double>> gHist = List.generate(4, (_) => <double>[]);
  final List<double?> gMin = List<double?>.filled(4, null);
  final List<double?> gMax = List<double?>.filled(4, null);
  bool graphVisible = false;
  Timer? _gTimer;

  double? gVal(int i) {
    final live = t.fresh || demo;
    switch (i) {
      case 0: return live ? t.rpm : null;
      case 1: return live ? t.tps : null;
      case 2: return demo ? t.speed : (gpsOk ? gpsSpeed : null);
      default: return live ? t.afr : null;
    }
  }

  void _gSample() {
    for (int i = 0; i < 4; i++) {
      final v = gVal(i);
      final h = gHist[i];
      h.add(v ?? double.nan);
      if (h.length > gN) h.removeAt(0);
      if (v != null) {
        if (gMin[i] == null || v < gMin[i]!) gMin[i] = v;
        if (gMax[i] == null || v > gMax[i]!) gMax[i] = v;
      }
    }
    if (graphVisible) notifyListeners();
  }

  bool get ecuLive => link == LinkState.connected && t.fresh;

  /// ความเร็วกลางเกจ: สลับโหมด GPS / ECU ได้ (แตะที่ตัวเลขความเร็ว)
  double? get shownSpeed => demo ? t.speed : (Cfg.i.speedGps ? (gpsOk ? gpsSpeed : null) : t.speed);
  String get speedSrc => Cfg.i.speedGps ? 'GPS' : 'ECU';

  double? keyVal(int k) {
    switch (k) {
      case kTps: return t.tps;
      case kTemp: return t.ect;
      case kBatt: return t.batt;
      case kAfr: return t.afr;
      case kInj: return t.inj;
      case kIgn: return t.ign;
      case kRpm: return t.rpm;
      case kMap: return t.map;
      case kSpd: return shownSpeed;
      case kEot: return t.eot;
      case kIat: return t.iat;
      case kO2: return t.o2v;
      case kStft: return t.stft;
      case kLtft: return t.ltft;
      case kTop: return topSpeed;
    }
    return null;
  }

  Future<void> init() async {
    await WakelockPlus.enable();
    _gTimer?.cancel();
    _gTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _gSample());
    _dragLoad();
    await _startGps();
  }

  Future<void> _startGps() async {
    try {
      final perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      _startGnss();
      // Android: ใช้ GPS ตรง (LocationManager) และขอทุก 200 ms -> ได้ความเร็วเร็วที่สุดเท่าที่ชิป GPS ให้ (ปกติ ~1 Hz ขึ้นไป)
      final LocationSettings ls = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
              intervalDuration: const Duration(milliseconds: 200),
              forceLocationManager: true,
            )
          : (defaultTargetPlatform == TargetPlatform.iOS
              ? AppleSettings(
                  accuracy: LocationAccuracy.bestForNavigation,
                  activityType: ActivityType.automotiveNavigation,
                  distanceFilter: 0,
                  pauseLocationUpdatesAutomatically: false,
                )
              : const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0));
      _gpsSub = Geolocator.getPositionStream(locationSettings: ls).listen((p) {
        if (demo) return; // DEMO ใช้ GPS จำลอง (ไม่ให้ GPS จริงที่จอดนิ่งมาทับ)
        final now = DateTime.now().millisecondsSinceEpoch;
        gpsOk = true;
        _gpsLastMs = now;
        gpsAccM = p.accuracy;
        final saKmh = p.speedAccuracy > 0 ? p.speedAccuracy * 3.6 : 0.0;
        spdAccKmh = saKmh > 0 ? saKmh : null;
        // ความเร็วจากดอปเปลอร์ของชิป GPS (แม่นกว่าคำนวณจากระยะ) ; ค่าติดลบ = ชิปไม่บอก
        double v = p.speed < 0 ? 0.0 : p.speed * 3.6;
        // จอดนิ่ง: GPS แกว่ง 0-3 กม./ชม. -> ตัดเป็น 0
        if (v < 2.5 || (saKmh > 0 && v < saKmh && v < 8)) v = 0;
        // กันค่ากระโดด: รถเร่ง/เบรกจริงไม่เกิน ~1.2g (≈43 กม./ชม. ต่อวินาที) ; โดดเกินติดกัน 3 ครั้ง = ของจริง (เช่นออกจากอุโมงค์)
        final dt = _gPrevFixMs == 0 ? 1.0 : ((now - _gPrevFixMs) / 1000.0).clamp(0.05, 5.0).toDouble();
        bool spike = false;
        final prev = _gLastV;
        if (prev != null) {
          final maxStep = 43.0 * dt + 3.0;
          if ((v - prev).abs() > maxStep) {
            if (++_gSpikeN < 3) {
              spike = true;
              v = prev + (v > prev ? maxStep : -maxStep);
            } else {
              _gSpikeN = 0;
            }
          } else {
            _gSpikeN = 0;
          }
        }
        final interval = _gPrevFixMs == 0 ? 1000 : (now - _gPrevFixMs).clamp(80, 1500).toInt();
        _gPrevFixMs = now;
        _gLastV = v;
        // ---- จอดนิ่งแต่ GPS ลอย (ในอาคาร/ใต้หลังคา สัญญาณสะท้อน) -> ต้องโชว์ 0 ----
        double vs = v;
        // 1) ความเร็วต่ำกว่าความคลาดเคลื่อนที่ชิปบอก = เชื่อไม่ได้
        if (saKmh > 0 && vs < saKmh * 1.5) vs = 0;
        // 2) ตำแหน่งไม่แม่น (รัศมี >20 ม.) แล้วความเร็วต่ำ = มักเป็นค่าลอย
        if (p.accuracy > 20 && vs < 15) vs = 0;
        // 3) เทียบระยะที่ "ควรไป" ตามความเร็ว กับระยะที่ตำแหน่งย้ายจริงใน ~4 วินาที : ลอยอยู่กับที่ = ตำแหน่งไม่ไปไหน
        _gHist.add([now.toDouble(), p.latitude, p.longitude, v]);
        while (_gHist.length > 2 && now - _gHist.first[0] > 4000) { _gHist.removeAt(0); }
        if (vs > 0 && _gHist.length >= 3 && now - _gHist.first[0] >= 2500) {
          double want = 0;
          for (int i = 1; i < _gHist.length; i++) {
            want += _gHist[i][3] / 3.6 * ((_gHist[i][0] - _gHist[i - 1][0]) / 1000.0);
          }
          final got = Geolocator.distanceBetween(_gHist.first[1], _gHist.first[2], _gHist.last[1], _gHist.last[2]);
          if (want >= 6 && got < want * 0.45) vs = 0;
        }
        // 4) จาก 0 ต้องได้ค่าวิ่งติดกัน 2 ครั้งก่อน ถึงจะเริ่มโชว์ความเร็ว (กันค่าลอยครั้งเดียว)
        if (vs > 0) {
          if (!_gMoving && ++_gMoveN >= 2) _gMoving = true;
        } else {
          _gMoving = false;
          _gMoveN = 0;
        }
        if (!_gMoving) vs = 0;
        gpsRaw = vs;
        // บันทึกค่าสูงสุดเฉพาะจุดที่แม่นพอ: รัศมี ≤30 ม. และความเร็ว ±≤9 กม./ชม. (ค่า ≤0 = ชิปไม่บอก ให้ผ่าน) และไม่ใช่ค่ากระโดด
        final accOk = p.accuracy <= 0 || p.accuracy <= 30;
        final spdOk = saKmh <= 0 || saKmh <= 9;
        _gpsTrust = accOk && spdOk && !spike && _gMoving;
        // ตัวเลขบนจอ: เลื่อนจากค่าที่โชว์อยู่ไปค่าใหม่แบบต่อเนื่องภายในช่วงเวลาระหว่างจุด GPS (ไม่โดดทีละขั้น)
        _gFrom = gpsSpeed ?? vs;
        _gTo = vs;
        _gT0 = now;
        _gDur = math.max(60, (interval * 0.9).round());
        _gpsAnimStart();
        _dragUpdate(v, p.timestamp);
        _track();
        _sendGps();
        notifyListeners();
      }, onError: (_) {
        gpsOk = false;
        notifyListeners();
      });
      // ถ้าไม่มีข้อมูล GPS เกิน 4 วินาที ถือว่าสัญญาณหาย
      _gpsWatch?.cancel();
      _gpsWatch = Timer.periodic(const Duration(seconds: 1), (_) {
        if (gpsOk && DateTime.now().millisecondsSinceEpoch - _gpsLastMs > 4000) {
          gpsOk = false;
          if (dragSt == DragSt.run) {
            _dragFinish(); // สัญญาณ GPS หายกลางรอบ: หยุดนาฬิกา เก็บช่วงที่วัดได้
          }
          _rPrevKmh = null; // ต้องได้ค่าต่ำกว่า 5 km/h ใหม่ก่อนออกตัวรอบถัดไป
          gpsRaw = null; // สัญญาณกลับมาใหม่ ไม่เทียบกับค่าเก่า
          _gLastV = null;
          _gPrevFixMs = 0;
          _gSpikeN = 0;
          _gMoving = false;
          _gMoveN = 0;
          _gHist.clear();
          notifyListeners();
        }
      });
    } catch (_) {}
  }

  /// อัปเดตตัวเลขความเร็วบนจอ ~30 ครั้ง/วินาที ระหว่างจุด GPS (ชิป GPS มือถือส่วนใหญ่ให้ค่าแค่ 1 ครั้ง/วินาที)
  void _gpsAnimStart() {
    _gpsAnim ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (demo || !gpsOk) {
        _gpsAnim?.cancel();
        _gpsAnim = null;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final f = ((now - _gT0) / _gDur).clamp(0.0, 1.0).toDouble();
      final nv = _gFrom + (_gTo - _gFrom) * f;
      final cur = gpsSpeed;
      if (cur == null || (nv - cur).abs() > 0.02) {
        gpsSpeed = nv;
        _sendGps();
        notifyListeners();
      }
    });
  }

  /// ส่งความเร็ว GPS ไปบอร์ด TEST1: [3][u16 km/h x10] (ไม่รอตอบกลับ เพื่อให้เร็ว)
  void _sendGps() {
    final c = _cmd;
    final sp = gpsSpeed;
    if (demo || link != LinkState.connected || c == null || _logoBusy || sp == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _gpsSentMs < 120) return;
    _gpsSentMs = now;
    final v = (sp * 10).round().clamp(0, 65534).toInt();
    try {
      c.write([3, v & 255, (v >> 8) & 255], withoutResponse: c.properties.writeWithoutResponse).catchError((_) {});
    } catch (_) {}
  }

  void _mmUpdate(String k, double? v, {bool skipZero = false}) {
    if (v == null) return;
    if (skipZero && v <= 0) return;
    final cur = mm[k];
    if (cur == null) {
      mm[k] = [v, v];
    } else {
      if (v < cur[0]) cur[0] = v;
      if (v > cur[1]) cur[1] = v;
    }
  }

  // ยังไม่มีค่า / เพิ่งรีเซ็ต -> แสดง 0 (ไม่ซ่อน)
  String mnStr(String k) => mm[k] == null ? '0' : mm[k]![0].toStringAsFixed(0);
  String mxStr(String k) => mm[k] == null ? '0' : mm[k]![1].toStringAsFixed(0);

  // ----- หน้า TOP SPEED: ความเร็วสูงสุด (GPS ก่อน ไม่มีใช้ ECU) + RPM/AFR/เวลา ณ จังหวะนั้น -----
  double tsBest = 0;
  double? tsRpm, tsAfr;
  DateTime? tsAt;
  double? get tsNow => (demo || gpsOk) ? gpsRaw : null; // ค่าที่วัดจริง (ไม่ใช่ค่าที่เลื่อนบนจอ)   // วัดจาก GPS โทรศัพท์โดยตรง ไม่พึ่ง ECU
  String get tsSrc => (demo || gpsOk) ? 'GPS' : '--';
  /// ปุ่ม CLEAR หน้า TOP SPEED: ล้างความเร็วสูงสุดทุกหน้า (TOP SPEED, ช่อง TOP SPD, หน้า DASH)
  void tsClear() {
    tsBest = 0; tsRpm = null; tsAfr = null; tsAt = null;
    topSpeed = 0;
    notifyListeners();
  }

  void _track() {
    final gpsTrust = demo || _gpsTrust;             // ยอมรับเฉพาะ fix ที่แม่น จะได้ไม่บันทึกค่าสูงสุดหลอกจาก GPS กระตุก
    final sIsGps = demo || Cfg.i.speedGps;          // ความเร็วหลักมาจาก GPS หรือไม่
    final s = (sIsGps && !demo) ? (gpsOk ? gpsRaw : null) : shownSpeed;
    if (s != null && s > topSpeed && (!sIsGps || gpsTrust)) topSpeed = s;
    final ts = tsNow;
    if (ts != null && ts >= 1 && ts > tsBest && gpsTrust) {
      tsBest = ts;
      final live = demo || ecuLive;
      tsRpm = live ? t.rpm : null;
      tsAfr = live ? t.afr : null;
      tsAt = DateTime.now();
    }
    if (t.fresh || demo) {
      _mmUpdate('rpm', t.rpm, skipZero: true);
    }
  }

  void resetMinMax() {
    topSpeed = 0;
    tsBest = 0; tsRpm = null; tsAfr = null; tsAt = null;
    mm.clear();
    for (int i = 0; i < 4; i++) {
      gMin[i] = null;
      gMax[i] = null;
    }
    notifyListeners();
  }

  // ----- BLE -----
  /// ขอสิทธิ์ + เปิดบลูทูธ + โหลดเกจที่เคยเลือก ; true = พร้อมสแกน
  Future<bool> prepareBle() async {
    if (demo) toggleDemo();
    error = null;
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }
    if (gaugeId == null) {
      try {
        final p = await SharedPreferences.getInstance();
        gaugeId = p.getString('gauge_id');
        gaugeName = p.getString('gauge_name');
      } catch (_) {}
    }
    return await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
  }

  /// สแกนหาเกจทุกตัวให้หน้าต่างเลือก (ผลอยู่ใน FlutterBluePlus.scanResults)
  Future<void> startPickScan() async {
    _retryTimer?.cancel();
    _auto = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await FlutterBluePlus.startScan(withServices: [kSvc], timeout: const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> stopPickScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// ต่อกับเกจที่ผู้ใช้เลือก แล้วจำไว้
  Future<void> connectTo(BluetoothDevice dev, String name) async {
    await stopPickScan();
    gaugeId = dev.remoteId.str;
    gaugeName = name;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('gauge_id', gaugeId!);
      await p.setString('gauge_name', name);
    } catch (_) {}
    _auto = true;
    error = null;
    await _open(dev);
  }

  /// ต่อใหม่อัตโนมัติ (หลุดเอง): หาเฉพาะเกจตัวที่เลือกไว้
  Future<void> _scanAndConnect() async {
    if (!_auto || gaugeId == null) return;
    link = LinkState.scanning;
    notifyListeners();
    await _scanSub?.cancel();
    final done = Completer<BluetoothDevice?>();
    _scanSub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        if (r.device.remoteId.str == gaugeId && !done.isCompleted) done.complete(r.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: [kSvc], timeout: const Duration(seconds: 8));
    } catch (_) {}
    final dev = await done.future.timeout(const Duration(seconds: 9), onTimeout: () => null);
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    if (dev == null) {
      error = 'ไม่พบ ${gaugeName ?? 'เกจ'}';
      link = LinkState.idle;
      notifyListeners();
      _scheduleRetry();
      return;
    }
    await _open(dev);
  }

  Future<void> _open(BluetoothDevice dev) async {
    try {
      link = LinkState.connecting;
      notifyListeners();
      _dev = dev;
      await dev.connect(timeout: const Duration(seconds: 10));
      try {
        await dev.requestMtu(185);
      } catch (_) {}
      // TIWSHOP: ขอช่วงเชื่อมต่อ BLE แบบเร็ว (Android) -> ค่าจากเกจมาถึงทันที ไม่ดีเลย์
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await dev.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
        } catch (_) {}
      }
      final services = await dev.discoverServices();
      final svc = services.firstWhere((s) => s.uuid == kSvc);
      final data = svc.characteristics.firstWhere((c) => c.uuid == kData);
      _cmd = svc.characteristics.firstWhere((c) => c.uuid == kCmd);
      _imgCh = null;
      _fileCh = null;
      for (final c in svc.characteristics) {
        if (c.uuid == kImg) _imgCh = c;
        if (c.uuid == kFile) _fileCh = c;
      }
      await data.setNotifyValue(true);
      await _dataSub?.cancel();
      _dataSub = data.onValueReceived.listen((v) {
        if (demo) return; // DEMO เปิดอยู่: ไม่เอาค่าจากบอร์ดมาทับ
        final p = Telemetry.parse(v);
        if (p != null) {
          t = p;
          _dtcTrack();
          _track();
          notifyListeners();
        }
      });
      await _connSub?.cancel();
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          link = LinkState.idle;
          t = Telemetry();
          notifyListeners();
          _scheduleRetry();
        }
      });
      link = LinkState.connected;
      notifyListeners();
      if (_dtcWanted) dtcRead(); // เปิดหน้า DTC ค้างไว้ตอนต่อ -> สั่งอ่านทันที
    } catch (e) {
      error = 'เชื่อมต่อไม่สำเร็จ';
      link = LinkState.idle;
      notifyListeners();
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_auto) _retryTimer = Timer(const Duration(seconds: 3), _scanAndConnect);
  }

  Future<void> disconnect() async {
    _auto = false;
    _retryTimer?.cancel();
    await _dataSub?.cancel();
    await _connSub?.cancel();
    try {
      await _dev?.disconnect();
    } catch (_) {}
    link = LinkState.idle;
    t = Telemetry();
    notifyListeners();
  }

  // ---- DTC (หน้า DTC): อ่าน/ลบโค้ดผ่านเกจ ----
  bool _dtcWanted = false;      // หน้า DTC เปิดอยู่ -> ให้เกจอ่าน DTC ต่อเนื่อง
  bool dtcReading = false;      // กด "อ่านโค้ด" แล้ว รอผลรอบใหม่
  bool _dtcSawInvalid = false;
  int _dtcReqMs = 0;
  DateTime? dtcLastRead;
  void dtcWatch(bool on) {
    if (_dtcWanted == on) return;
    _dtcWanted = on;
    if (on) {
      dtcRead();
    } else if (link == LinkState.connected) {
      sendCmd([4, 0]);
    }
  }

  void dtcRead() {
    if (link != LinkState.connected) return;
    dtcReading = true;
    _dtcSawInvalid = false;
    _dtcReqMs = DateTime.now().millisecondsSinceEpoch;
    sendCmd([4, 2]);
    notifyListeners();
  }

  void dtcClear() {
    if (link != LinkState.connected) return;
    sendCmd([1]);
  }

  void _dtcTrack() {
    if (!t.dtcSup) return;
    if (dtcReading) {
      if (!t.dtcValid) {
        _dtcSawInvalid = true;
      } else if (_dtcSawInvalid) {
        dtcReading = false;
        dtcLastRead = DateTime.now();
      }
      if (DateTime.now().millisecondsSinceEpoch - _dtcReqMs > 9000) dtcReading = false;
    } else if (dtcLastRead == null && t.dtcValid) {
      dtcLastRead = DateTime.now();
    }
  }

  Future<void> sendCmd(List<int> bytes) async {
    try {
      await _cmd?.write(bytes, withoutResponse: false);
    } catch (_) {}
  }

  /// ส่งโลโก้ 320x240 RGB565 (153600 ไบต์) ไปเก็บในบอร์ด คืนค่า null = สำเร็จ, ข้อความ = error
  Future<String?> sendLogo(Uint8List data, void Function(double) onProgress) async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected || _dev == null) {
      return 'ยังไม่ได้เชื่อมต่อบอร์ด หรือเฟิร์มแวร์ยังไม่รองรับการส่งโลโก้';
    }
    _logoBusy = true;
    try {
      final chunk = (_dev!.mtuNow - 4).clamp(16, 200).toInt();
      final n = data.length;
      await ch.write([1, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]);
      int sum = 0;
      for (int off = 0; off < n; off += chunk) {
        final end = math.min(n, off + chunk);
        final part = data.sublist(off, end);
        for (final b in part) {
          sum = (sum + b) & 0xFFFF;
        }
        await ch.write([2, ...part]);
        onProgress(end / n);
      }
      await ch.write([3, sum & 255, (sum >> 8) & 255]);
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (t.img == 2) return null;
        if (t.img == 3) return 'บอร์ดรับภาพไม่สำเร็จ ลองส่งใหม่อีกครั้ง';
      }
      return 'ไม่ได้รับการยืนยันจากบอร์ด';
    } catch (e) {
      return 'ส่งไม่สำเร็จ: $e';
    } finally {
      _logoBusy = false;
    }
  }

  Future<String?> resetLogo() async {
    final ch = _imgCh;
    if (ch == null || link != LinkState.connected) return 'ยังไม่ได้เชื่อมต่อบอร์ด';
    try {
      await ch.write([4]);
      return null;
    } catch (e) {
      return 'ส่งคำสั่งไม่สำเร็จ: $e';
    }
  }

  // ===================== เขียนไฟล์ ECU (คลังไฟล์ + ส่งไป + สั่งเขียน) =====================
  bool get flashSupported => t.flashSup;
  bool get fileBusy => _fileBusy;
  bool get flashBusy => t.flashState >= 1 && t.flashState <= 5; // INIT..VERIFY

  /// ส่งไฟล์ .bin ไปเก็บในเกจ (ช่อง FILE) — name ส่งไปด้วยเพื่อให้เกจแสดงชื่อไฟล์
  Future<String?> sendBinFile(Uint8List data, String name, void Function(double) onProgress) async {
    final ch = _fileCh;
    if (ch == null || link != LinkState.connected || _dev == null) {
      return 'เฟิร์มแวร์เกจยังไม่รองรับการเขียนไฟล์ (ต้อง FW 1.3.0 ขึ้นไป)';
    }
    if (_fileBusy) return 'กำลังส่งไฟล์อยู่';
    _fileBusy = true;
    try {
      final chunk = (_dev!.mtuNow - 4).clamp(16, 200).toInt();
      final n = data.length;
      final nb = name.codeUnits.take(24).toList();
      await ch.write([1, n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255, ...nb]);
      int sum = 0;
      for (int off = 0; off < n; off += chunk) {
        final end = math.min(n, off + chunk);
        final part = data.sublist(off, end);
        for (final b in part) {
          sum = (sum + b) & 0xFFFF;
        }
        await ch.write([2, ...part], withoutResponse: false);
        onProgress(end / n);
      }
      await ch.write([3, sum & 255, (sum >> 8) & 255]);
      for (int i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (t.fileRx == 2) return null;
        if (t.fileRx == 3) return 'เกจรับไฟล์ไม่สำเร็จ ลองส่งใหม่';
      }
      return 'ไม่ได้รับการยืนยันจากเกจ';
    } catch (e) {
      return 'ส่งไม่สำเร็จ: $e';
    } finally {
      _fileBusy = false;
    }
  }

  Future<String?> deleteGaugeBin() async {
    final ch = _fileCh;
    if (ch == null || link != LinkState.connected) return 'ยังไม่ได้เชื่อมต่อเกจ';
    try {
      await ch.write([4]);
      return null;
    } catch (e) {
      return 'ส่งคำสั่งไม่สำเร็จ: $e';
    }
  }

  /// สั่งเกจเริ่มเขียนไฟล์ลงกล่อง (vendor 0 อัตโนมัติ, 1 Keihin, 2 Shindengen)
  Future<String?> startFlash(int vendor) async {
    final ch = _fileCh;
    if (ch == null || link != LinkState.connected) return 'ยังไม่ได้เชื่อมต่อเกจ';
    try {
      await ch.write([5, vendor & 0xFF]);
      return null;
    } catch (e) {
      return 'ส่งคำสั่งไม่สำเร็จ: $e';
    }
  }

  // ----- คลังไฟล์ในเครื่อง (เก็บ .bin ไว้ส่งซ้ำได้) -----
  Future<io.Directory> _binsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = io.Directory('${base.path}/bins');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<io.File>> listBins() async {
    try {
      final d = await _binsDir();
      final l = (await d.list().toList()).whereType<io.File>().where((f) => f.path.toLowerCase().endsWith('.bin')).toList();
      l.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return l;
    } catch (_) {
      return [];
    }
  }

  Future<io.File> importBinBytes(String name, Uint8List bytes) async {
    final d = await _binsDir();
    var safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (!safe.toLowerCase().endsWith('.bin')) safe = '$safe.bin';
    final f = io.File('${d.path}/$safe');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  // ----- คลัง XDF (เก็บไว้ในแอพ ไม่ต้องหาไฟล์ในเครื่องทุกครั้ง) -----
  Future<io.Directory> _xdfDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = io.Directory('${base.path}/xdf');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<io.File>> listXdfs() async {
    try {
      final d = await _xdfDir();
      final l = (await d.list().toList()).whereType<io.File>().where((f) => f.path.toLowerCase().endsWith('.xdf')).toList();
      l.sort((a, b) => a.path.compareTo(b.path));
      return l;
    } catch (_) {
      return [];
    }
  }

  Future<io.File> importXdfBytes(String name, Uint8List bytes) async {
    final d = await _xdfDir();
    var safe = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (!safe.toLowerCase().endsWith('.xdf')) safe = '$safe.xdf';
    final f = io.File('${d.path}/$safe');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<void> deleteBinFile(io.File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ----- DEMO: จำลองการขี่ครบทุกค่า -----
  // ECU 14 ค่า (RPM, SPEED, W.TEMP, IAT, EOT, TPS, MAP, BATT, AFR, IGN, INJ, O2, STFT, LTFT)
  // + GPS (ความเร็ว, ความแม่นยำ, ดาวเทียม) + DRAG LOG (ออกตัว 5 km/h, นาฬิกา 0.0000, ระยะ 201/402/500/1000 m)
  // วนรอบละ 48 วินาที: จอดติดเครื่อง 5 s -> ออกตัวเต็มคันเร่ง 34 s (เกิน 1000 m, สูงสุด ~148 km/h) -> เบรกจนหยุด 9 s
  // LOG DRAG จริงถูกพักไว้ระหว่าง DEMO (ไม่บันทึกทับ) และคืนค่าเดิมเมื่อปิด DEMO
  static const double _demoCycle = 48.0;
  List<dynamic>? _demoRunsBak;
  int _demoSelBak = 0;

  void toggleDemo() {
    demo = !demo;
    _demoTimer?.cancel();
    if (demo) {
      _demoRunsBak = runs.map((r) => r.toJson()).toList();
      _demoSelBak = dragSel;
      for (final r in runs) {
        r.clear();
      }
      dragSel = 0;
      _dragResetLive();
      final rnd = math.Random();
      final sw = Stopwatch()..start();
      const vmax = 150 / 3.6, tau = 8.0; // m/s ; ค่าคงที่เวลาเร่ง (ออกตัวแบบรถสายพาน)
      double last = 0, v = 0, ect = 72, eot = 70, stft = 1.0;
      int tick = 0;
      _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = sw.elapsedMicroseconds / 1e6;
        final dt = (now - last).clamp(0.0, 0.2).toDouble();
        last = now;
        final ph = now % _demoCycle;
        final wob = math.sin(now * 7.3); // สั่นเล็กน้อยให้ดูเหมือนจริง
        double tps, rpm;
        bool decel = false;
        if (ph < 5) {
          // จอดติดเครื่อง (เดินเบา)
          v = math.max(0.0, v - 6 * dt);
          tps = 0;
          rpm = 1550 + 40 * wob;
          // LOG เต็ม 3 RUN แล้ว -> ล้างก่อนออกตัวรอบใหม่ (เฉพาะ DEMO)
          if (ph > 4.5 && dragSt != DragSt.run && runs.every((r) => r.hasData)) {
            for (final r in runs) {
              r.clear();
            }
            dragSel = 0;
          }
        } else if (ph < 39) {
          // ออกตัวเต็มคันเร่ง: dv/dt = (vmax - v) / tau
          v += (vmax - v) / tau * dt;
          tps = math.max(0.0, 100 - 12 * v / vmax);
          rpm = 6800 + 2700 * v / vmax + 60 * wob;
        } else {
          // เบรก ~4.8 m/s²
          v = math.max(0.0, v - 4.8 * dt);
          tps = 0;
          decel = v > 1;
          rpm = decel ? 2300 + 3600 * v / vmax : 1600 + 40 * wob;
        }
        final spd = v * 3.6;
        final load = tps / 100;
        // อุณหภูมิค่อยๆ อุ่นเครื่องขึ้นจนคงที่
        ect += (90 + 2 * load - ect) * dt / 25;
        eot += (96 + 4 * load - eot) * dt / 35;
        final double afr = decel
            ? math.min(19.0, 17.2 + 1.8 * v / vmax)
            : (load > 0.5 ? 12.9 + 0.25 * wob : 14.4 + 0.35 * math.sin(now * 2.1));
        final double o2v = afr < 14.7 ? (0.82 - (afr - 12.5) * 0.04 + 0.02 * wob) : (0.14 + 0.04 * rnd.nextDouble());
        stft += ((afr < 14.7 ? 0.96 : 1.04) - stft) * dt * 0.8 + (rnd.nextDouble() - 0.5) * 0.004;
        stft = stft.clamp(0.9, 1.1).toDouble();
        final double inj = decel ? 0.55 : (load == 0 ? 1.45 + 0.05 * wob : 1.4 + 5.2 * load * (0.6 + 0.4 * rpm / 9500));
        final double ign = decel ? 30.0 : (load == 0 ? 12 + wob : (18 + 14 * ((rpm - 6000) / 3500).clamp(0.0, 1.0)).toDouble());
        final double map = decel ? 22 + 2 * wob : 30 + 68 * load + 1.5 * wob;
        t = Telemetry(
          fresh: true, state: 1, proto: 1, bike: t.bike, img: 0,
          rpm: rpm, speed: spd, ect: ect, iat: 33 + 3 * (1 - v / vmax), eot: eot,
          tps: tps, map: map, batt: rpm < 2000 ? 13.4 + 0.03 * wob : 14.1 + 0.05 * wob,
          afr: afr, ign: ign, inj: inj, o2v: o2v, stft: stft, ltft: 0.984 + 0.004 * math.sin(now * 0.05),
        );
        // GPS จำลอง 10 Hz (ทุก 2 รอบ) -> ป้อนหน้า DRAG LOG / GRAPH / ความเร็ว GPS
        if (++tick % 2 == 0) {
          gpsOk = true;
          _gpsLastMs = DateTime.now().millisecondsSinceEpoch;
          gpsSpeed = spd < 0.5 ? 0.0 : math.max(0.0, spd + (rnd.nextDouble() - 0.5) * 0.6);
          gpsRaw = gpsSpeed;
          gpsAccM = 3.0 + rnd.nextDouble() * 1.5;
          spdAccKmh = 0.5 + rnd.nextDouble() * 0.4;
          satTotal = 26;
          satUsed = 17 + (2 * math.sin(now / 20)).round();
          _dragUpdate(gpsSpeed!, DateTime.now());
        }
        _track();
        notifyListeners();
      });
    } else {
      t = Telemetry();
      // คืนสถานะ GPS ให้ GPS จริงอัปเดตต่อ และคืน LOG DRAG เดิม
      gpsOk = false;
      gpsSpeed = null;
      gpsRaw = null;
      _gLastV = null;
      _gPrevFixMs = 0;
      _gMoving = false;
      _gMoveN = 0;
      _gHist.clear();
      gpsAccM = null;
      spdAccKmh = null;
      satUsed = null;
      satTotal = null;
      final bak = _demoRunsBak;
      if (bak != null) {
        for (int i = 0; i < runs.length && i < bak.length; i++) {
          runs[i] = DragRun.fromJson(bak[i]);
        }
        dragSel = _demoSelBak;
      }
      _demoRunsBak = null;
      _dragResetLive();
    }
    notifyListeners();
  }

  /// ล้างสถานะรอบที่กำลังวิ่ง/นาฬิกา (ไม่แตะ LOG ที่บันทึกแล้ว)
  void _dragResetLive() {
    dragSt = DragSt.ready;
    dragMeters = 0;
    dragSecs = 0;
    _rPrevKmh = null;
    _rPrevTs = null;
    _clockStop(0);
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _retryTimer?.cancel();
    _scanSub?.cancel();
    _dataSub?.cancel();
    _connSub?.cancel();
    _gpsSub?.cancel();
    _gpsWatch?.cancel();
    _gpsAnim?.cancel();
    _gnssSub?.cancel();
    _dTick?.cancel();
    dragClock.dispose();
    _gTimer?.cancel();
    _disposed = true;
    _notifyTimer?.cancel();
    super.dispose();
  }
}

// ======================= UI =======================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Cfg.i.load();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MfbProApp());
}

// ---------- พื้นหลัง TIWSHOP (รังผึ้งเขียว ลดความสว่างไว้ในรูปแล้ว) ----------
class _Bg extends StatelessWidget {
  final double dim; // มืดเพิ่ม 0..1 (หน้า SETTING)
  final int idx; // kBgs
  const _Bg({this.dim = 0, this.idx = 0});
  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        if (idx == kBgs.length - 1)
          const ColoredBox(color: Colors.black)
        else if (idx <= 0 || idx >= kBgs.length)
          Image.asset('assets/bg.jpg', fit: BoxFit.cover, filterQuality: FilterQuality.low, gaplessPlayback: true)
        else // รูปขาวดำย้อมสี (คูณสี) -> ได้พื้นหลังสีที่เลือก
          Image.asset('assets/bg_gray.jpg', fit: BoxFit.cover, filterQuality: FilterQuality.low, gaplessPlayback: true,
              color: kBgs[idx].color, colorBlendMode: BlendMode.modulate),
        if (dim > 0) ColoredBox(color: Colors.black.withOpacity(dim)),
      ]);
}

class MfbProApp extends StatelessWidget {
  const MfbProApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'TIWSHOP',
        theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
        home: const SplashPage(),
      );
}

// ---------- หน้าเปิดแอพ: โลโก้ TIWSHOP เลือนเข้า-ออก 2.2 วิ + แถบโหลด ----------
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late final AnimationController ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200)); // TIWSHOP: เปิดแอพไวขึ้น (เดิม 4 วิ)
  late final Animation<double> fade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
    TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)), weight: 30),
  ]).animate(ac);

  @override
  void initState() {
    super.initState();
    ac.forward().whenComplete(_go);
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 500),
      pageBuilder: (_, __, ___) => const GaugePage(),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  void dispose() {
    ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        FadeTransition(opacity: fade, child: Image.asset('assets/splash.jpg', fit: BoxFit.cover)),
        Positioned(
          left: 0, right: 0, bottom: 18,
          child: Center(
            child: SizedBox(
              width: 280,
              child: AnimatedBuilder(
                animation: ac,
                builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('LOADING  ${(ac.value * 100).round()}%',
                      style: const TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: ac.value, minHeight: 5, color: Colors.white, backgroundColor: Colors.white24),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------- เลือกค่าที่จะแสดงในช่อง (เหมือนเมนู SELECT ของ TEST1) ----------
Future<void> pickKey(BuildContext context, List<int> arr, int idx, {bool speedSrc = false}) {
  final th = Cfg.i.t;
  Widget srcBtn(String label, bool on, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 92,
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? th.c.withOpacity(0.3) : Colors.black45,
            border: Border.all(color: on ? th.c : Colors.white24, width: on ? 1.6 : 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: const TextStyle(fontFamily: kFont, fontSize: 9)),
        ),
      );
  return showDialog<void>(
    context: context,
    builder: (dctx) => StatefulBuilder(builder: (dctx, setD) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xF2060606),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: th.c, width: 1.2),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SELECT', style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c)),
              const SizedBox(height: 10),
              if (speedSrc) ...[
                Text('SPD จาก', style: TextStyle(fontFamily: kFont, fontSize: 9, color: th.c2)),
                const SizedBox(height: 6),
                Row(children: [
                  srcBtn('GPS', Cfg.i.speedGps, () async { await Cfg.i.setSpeedGps(true); setD(() {}); }),
                  const SizedBox(width: 8),
                  srcBtn('ECU', !Cfg.i.speedGps, () async { await Cfg.i.setSpeedGps(false); setD(() {}); }),
                ]),
                const SizedBox(height: 12),
              ],
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (int k = 0; k < kKeys.length; k++)
                  InkWell(
                    onTap: () {
                      Cfg.i.setSlot(arr, idx, k);
                      Navigator.of(dctx).pop();
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 92,
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: arr[idx] == k ? th.c.withOpacity(0.3) : Colors.black45,
                        border: Border.all(color: arr[idx] == k ? th.c : Colors.white24, width: arr[idx] == k ? 1.6 : 1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(kKeys[k].name, style: const TextStyle(fontFamily: kFont, fontSize: 9)),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    )),
  );
}

// ---------- หน้าเกจหลัก (2 หน้า: GAUGE / GRID) ----------
class GaugePage extends StatefulWidget {
  const GaugePage({super.key});
  @override
  State<GaugePage> createState() => _GaugePageState();
}

class _GaugePageState extends State<GaugePage> {
  final c = GaugeController();
  final pc = PageController();
  int page = 0;
  Size _afrSz = Size.zero;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    c.init();
    c.addListener(_rebuild);
    Cfg.i.addListener(_rebuild);
    AfrLog.i.attach(c);
    AfrLog.i.ensureDefault();   // ตั้งแกนตาราง AFR LOG
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    c.removeListener(_rebuild);
    c.dispose();
    pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final t = c.t;
    final blinkOn = (DateTime.now().millisecondsSinceEpoch ~/ 280) % 2 == 0;
    final shiftOn = t.rpm != null && t.rpm! >= cfg.shift;
    final linkTxt = switch (c.link) {
      LinkState.idle => 'OFFLINE',
      LinkState.scanning => 'SCANNING',
      LinkState.connecting => 'CONNECTING',
      LinkState.connected => c.gaugeName ?? 'CONNECTED',
    };
    final linkCol = c.link == LinkState.connected ? kGreen : (c.link == LinkState.idle ? kBad : kAmber);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        RepaintBoundary(child: _Bg(idx: cfg.bgIdx)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Column(children: [
              Row(children: [
                // โลโก้ TIWSHOP
                const RepaintBoundary(child: Image(image: AssetImage('assets/logo.png'), height: 34, filterQuality: FilterQuality.medium)),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _chip(linkTxt, linkCol),
                      _chip(c.ecuLive || c.demo ? 'ECU LIVE' : 'NO ECU', c.ecuLive || c.demo ? kGreen : kBad),
                      _chip(c.gpsOk ? 'GPS' : 'NO GPS', c.gpsOk ? kGreen : kBad),
                    ]),
                  ),
                ),
                _btn(c.link == LinkState.connected ? 'ตัดการเชื่อมต่อ' : 'เชื่อมต่อ',
                    () => c.link == LinkState.connected ? c.disconnect() : pickGauge(context, c), th),
                const SizedBox(width: 6),
                _btn('DEMO', c.toggleDemo, th, active: c.demo),
                const SizedBox(width: 6),
                _btn('FLASH ECU', () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlashPage(c: c))), th),
                const SizedBox(width: 6),
                _iconBtn(Icons.settings, th, () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(c: c)));
                }),
              ]),
              const SizedBox(height: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: PageView(
                    controller: pc,
                    onPageChanged: (i) {
                      c.graphVisible = i == 3;
                      c.dtcWatch(i == 6); // หน้า DTC: ให้เกจอ่านโค้ดต่อเนื่อง
                      setState(() => page = i);
                    },
                    // TIWSHOP: สร้างเฉพาะหน้าที่เห็นบนจอ (เดิมสร้างครบ 6 หน้าทุกครั้งที่ค่าเปลี่ยน)
                    children: [
                      for (int pi = 0; pi < 8; pi++)
                        RepaintBoundary(child: Builder(builder: (_) => switch (pi) {
                              0 => DashPage(c: c),
                              1 => _mainPage(th, blinkOn),
                              2 => _gridPage(th, blinkOn),
                              3 => _graphPage(th),
                              4 => _afrPage(th),
                              5 => _dragPage(th),
                              6 => _dtcPage(th),
                              _ => TopSpeedPage(c: c),
                            })),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
        // ตัวบอกหน้า: สี่เหลี่ยมแนวนอน + ชื่อหน้า
        Positioned(
          left: 0, right: 0, bottom: 3,
          child: IgnorePointer(
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (int i = 0; i < 8; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == page ? 24 : 14, height: 5,
                  decoration: BoxDecoration(
                    color: i == page ? th.c : Colors.white30,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              const SizedBox(width: 8),
              Text(const ['DASH', 'GAUGE', 'GRID', 'GRAPH', 'AFR LOG', 'DRAG LOG', 'DTC', 'TOP SPEED'][page], style: const TextStyle(fontFamily: kFont, fontSize: 7, color: Colors.white54)),
            ]),
          ),
        ),
        // แสงเตือน SHIFT: แดงฟุ้งจากขอบทั้ง 4 เข้ากลางจอ กระพริบ
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: shiftOn ? (blinkOn ? 1.0 : 0.15) : 0.0,
              duration: const Duration(milliseconds: 120),
              child: CustomPaint(painter: EdgeGlowPainter()),
            ),
          ),
        ),
      ]),
    );
  }

  // ----- หน้า 1: เกจ -----
  Widget _mainPage(AppTheme th, bool blinkOn) {
    final m = Cfg.i.main;
    return LayoutBuilder(builder: (_, all) {
      final tw = (all.maxWidth * 0.26).clamp(150.0, 220.0).toDouble();   // ช่องค่ากว้างขึ้น (จอ 800 dp = ~205)
      return Row(children: [
        SizedBox(
          width: tw,
          child: Column(children: [
            for (int i = 0; i < 3; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(child: RepaintBoundary(child: LayoutBuilder(builder: (_, cs) => _center(cs, th)))),
        const SizedBox(width: 8),
        SizedBox(
          width: tw,
          child: Column(children: [
            for (int i = 3; i < 6; i++) Expanded(child: _slotTile(m[i], () => pickKey(context, m, i), blinkOn)),   // ขวา 3 ช่อง (เท่าซ้าย)
          ]),
        ),
      ]);
    });
  }

  // ----- หน้า 2: GRID 12 ช่อง -----
  Widget _gridPage(AppTheme th, bool blinkOn) {
    final g = Cfg.i.grid;
    return Column(children: [
      for (int r = 0; r < 3; r++)
        Expanded(
          child: Row(children: [
            for (int k = 0; k < 4; k++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: k < 3 ? 6 : 0),
                  child: _slotTile(g[r * 4 + k], () => pickKey(context, g, r * 4 + k), blinkOn, vs: 36),
                ),
              ),
          ]),
        ),
    ]);
  }

  // ----- หน้า 4: DRAG LOG (จัดหน้าตาก่อน) -----
  Widget _frame(AppTheme th, Widget child, {EdgeInsets pad = const EdgeInsets.all(8)}) => FxPanel(col: th.c, padding: pad, glow: 0.35, child: child);


  // ----- หน้า AFR LOG (ก่อน DRAG): ตาราง RPM×TPS, จำลองด้วย DEMO -----
  Widget _afrPage(AppTheme th) {
    final log = AfrLog.i;
    final live = c.demo || c.ecuLive;
    return _frame(
      th,
      Column(children: [
        Row(children: [
          Text('AFR LOG', style: TextStyle(fontFamily: kFont, fontSize: 12, color: th.c)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                log.ready
                    ? '${log.rows}×${log.cols} · ${log.src} · ${log.filled} ช่อง'
                    : 'ยังไม่มีตาราง',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: live ? Colors.white70 : kAmber)),
          ),
          _afrMini(log.rec ? '● REC' : '❚❚', log.rec ? kGreen : kAmber, log.ready ? log.toggleRec : null),
          const SizedBox(width: 6),
          _afrMini('ล้าง', th.c,
              log.ready
                  ? () async {
                      if (await askYes(context, 'ล้าง AFR LOG', 'ลบค่าที่บันทึกไว้ทั้งหมด?', ok: 'ล้าง', col: kBad)) log.clear();
                    }
                  : null),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: log.ready
                ? LayoutBuilder(builder: (_, cs) {
                    final h = _AfrPainter.hh + log.rows * _AfrPainter.rh;
                    _afrSz = Size(cs.maxWidth, h);
                    return SingleChildScrollView(
                      child: GestureDetector(
                        onTapUp: (dd) => _afrTap(dd.localPosition),
                        child: CustomPaint(size: Size(cs.maxWidth, h), painter: _AfrPainter(log, th)),
                      ),
                    );
                  })
                : const Center(child: Text('ยังไม่มีตาราง', style: TextStyle(color: Colors.white54))),
          ),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Container(
            width: 120, height: 7,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(colors: [for (int k = 0; k <= 10; k++) _afrColor(11.5 + k * 0.5)])),
          ),
          const SizedBox(width: 6),
          const Text('11.5 รวย · 14.7 · 16.5 บาง', style: TextStyle(fontSize: 10, color: Colors.white60)),
          const Spacer(),
          const Text('กรอบขาว = ตำแหน่งตอนนี้ · แตะช่องดูค่า', style: TextStyle(fontSize: 10, color: Colors.white54)),
        ]),
      ]),
    );
  }

  Widget _afrMini(String t, Color col, VoidCallback? f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(7),
        child: Opacity(
          opacity: f == null ? 0.4 : 1,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black45,
              border: Border.all(color: col, width: 1.2),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(t, style: TextStyle(fontSize: 12, color: col, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  void _afrTap(Offset p) {
    final log = AfrLog.i;
    if (!log.ready) return;
    final g = _AfrPainter.geom(_afrSz, log.rows, log.cols);
    final cc = ((p.dx - g.$1) / g.$3).floor(), r = ((p.dy - g.$2) / g.$4).floor();
    if (r < 0 || cc < 0 || r >= log.rows || cc >= log.cols) return;
    final v = log.at(r, cc);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('RPM ${log.rpm[r].toStringAsFixed(0)} · TPS ${log.tps[cc].toStringAsFixed(1)} : '
              '${v == null ? 'ยังไม่มีข้อมูล' : 'AFR ${v.toStringAsFixed(2)} (${log.cnt[r][cc]} ครั้ง)'}')));
  }

  Widget _dragPage(AppTheme th) {
    final run = c.runs[c.dragSel];
    final sp = c.demo ? c.t.speed : (c.gpsOk ? c.gpsSpeed : null);
    // สีสัญญาณ GPS: ดาวเทียม >= 15 ดวง = เขียว (ถ้ายังไม่มีจำนวนดาวเทียมจริง ใช้ความแม่นยำตำแหน่งแทนไปก่อน)
    Color gpsCol;
    if (c.satUsed != null) {
      gpsCol = c.satUsed! >= 15 ? kGreen : (c.satUsed! >= 8 ? kAmber : kBad);
    } else if (!c.gpsOk) {
      gpsCol = kBad;
    } else {
      final a = c.gpsAccM ?? 99;
      gpsCol = a <= 10 ? kGreen : (a <= 25 ? kAmber : kBad);
    }
    final acc = c.spdAccKmh == null ? '--' : c.spdAccKmh!.round().toString();
    final stTxt = c.dragSt == DragSt.run ? 'RUNNING' : (c.dragFull ? 'RUN ${c.dragSel + 1} FULL' : (c.dragSt == DragSt.done ? 'DONE' : 'READY'));
    final stCol = c.dragSt == DragSt.run ? kAmber : (c.dragFull ? kBad : (c.dragSt == DragSt.done ? th.c : kGreen));
    const lab = TextStyle(fontSize: 13, color: Colors.white70);

    return Column(children: [
      _frame(
        th,
        Row(children: [
          Icon(Icons.signal_cellular_alt, color: gpsCol, size: 22),
          const SizedBox(width: 4),
          Text('GPS', style: TextStyle(fontFamily: kFont, fontSize: 12, color: gpsCol)),
          const SizedBox(width: 16),
          Text('Satellites in use: ${c.satUsed ?? '--'} of ${c.satTotal ?? '--'}', style: lab),
          if (c.satMax > 0) Text('  (max ${c.satMax})', style: const TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(width: 16),
          Text('Speed ${sp == null ? '--' : sp.round()} ± $acc km/h', style: lab),
          const Spacer(),
          Text(stTxt, style: TextStyle(fontFamily: kFont, fontSize: 11, color: stCol)),
        ]),
        pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: Row(children: [
          Expanded(flex: 3, child: _frame(th, _splitTable(th, run))),
          const SizedBox(width: 6),
          Expanded(flex: 2, child: _frame(th, _dragControls(th, run))),
        ]),
      ),
      const SizedBox(height: 6),
      _speedTacho(th, sp),
    ]);
  }

  Widget _splitTable(AppTheme th, DragRun run) {
    Widget cell(String s, {bool head = false, bool right = true, Color? col, double size = 15}) => Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(s,
                style: TextStyle(
                    fontFamily: kFont,
                    fontSize: head ? 9 : size,
                    color: head ? Colors.white54 : (col ?? Colors.white),)),
          ),
        );
    Widget row(Widget a, Widget b, Widget d, {bool last = false}) => Expanded(
          child: Container(
            decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Colors.white12))),
            child: Row(children: [
              Expanded(flex: 4, child: a),
              Expanded(flex: 4, child: b),
              Expanded(flex: 4, child: d),
            ]),
          ),
        );
    String tm(double? v) => v == null ? '--' : '${v.toStringAsFixed(4)} s';
    String kh(double? v) => v == null ? '--' : '${v.round()} km/h';
    return Column(children: [
      row(cell('DIST', head: true, right: false), cell('TIME', head: true), cell('SPEED', head: true)),
      for (int i = 0; i < 4; i++)
        row(cell('${GaugeController.dragDist[i].round()}m', right: false, col: th.c), cell(tm(run.t[i])), cell(kh(run.v[i]))),
      row(cell('MAX SPEED', right: false, size: 13, col: th.c), cell(''), cell(run.maxKmh > 0 ? '${run.maxKmh.round()} KM/H' : '-- KM/H'), last: true),
    ]);
  }

  Widget _dragControls(AppTheme th, DragRun run) {
    final running = c.dragSt == DragSt.run;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('LOG RUN', style: TextStyle(fontFamily: kFont, fontSize: 9, color: Colors.white54)),
      const SizedBox(height: 6),
      Row(children: [
        for (int i = 0; i < 3; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < 2 ? 6 : 0),
              child: InkWell(
                onTap: () => c.selectRun(i),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.dragSel == i ? th.c.withOpacity(0.3) : Colors.black45,
                    border: Border.all(color: c.dragSel == i ? th.c : Colors.white24, width: c.dragSel == i ? 1.6 : 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('RUN ${i + 1}${c.runs[i].hasData ? ' ●' : ''}', style: const TextStyle(fontFamily: kFont, fontSize: 9)),
                ),
              ),
            ),
          ),
      ]),
      Expanded(
        child: Center(
          child: running || (c.dragSt == DragSt.done && c.dragClock.value > 0)
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  // นาฬิกาวิ่งจริง 0.0000 (อัปเดต ~60 ครั้ง/วินาที เฉพาะตัวเลขนี้) | จบรอบ = ค้างเวลาสุดท้าย
                  ValueListenableBuilder<double>(
                    valueListenable: c.dragClock,
                    builder: (_, v, __) => FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _monoNum('${v.toStringAsFixed(4)} s',
                          TextStyle(fontFamily: kFont, fontSize: 26, color: Colors.white)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(running ? '${c.dragMeters.round()} m' : 'DONE · ${c.dragMeters.round()} m',
                      style: const TextStyle(fontSize: 14, color: Colors.white70)),
                ])
              : Text(
                  c.dragFull
                      ? 'RUN ${c.dragSel + 1} มีข้อมูลแล้ว\nเลือก RUN อื่น หรือกด RESET LOG'
                      : (c.dragArmed
                          ? 'รอออกตัว… (เริ่มจับเวลาเมื่อเกิน ${GaugeController.dragStartKmh.round()} km/h)'
                          : 'ชะลอให้ต่ำกว่า ${GaugeController.dragStartKmh.round()} km/h\nเพื่อเตรียมออกตัว'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ),
      ),
      InkWell(
        onTap: running ? null : _confirmReset,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(color: kBad, width: 1.4),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text('RESET LOG', style: TextStyle(fontFamily: kFont, fontSize: 10, color: kBad)),
        ),
      ),
    ]);
  }

  /// ตัวเลขกว้างคงที่ทีละตัว: ฟอนต์ Ethnocentric ตัวเลขกว้างไม่เท่ากัน ("1" แคบ) -> ถ้าไม่ล็อกความกว้าง นาฬิกาจะสั่นซ้ายขวาตอนวิ่ง
  Widget _monoNum(String s, TextStyle st) {
    final fs = st.fontSize ?? 14;
    double w(String ch) => ch == '.' ? fs * 0.42 : (ch == ' ' ? fs * 0.3 : (RegExp(r'[0-9]').hasMatch(ch) ? fs * 1.0 : fs * 0.9));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final ch in s.split(''))
        SizedBox(width: w(ch), child: Text(ch, textAlign: TextAlign.center, softWrap: false, overflow: TextOverflow.visible, style: st)),
    ]);
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: const Text('RESET LOG', style: TextStyle(fontFamily: kFont, fontSize: 14)),
        content: const Text('ลบ LOG ทั้ง 3 RUN ใช่หรือไม่?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: const Text('ลบทั้งหมด', style: TextStyle(color: kBad))),
        ],
      ),
    );
    if (ok == true) c.resetDragLog();
  }

  /// TACHO SPEED 0-240 ไล่สีเขียว -> เหลือง -> แดง
  Widget _speedTacho(AppTheme th, double? sp) {
    final frac = ((sp ?? 0) / 240).clamp(0.0, 1.0).toDouble();
    const n = 48;
    return _frame(
      th,
      Row(children: [
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 14,
              child: Row(children: [
                for (int i = 0; i < n; i++)
                  Expanded(
                    child: Builder(builder: (_) {
                      final pos = (i + 0.5) / n;
                      final lit = pos <= frac;
                      final col = rpmColor(pos * 240, 240);
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: lit ? col : Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(2),
                          
                        ),
                      );
                    }),
                  ),
              ]),
            ),
            const SizedBox(height: 3),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (int k = 0; k <= 240; k += 40) Text('$k', style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white54)),
            ]),
          ]),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 96,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text('${sp == null ? '--' : sp.round()} km/h',
                style: TextStyle(fontFamily: kFont, fontSize: 18, color: Colors.white)),
          ),
        ),
      ]),
      pad: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    );
  }

  // ----- หน้า 3: GRAPH (4 ช่อง แตะเพื่อเปิด/ปิดเส้นกราฟ ค่ายังแสดงในช่องเหมือนเดิม) -----
  static const _gNames = ['RPM', 'TPS', 'GPS', 'AFR'];

  // ----- หน้า 6: DTC อ่านโค้ด / ลบโค้ด (ผ่านเกจ, เฉพาะกล่อง Honda) -----
  Widget _dtcPage(AppTheme th) {
    final t = c.t;
    final conn = c.link == LinkState.connected;
    final demo = c.demo;
    final cur = demo ? const [[7, 1]] : t.dtcCur;
    final sto = demo ? const [[21, 1], [12, 1]] : t.dtcSto;
    final valid = demo || t.dtcValid;
    String? msg;
    Color msgCol = Colors.white70;
    if (demo) {
      msg = null;
    } else if (!conn) {
      msg = 'ยังไม่ได้เชื่อมต่อเกจ';
      msgCol = kAmber;
    } else if (!t.dtcSup) {
      msg = 'เฟิร์มแวร์เกจยังไม่รองรับ DTC ผ่านแอพ — อัปเดตเป็น FW 1.0.0 ขึ้นไป';
      msgCol = kAmber;
    } else if (t.proto != 1) {
      msg = 'อ่าน/ลบโค้ดได้เฉพาะกล่อง HONDA (K-LINE)';
      msgCol = kAmber;
    } else if (!t.fresh) {
      msg = 'ไม่มีการเชื่อมต่อกับกล่อง ECU';
      msgCol = kBad;
    } else if (c.dtcReading || !valid) {
      msg = 'กำลังอ่านโค้ดจากกล่อง ECU…';
      msgCol = th.c2;
    } else if (t.dtcClear == 1) {
      msg = 'กำลังลบโค้ด…';
      msgCol = th.c2;
    } else if (t.dtcClear == 3) {
      msg = 'ลบโค้ดไม่สำเร็จ (ลองบิดกุญแจ OFF-ON แล้วลบใหม่)';
      msgCol = kBad;
    } else if (cur.isEmpty && sto.isEmpty) {
      msg = t.dtcClear == 2 ? 'ลบโค้ดเรียบร้อย — ไม่พบโค้ด' : 'ไม่พบโค้ด (NO CODES)';
      msgCol = kGreen;
    }
    final canAct = demo || (conn && t.dtcSup && t.proto == 1 && t.fresh);
    final last = c.dtcLastRead;
    String lastTxt = '--';
    if (last != null) {
      final sec = DateTime.now().difference(last).inSeconds;
      lastTxt = sec < 60 ? '${sec}s' : '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
    }

    Widget row(List<int> d, bool now) {
      final col = now ? kBad : kAmber;
      final desc = dtcDesc(d[0], d[1]);
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: col.withOpacity(0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: col.withOpacity(0.55)),
        ),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Text('${d[0].toString().padLeft(2, '0')}-${d[1].toString().padLeft(2, '0')}',
              style: TextStyle(fontFamily: kFont, fontSize: 13, color: Colors.white)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(desc?.$2 ?? 'ไม่รู้จักโค้ดนี้', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              Text(desc?.$1 ?? 'Unknown code', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: col.withOpacity(0.25), borderRadius: BorderRadius.circular(4)),
            child: Text(now ? 'NOW' : 'PAST', style: TextStyle(fontFamily: kFont, fontSize: 8, color: col)),
          ),
        ]),
      );
    }

    Widget bigBtn(String en, String thTxt, IconData ic, Color col, VoidCallback? f, {bool filled = false}) => Opacity(
          opacity: f == null ? 0.4 : 1,
          child: GestureDetector(
            onTap: f,
            child: FxPanel(
              col: col, glow: filled ? 0.6 : 0.4,
              child: Container(
                decoration: filled ? BoxDecoration(color: col.withOpacity(0.28), borderRadius: BorderRadius.circular(11)) : null,
                alignment: Alignment.center,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(ic, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(en, style: TextStyle(fontFamily: kFont, fontSize: 12, color: Colors.white)),
                    Text(thTxt, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  ]),
                ]),
              ),
            ),
          ),
        );

    return Row(children: [
      SizedBox(
        width: 210,
        child: Column(children: [
          Expanded(
            child: Row(children: [
              Expanded(child: StatTile(th: th, label: 'NOW', unit: 'CODES', value: valid ? '${cur.length}' : '--', valueColor: cur.isEmpty ? null : kBad, valueSize: 26)),
              const SizedBox(width: 6),
              Expanded(child: StatTile(th: th, label: 'PAST', unit: 'CODES', value: valid ? '${sto.length}' : '--', valueColor: sto.isEmpty ? null : kAmber, valueSize: 26)),
            ]),
          ),
          Expanded(child: StatTile(th: th, label: 'LAST READ', unit: 'AGO', value: demo ? '3s' : lastTxt, valueSize: 22)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: bigBtn('READ', 'อ่านโค้ด', Icons.search, th.c, canAct && !c.dtcReading ? c.dtcRead : null, filled: true),
            ),
          ),
          Expanded(
            child: bigBtn('CLEAR', 'ลบโค้ด', Icons.delete_sweep, kBad, canAct && t.dtcClear != 1
                ? () async {
                    if (await askYes(context, 'ลบโค้ด DTC', 'ลบโค้ดทั้งหมดในกล่อง ECU?\nควรดับเครื่องยนต์ (บิดกุญแจ ON) ก่อนลบ', ok: 'ลบโค้ด', col: kBad)) c.dtcClear();
                  }
                : null),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _frame(
          th,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('DTC', style: TextStyle(fontFamily: kFont, fontSize: 13, color: th.c)),
              const SizedBox(width: 10),
              const Expanded(child: Text('รหัสปัญหาจากกล่อง ECU (HONDA)', style: TextStyle(fontSize: 12, color: Colors.white60))),
              if (c.dtcReading) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: th.c)),
            ]),
            const SizedBox(height: 8),
            Expanded(
              child: msg != null && (cur.isEmpty && sto.isEmpty || !valid || c.dtcReading || !canAct)
                  ? Center(child: Text(msg, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: msgCol, fontWeight: FontWeight.bold)))
                  : ListView(children: [
                      if (msg != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(msg, style: TextStyle(fontSize: 12, color: msgCol))),
                      for (final d in cur) row(d, true),
                      for (final d in sto) row(d, false),
                    ]),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _graphPage(AppTheme th) {
    final cfg = Cfg.i;
    return Column(children: [
      SizedBox(
        height: 78,
        child: Row(children: [
          for (int i = 0; i < 4; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i < 3 ? 6 : 0),
                child: _graphBox(i, (cfg.graphOn & (1 << i)) != 0),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xCC060606),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: CustomPaint(painter: GraphPainter(hist: c.gHist, on: cfg.graphOn), size: Size.infinite),
          ),
        ),
      ),
    ]);
  }

  Widget _graphBox(int i, bool on) {
    final col = GraphPainter.cols[i];
    final v = c.gVal(i);
    final dec = (i == 1 || i == 3) ? 1 : 0;
    String f(double? x) => x == null ? '0' : x.toStringAsFixed(dec);
    return GestureDetector(
      onTap: () => Cfg.i.toggleGraph(i),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
        decoration: BoxDecoration(
          color: const Color(0xCC060606),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? col : Colors.white24, width: on ? 1.6 : 1.0),
          
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_gNames[i], style: TextStyle(fontFamily: kFont, fontSize: 9, color: on ? col : Colors.white38)),
            Icon(on ? Icons.show_chart : Icons.visibility_off, size: 13, color: on ? col : Colors.white30),
          ]),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(v == null ? '--' : v.toStringAsFixed(dec),
                    style: TextStyle(fontFamily: kFont, fontSize: 22, color: Colors.white)),
              ),
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text.rich(TextSpan(children: [
              const TextSpan(text: '▼ ', style: TextStyle(color: kGreen, fontSize: 8)),
              TextSpan(text: f(c.gMin[i]), style: const TextStyle(color: kGreen, fontSize: 11)),
            ])),
            Text.rich(TextSpan(children: [
              const TextSpan(text: '▲ ', style: TextStyle(color: kBad, fontSize: 8)),
              TextSpan(text: f(c.gMax[i]), style: const TextStyle(color: kBad, fontSize: 11)),
            ])),
          ]),
        ]),
      ),
    );
  }

  /// สร้างช่องค่าจากคีย์: สี/บาร์/กระพริบตามกฎ
  Widget _slotTile(int key, VoidCallback onTap, bool blinkOn, {double vs = 30, double bm = 6, bool minmax = false}) {
    final kd = kKeys[key];
    final cfg = Cfg.i;
    final v = c.keyVal(key);
    final s = v == null ? '--' : v.toStringAsFixed(kd.dec);
    Color? vc;
    double? bar;
    Color Function(double)? bc;
    bool alert = false;
    switch (key) {
      case kTps:
        vc = kTpsBlue;
        bar = v == null ? 0.0 : (v / 100).clamp(0.0, 1.0).toDouble();
        bc = (_) => kTpsBlue;
        break;
      case kBatt:
        vc = kBattRed;
        break;
      case kAfr:
        final col = v == null ? kAfrOk : afrColor(v);
        if (v != null) vc = col;
        bar = v == null ? 0.0 : ((v - 10) / 8).clamp(0.0, 1.0).toDouble();
        bc = (_) => col;
        break;
      case kRpm:
        bar = v == null ? 0.0 : (v / kMaxRpm).clamp(0.0, 1.0).toDouble();
        bc = (p) => rpmColor(p * kMaxRpm, cfg.shift);
        break;
      case kTemp:
      case kEot:
        alert = v != null && v >= cfg.tempWarn;
        break;
    }
    return StatTile(
      th: cfg.t, label: kd.name, unit: kd.unit, value: s, valueColor: vc,
      alert: alert, blinkOn: blinkOn, bar: bar, barColor: bc, onTap: onTap, valueSize: vs, bottomMargin: bm,
      mn: minmax && key == kRpm ? c.mnStr('rpm') : null, mx: minmax && key == kRpm ? c.mxStr('rpm') : null,
    );
  }

  // เกจกลาง: ตัวเลขกลางเกจ + ช่องใต้เกจ เลือกค่าได้ (แตะ) ; เข็มเกจ = RPM เสมอ
  Widget _center(BoxConstraints cs, AppTheme th) {
    final cfg = Cfg.i;
    final w = cs.maxWidth, h = cs.maxHeight;
    const tileH = 80.0;
    // ขอบโลหะเกจยื่นออก ~10% ของรัศมี -> จุดศูนย์กลางเลื่อนลง (cy = 1.1r + 2) ไม่ให้ขอบบนโดนตัด
    final r = math.max(60.0, math.min(w / 2.2 - 4, (h - tileH - 6) / 1.84));
    final cx = w / 2, cy = gaugeCy(r);
    final rpm = c.t.rpm;
    final frac = rpm == null ? 0.0 : (rpm / kMaxRpm).clamp(0.0, 1.0).toDouble();
    final ck = cfg.ctr[0];
    final ckd = kKeys[ck];
    final sp = c.keyVal(ck);
    final cLabel = ck == kSpd ? 'km/h · ${c.speedSrc}' : (ckd.unit.isEmpty ? ckd.name : '${ckd.name} · ${ckd.unit}');
    final tileW = math.min(math.max(r * 1.5, 150.0), 230.0);

    return Stack(children: [
      // TIWSHOP: หน้าปัด/ขีด/ตัวเลข วาดครั้งเดียวเก็บเป็นเลเยอร์ (เดิมวาดใหม่ทุกเฟรม + เบลอ 44 แท่ง = กระตุก)
      Positioned.fill(
        child: RepaintBoundary(child: CustomPaint(painter: GaugeDialPainter(r: r, th: th, shift: cfg.shift))),
      ),
      Positioned.fill(
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: frac),
            duration: const Duration(milliseconds: 70),   // TIWSHOP: เข็มตามค่าไวขึ้น (เดิม 140 ms)
            builder: (_, v, __) => CustomPaint(painter: GaugePainter(frac: v, r: r, th: th, shift: cfg.shift)),
          ),
        ),
      ),
      Positioned(
        left: cx - r * 0.5, width: r, top: cy - r * 0.34, height: r * 0.72,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => pickKey(context, cfg.ctr, 0, speedSrc: true),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(sp == null ? '--' : sp.toStringAsFixed(ckd.dec),
                    style: TextStyle(fontFamily: kFont, fontSize: 60, color: Colors.white, shadows: [
                      Shadow(color: Color.lerp(th.c, Colors.black, 0.55)!, offset: const Offset(2.5, 2.5)),
                    ])),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: Color.lerp(th.c, Colors.black, 0.55),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: th.c2, width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(cLabel, style: TextStyle(fontSize: math.max(10.0, r * 0.085), color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(width: 3),
                Icon(Icons.swap_horiz, size: math.max(12.0, r * 0.1), color: th.c2),
              ]),
            ),
          ]),
        ),
      ),
      Positioned(
        left: cx - tileW / 2, width: tileW, top: cy + 0.74 * r, height: tileH,
        child: _slotTile(cfg.ctr[1], () => pickKey(context, cfg.ctr, 1, speedSrc: true), false, vs: 26, bm: 0, minmax: true),
      ),
    ]);
  }

  Widget _chip(String s, Color col) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(s, style: const TextStyle(fontFamily: kFont, fontSize: 8.5)),
        ]),
      );

  Widget _btn(String s, VoidCallback f, AppTheme th, {bool active = false}) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? th.c.withOpacity(0.3) : Colors.black45,
            border: Border.all(color: th.c, width: 1.4),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      );

  Widget _iconBtn(IconData ic, AppTheme th, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(color: th.c, width: 1.4),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(ic, size: 20, color: th.c),
        ),
      );
}

// ---------- กราฟ 4 เส้น (RPM / TPS / GPS / AFR) ----------
class GraphPainter extends CustomPainter {
  final List<List<double>> hist;
  final int on;
  GraphPainter({required this.hist, required this.on});

  static const cols = <Color>[Color(0xFFFF3B3B), kTpsBlue, Color(0xFF3CFF8A), Color(0xFFFFC233)];

  static double norm(int i, double v) {
    double lo = 0, hi = 1;
    switch (i) {
      case 0: hi = kMaxRpm; break;
      case 1: hi = 100; break;
      case 2: hi = 180; break;
      default: lo = 10; hi = 18;
    }
    return ((v - lo) / (hi - lo)).clamp(0.0, 1.0).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (int k = 0; k <= 4; k++) {
      final y = pad + (size.height - 2 * pad) * k / 4;
      canvas.drawLine(Offset(pad, y), Offset(size.width - pad, y), grid);
    }
    final step = (size.width - 2 * pad) / (GaugeController.gN - 1);
    for (int i = 0; i < 4; i++) {
      if ((on & (1 << i)) == 0) continue;
      final h = hist[i];
      final n = h.length;
      final path = Path();
      bool pen = false;
      for (int j = 0; j < n; j++) {
        final v = h[j];
        if (v.isNaN) {
          pen = false;
          continue;
        }
        final x = size.width - pad - (n - 1 - j) * step;
        final y = size.height - pad - norm(i, v) * (size.height - 2 * pad);
        if (!pen) {
          path.moveTo(x, y);
          pen = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = cols[i].withOpacity(0.25)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6);
      canvas.drawPath(
          path,
          Paint()
            ..color = cols[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(GraphPainter o) => true;
}

// ---------- แสงเตือนแดงจากขอบ 4 ด้าน ----------
class EdgeGlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final d = math.min(size.width, size.height) * 0.32;
    void edge(Rect r, Alignment a, Alignment b) {
      canvas.drawRect(
          r,
          Paint()
            ..shader = LinearGradient(begin: a, end: b, colors: const [Color(0xE6FF1A1A), Color(0x00FF1A1A)]).createShader(r));
    }

    edge(Rect.fromLTWH(0, 0, size.width, d), Alignment.topCenter, Alignment.bottomCenter);
    edge(Rect.fromLTWH(0, size.height - d, size.width, d), Alignment.bottomCenter, Alignment.topCenter);
    edge(Rect.fromLTWH(0, 0, d, size.height), Alignment.centerLeft, Alignment.centerRight);
    edge(Rect.fromLTWH(size.width - d, 0, d, size.height), Alignment.centerRight, Alignment.centerLeft);
  }

  @override
  bool shouldRepaint(EdgeGlowPainter o) => false;
}

// ---------- สไตล์ FTP: แผงเรืองแสง (ไล่สีธีม -> ดำ + แสงเรือง + เงากระจก + มุมฉากสว่าง) ----------
class FxPanel extends StatelessWidget {
  final Color col; // สีกรอบ/แสง (ปกติ = สีธีม)
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius, glow; // glow = ความแรงแสงรอบกรอบ 0..1
  final bool strong; // กรอบหนา (ใช้ตอนเตือน)
  const FxPanel({super.key, required this.col, required this.child, this.padding = EdgeInsets.zero, this.radius = 12, this.glow = 0.45, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final top = Color.alphaBlend(col.withOpacity(0.30), const Color(0xFF060608));
    // TIWSHOP: กรอบ + แสงเรือง (blur) อยู่เลเยอร์แยกที่แคชไว้ -> ตัวเลขเปลี่ยนไม่ต้องคำนวณเบลอใหม่ทุกครั้ง
    final frame = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [top.withOpacity(0.90), const Color(0xE6040508)],
          stops: const [0.0, 0.78],
        ),
        border: Border.all(color: Color.lerp(col, Colors.white, 0.15)!.withOpacity(strong ? 1.0 : 0.9), width: strong ? 2.0 : 1.3),
      ),
      child: CustomPaint(foregroundPainter: _FxPanelPainter(col, radius, glow, strong)),
    );
    return Stack(fit: StackFit.passthrough, clipBehavior: Clip.none, children: [
      Positioned.fill(child: RepaintBoundary(child: frame)),
      Padding(padding: padding, child: child),
    ]);
  }
}

class _FxPanelPainter extends CustomPainter {
  final Color col;
  final double radius, glow;
  final bool strong;
  _FxPanelPainter(this.col, this.radius, [this.glow = 0.45, this.strong = false]);

  @override
  void paint(Canvas canvas, Size s) {
    // TIWSHOP: แสงเรืองรอบกรอบแบบไม่ใช้เบลอ (เส้นโปร่งแสงซ้อน 3 ชั้น) -> วาดเร็วมาก
    final box = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(radius));
    for (final k in const [(7.0, 0.10), (4.5, 0.20), (2.2, 0.38)]) {
      canvas.drawRRect(box.inflate(k.$1 * (strong ? 1.4 : 1.0) / 2), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = k.$1 * (strong ? 1.4 : 1.0)
        ..color = col.withOpacity((k.$2 * glow / 0.45).clamp(0.0, 1.0).toDouble()));
    }
    // เงากระจกครึ่งบน
    final sheen = RRect.fromRectAndRadius(Rect.fromLTWH(3, 3, s.width - 6, s.height * 0.42), Radius.circular(math.max(0.0, radius - 3)));
    canvas.drawRRect(
        sheen,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white.withOpacity(0.07), Colors.white.withOpacity(0.0)])
              .createShader(sheen.outerRect));
    // เส้นไฮไลต์ขอบบน
    canvas.drawLine(Offset(radius + 2, 1.2), Offset(s.width - radius - 2, 1.2),
        Paint()
          ..color = Color.lerp(col, Colors.white, 0.6)!.withOpacity(0.9)
          ..strokeWidth = 1);
    // มุมฉากสว่าง 4 มุม
    final arm = math.min(14.0, math.min(s.width, s.height) * 0.22);
    final cornerGlow = Paint()
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..color = col.withOpacity(0.45);
    final line = Paint()
      ..color = Color.lerp(col, Colors.white, 0.5)!
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final k in const [(0.0, 0.0, 1.0, 1.0), (1.0, 0.0, -1.0, 1.0), (0.0, 1.0, 1.0, -1.0), (1.0, 1.0, -1.0, -1.0)]) {
      final cx = k.$1 * s.width, cy = k.$2 * s.height, sx = k.$3, sy = k.$4;
      final p = Path()
        ..moveTo(cx + sx * 4, cy + sy * (4 + arm))
        ..lineTo(cx + sx * 4, cy + sy * 4)
        ..lineTo(cx + sx * (4 + arm), cy + sy * 4);
      canvas.drawPath(p, cornerGlow);
      canvas.drawPath(p, line);
    }
  }

  @override
  bool shouldRepaint(_FxPanelPainter o) => o.col != col || o.radius != radius || o.glow != glow || o.strong != strong;
}

// ---------- บาร์แท่งเซกเมนต์ (แท่งเฉียง ผิวมัน + เรืองแสง) ----------
class SegBar extends StatelessWidget {
  final double frac;
  final Color Function(double) color;
  final int n;
  const SegBar({super.key, required this.frac, required this.color, this.n = 18});

  @override
  Widget build(BuildContext context) => SizedBox(height: 7, width: double.infinity, child: CustomPaint(painter: _SegBarPainter(frac, color, n)));
}

class _SegBarPainter extends CustomPainter {
  final double frac;
  final Color Function(double) color;
  final int n;
  _SegBarPainter(this.frac, this.color, this.n);

  @override
  void paint(Canvas canvas, Size s) {
    final sk = s.height * 0.32, gap = 2.0;
    final sw = (s.width - sk * 2 + gap) / n - gap;
    // TIWSHOP: แสงเรืองใต้แท่งที่ติด = เบลอครั้งเดียว (เดิมเบลอทีละแท่ง)
    final litN = List.generate(n, (i) => (i + 0.5) / n <= frac).where((b) => b).length;
    if (litN > 0) {
      final xe = sk + litN * (sw + gap) + sk;
      canvas.drawRect(Rect.fromLTWH(sk * 0.5, -2, xe - sk * 0.5, s.height + 4), Paint()
        ..shader = LinearGradient(colors: [color(0.0).withOpacity(0.25), color(litN / n).withOpacity(0.25)])
            .createShader(Rect.fromLTWH(0, 0, xe, s.height)));
    }
    for (int i = 0; i < n; i++) {
      final pos = (i + 0.5) / n;
      final lit = pos <= frac;
      final col = color(pos);
      final x0 = sk + i * (sw + gap), x1 = x0 + sw;
      final p = Path()
        ..moveTo(x0 + sk, 0)
        ..lineTo(x1 + sk, 0)
        ..lineTo(x1 - sk, s.height)
        ..lineTo(x0 - sk, s.height)
        ..close();
      if (!lit) {
        canvas.drawPath(p, Paint()..color = const Color(0xFF262A36));
        continue;
      }
      canvas.drawPath(p, Paint()..color = col);
      final hy = s.height * 0.42;
      final g = Path()
        ..moveTo(x0 + sk, 0)
        ..lineTo(x1 + sk, 0)
        ..lineTo(x1 + sk * 0.2, hy)
        ..lineTo(x0 + sk * 0.2, hy)
        ..close();
      canvas.drawPath(g, Paint()..color = Color.lerp(col, Colors.white, 0.45)!);
    }
  }

  @override
  bool shouldRepaint(_SegBarPainter o) => o.frac != frac || o.n != n || o.color(0.0) != color(0.0) || o.color(1.0) != color(1.0);   // สีเป็นฟังก์ชันที่สร้างใหม่ทุกรอบ -> เทียบสีจริงแทน
}

// ---------- กรอบแสดงค่า ----------
class StatTile extends StatelessWidget {
  final AppTheme th;
  final String label, unit, value;
  final Color? valueColor;
  final bool alert, blinkOn;
  final double? bar;
  final Color Function(double)? barColor;
  final String? mn, mx;
  final VoidCallback? onTap;
  final double bottomMargin, valueSize;
  const StatTile({
    super.key, required this.th, required this.label, required this.unit, required this.value,
    this.valueColor, this.alert = false, this.blinkOn = false, this.bar, this.barColor,
    this.mn, this.mx, this.onTap, this.bottomMargin = 6, this.valueSize = 30,
  });

  @override
  Widget build(BuildContext context) {
    final active = alert && blinkOn; // กรอบกระพริบแดงเมื่อค่าเกินที่ตั้ง
    final col = active ? kBad : th.c;
    final vcol = alert ? kBad : (valueColor ?? Colors.white);
    final glow = alert ? kBad : (valueColor ?? th.c);
    return RepaintBoundary(child: GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomMargin),
        child: FxPanel(
          col: col, glow: active ? 0.85 : 0.45, strong: active,
          padding: const EdgeInsets.fromLTRB(9, 6, 9, 5),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Color.lerp(col, Colors.black, 0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFont, fontSize: 8, color: Colors.white)),
                ),
              ),
              Text(unit, style: TextStyle(fontFamily: kFont, fontSize: 8, color: th.c2)),
            ]),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value,
                      style: TextStyle(fontFamily: kFont, fontSize: valueSize, color: vcol, shadows: [
                        Shadow(color: Color.lerp(glow, Colors.black, 0.55)!, offset: const Offset(1.5, 1.5)),
                      ])),
                ),
              ),
            ),
            if (bar != null && barColor != null) SegBar(frac: bar!, color: barColor!),
            if (mn != null && mx != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: '▼ ', style: TextStyle(color: kGreen, fontSize: 9)),
                    TextSpan(text: mn!, style: const TextStyle(color: kGreen, fontSize: 12)),
                  ])),
                  Text.rich(TextSpan(children: [
                    const TextSpan(text: '▲ ', style: TextStyle(color: kBad, fontSize: 9)),
                    TextSpan(text: mx!, style: const TextStyle(color: kBad, fontSize: 12)),
                  ])),
                ]),
              ),
          ]),
        ),
      ),
    ));
  }
}

/// จุดศูนย์กลางเกจ (แนวตั้ง) ในกล่องเกจ: ใช้ร่วมกันทั้ง _center / GaugePainter
double gaugeCy(double r) => r * 1.1 + 2;

// ---------- เกจ RPM (TIWSHOP: แยก 2 เลเยอร์ให้ลื่น) ----------
// GaugeDialPainter = ส่วนที่ไม่เปลี่ยน (หน้าปัด ขอบโลหะ นีออน แท่งที่ยังไม่ติด ขีด ตัวเลข) วาดครั้งเดียว แคชใน RepaintBoundary
// GaugePainter     = ส่วนที่ขยับ (แท่งที่ติด หัวแท่ง เข็ม) ใช้เบลอแค่ 3 ครั้ง/เฟรม (เดิมเบลอทุกแท่ง ~44 ครั้ง + จัดตัวเลข 16 ตัวทุกเฟรม)
const _gStart = 0.75 * math.pi, _gSweep = 1.5 * math.pi, _gN = 44;

class GaugeDialPainter extends CustomPainter {
  final double r;
  final AppTheme th;
  final int shift;
  GaugeDialPainter({required this.r, required this.th, required this.shift});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, gaugeCy(r));
    Rect circ(double rr) => Rect.fromCircle(center: c, radius: rr);
    const start = _gStart, sweep = _gSweep;

    // หน้าปัดมืด (ไล่จากกลางสีธีมจาง -> ดำ) + ขอบโลหะ
    canvas.drawCircle(
        c,
        r * 1.04,
        Paint()
          ..shader = RadialGradient(colors: [
            Color.alphaBlend(th.c.withOpacity(0.10), const Color(0xF20A1020)),
            const Color(0xF2020409),
          ]).createShader(circ(r * 1.04)));
    canvas.drawCircle(
        c,
        r * 1.07,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.045
          ..shader = const SweepGradient(colors: [
            Color(0xFF3A4150), Color(0xFFE6EBF2), Color(0xFF59606E), Color(0xFFB8C0CC), Color(0xFF3A4150),
          ], transform: GradientRotation(-math.pi / 4)).createShader(circ(r * 1.07)));
    canvas.drawCircle(c, r * 1.095, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF0F141E));
    // เส้นนีออนขอบนอกสีธีม
    for (final k in const [(10.0, 0.10), (6.0, 0.22), (3.5, 0.5)]) {
      canvas.drawArc(circ(r), start, sweep, false, Paint()
        ..color = th.c.withOpacity(k.$2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = k.$1);
    }
    canvas.drawArc(circ(r), start, sweep, false, Paint()
      ..color = Color.lerp(th.c, Colors.white, 0.4)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);

    // แท่งเซกเมนต์ที่ยังไม่ติด (ทุกแท่ง - เลเยอร์บนจะทับแท่งที่ติด)
    final thick = r * 0.13;
    final rb = r - thick / 2;
    const seg = sweep / _gN;
    for (int i = 0; i < _gN; i++) {
      final pos = (i + 0.5) / _gN;
      final inZone = pos * kMaxRpm >= shift;
      final a0 = start + seg * i + seg * 0.1;
      canvas.drawArc(circ(rb), a0, seg * 0.8, false, Paint()
        ..color = inZone ? const Color(0xFF46141A) : const Color(0xFF1C202C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick);
      canvas.drawArc(circ(r - thick * 0.1), a0, seg * 0.8, false, Paint()
        ..color = inZone ? const Color(0xFF6E282C) : const Color(0xFF3C4252)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }

    // วงบางด้านใน + โซนแดงเริ่มที่ SHIFT RPM
    final r2 = r * 0.80;
    canvas.drawArc(circ(r2), start, sweep, false, Paint()
      ..color = Color.lerp(th.c, Colors.black, 0.5)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    final zs = (shift / kMaxRpm).clamp(0.0, 1.0).toDouble();
    if (zs < 1.0) {
      canvas.drawArc(circ(r2), start + sweep * zs, sweep * (1 - zs), false, Paint()
        ..color = const Color(0xFFFF2A2A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
    }

    // ขีดหลัก/ขีดย่อย และตัวเลข 0..15
    for (int k = 0; k <= 15; k++) {
      final ang = start + sweep * k / 15;
      final dir = Offset(math.cos(ang), math.sin(ang));
      final zone = k * 1000 >= shift;
      canvas.drawLine(c + dir * (r2 - r * 0.05), c + dir * r2, Paint()
        ..color = zone ? const Color(0xFFFF2A2A) : Colors.white70
        ..strokeWidth = 2.2);
      if (k < 15) {
        for (final q in const [0.25, 0.5, 0.75]) {
          final aa = start + sweep * (k + q) / 15;
          final dd = Offset(math.cos(aa), math.sin(aa));
          canvas.drawLine(c + dd * (r2 - r * (q == 0.5 ? 0.035 : 0.022)), c + dd * r2, Paint()
            ..color = (k + q) * 1000 >= shift ? const Color(0xFFFF5050) : const Color(0xFF78808C)
            ..strokeWidth = 1);
        }
      }
      final tp = TextPainter(
        text: TextSpan(text: '$k', style: TextStyle(fontFamily: kFont, fontSize: r * 0.072, color: zone ? const Color(0xFFFF7A7A) : const Color(0xFFFFC233))),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = c + dir * (r * 0.64);
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.drawCircle(c, r * 0.30, Paint()
      ..color = Color.lerp(th.c, Colors.black, 0.3)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(GaugeDialPainter o) => o.r != r || o.th != th || o.shift != shift;
}

class GaugePainter extends CustomPainter {
  final double frac, r;
  final AppTheme th;
  final int shift;
  GaugePainter({required this.frac, required this.r, required this.th, required this.shift});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, gaugeCy(r));
    Rect circ(double rr) => Rect.fromCircle(center: c, radius: rr);
    const start = _gStart, sweep = _gSweep, seg = _gSweep / _gN;
    final thick = r * 0.13;
    final rb = r - thick / 2;
    final litN = (frac * _gN).round();

    if (litN > 0) {
      // แสงเรืองใต้แท่งที่ติด: เบลอครั้งเดียวทั้งช่วง (สีไล่ตามรอบ)
      canvas.drawArc(circ(rb), start, seg * litN, false, Paint()
        ..shader = SweepGradient(
          endAngle: sweep,
          colors: [for (int k = 0; k <= 10; k++) rpmColor(k / 10 * kMaxRpm, shift).withOpacity(0.28)],
          transform: const GradientRotation(start),
        ).createShader(circ(rb))
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick * 1.6);
    }
    for (int i = 0; i < litN && i < _gN; i++) {
      final pos = (i + 0.5) / _gN;
      final a0 = start + seg * i + seg * 0.1;
      final tip = i == litN - 1;
      final cc = tip ? const Color(0xFFEBFAFF) : rpmColor(pos * kMaxRpm, shift);
      canvas.drawArc(circ(rb), a0, seg * 0.8, false, Paint()
        ..color = cc
        ..style = PaintingStyle.stroke
        ..strokeWidth = thick);
      if (!tip) {
        canvas.drawArc(circ(r - thick * 0.22), a0, seg * 0.8, false, Paint()
          ..color = Color.lerp(cc, Colors.white, 0.5)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = thick * 0.35);
        canvas.drawArc(circ(r - thick * 0.86), a0, seg * 0.8, false, Paint()
          ..color = Color.lerp(cc, Colors.black, 0.3)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = thick * 0.22);
      }
    }
    // แสงวาบที่หัวแท่ง
    if (litN > 0) {
      final a = start + seg * (litN - 0.5);
      final tipC = c + Offset(math.cos(a), math.sin(a)) * rb;
      canvas.drawCircle(tipC, thick * 1.3, Paint()..color = const Color(0xFF8CD7FF).withOpacity(0.18));
      canvas.drawCircle(tipC, thick * 0.8, Paint()..color = const Color(0xFF8CD7FF).withOpacity(0.28));
    }

    // เข็มทรงสามเหลี่ยม 2 โทน + แสงสีธีม
    final ang = start + sweep * frac;
    final dir = Offset(math.cos(ang), math.sin(ang)), nrm = Offset(-dir.dy, dir.dx);
    final p1 = c + dir * (r * 0.30), p2 = c + dir * (r * 0.86);
    canvas.drawLine(p1, p2, Paint()
      ..color = th.c.withOpacity(0.35)
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round);
    canvas.drawPath(Path()..moveTo((p1 + nrm * 3.2).dx, (p1 + nrm * 3.2).dy)..lineTo(p2.dx, p2.dy)..lineTo((p1 - nrm * 3.2).dx, (p1 - nrm * 3.2).dy)..close(),
        Paint()..color = Colors.white);
    canvas.drawPath(Path()..moveTo((p1 + nrm * 3.2).dx, (p1 + nrm * 3.2).dy)..lineTo(p2.dx, p2.dy)..lineTo(p1.dx, p1.dy)..close(),
        Paint()..color = Color.lerp(th.c, Colors.white, 0.55)!);
  }

  @override
  bool shouldRepaint(GaugePainter o) => o.frac != frac || o.r != r || o.th != th || o.shift != shift;
}

// ---------- ปุ่ม - / + กดค้างเพื่อเพิ่ม/ลดต่อเนื่อง ----------
class StepBtn extends StatefulWidget {
  final String label;
  final VoidCallback onStep;
  final AppTheme th;
  const StepBtn({super.key, required this.label, required this.onStep, required this.th});
  @override
  State<StepBtn> createState() => _StepBtnState();
}

class _StepBtnState extends State<StepBtn> {
  Timer? _t;

  void _stop() {
    _t?.cancel();
    _t = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onStep,
      onLongPressStart: (_) {
        widget.onStep();
        _t = Timer.periodic(const Duration(milliseconds: 90), (_) => widget.onStep());
      },
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: Container(
        width: 38, height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black45,
          border: Border.all(color: widget.th.c, width: 1.4),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(widget.label, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: widget.th.c, height: 1.1)),
      ),
    );
  }
}

// ---------- หน้า SETTING ----------
class SettingsPage extends StatefulWidget {
  final GaugeController c;
  const SettingsPage({super.key, required this.c});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ui.Image? preview;
  Uint8List? raw565;
  double? progress;
  String? msg;
  bool busy = false;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    Cfg.i.addListener(_rebuild);
    widget.c.addListener(_rebuild);
  }

  @override
  void dispose() {
    Cfg.i.removeListener(_rebuild);
    widget.c.removeListener(_rebuild);
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1280);
      final src = (await codec.getNextFrame()).image;

      // ครอปแบบ cover ให้พอดี 320x240 ตามจอบอร์ด
      const w = 320.0, h = 240.0;
      final rec = ui.PictureRecorder();
      final cv = Canvas(rec);
      cv.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.black);
      final sw = src.width.toDouble(), sh = src.height.toDouble();
      final sc = math.max(w / sw, h / sh);
      final dw = sw * sc, dh = sh * sc;
      cv.drawImageRect(src, Rect.fromLTWH(0, 0, sw, sh), Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
          Paint()..filterQuality = FilterQuality.high);
      final out = await rec.endRecording().toImage(320, 240);
      final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return;
      final rgba = bd.buffer.asUint8List();
      final b = Uint8List(320 * 240 * 2);
      for (int i = 0; i < 320 * 240; i++) {
        final r = rgba[i * 4], g = rgba[i * 4 + 1], bl = rgba[i * 4 + 2];
        final v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (bl >> 3);
        b[i * 2] = v & 0xFF;
        b[i * 2 + 1] = (v >> 8) & 0xFF;
      }
      setState(() {
        preview = out;
        raw565 = b;
        msg = null;
        progress = null;
      });
    } catch (e) {
      setState(() => msg = 'เลือกรูปไม่สำเร็จ: $e');
    }
  }

  Future<void> _send() async {
    if (raw565 == null || busy) return;
    setState(() {
      busy = true;
      progress = 0;
      msg = null;
    });
    final err = await widget.c.sendLogo(raw565!, (p) {
      if (mounted) setState(() => progress = p);
    });
    if (!mounted) return;
    setState(() {
      busy = false;
      progress = null;
      msg = err ?? 'ส่งโลโก้สำเร็จ — จะแสดงตอนเปิดบอร์ดครั้งถัดไป';
    });
  }

  Future<void> _reset() async {
    if (busy) return;
    final err = await widget.c.resetLogo();
    if (!mounted) return;
    setState(() => msg = err ?? 'คืนค่าโลโก้เดิมของบอร์ดแล้ว');
  }

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final connected = widget.c.link == LinkState.connected;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        RepaintBoundary(child: _Bg(dim: 0.35, idx: cfg.bgIdx)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: Icon(Icons.arrow_back, color: th.c)),
                Text('SETTING', style: TextStyle(fontFamily: kFont, fontSize: 18, color: th.c)),
              ]),
              Expanded(
                child: SingleChildScrollView(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(children: [
                        _panel(th, 'ธีมสี', Wrap(spacing: 14, runSpacing: 14, children: [
                          for (int i = 0; i < kThemes.length; i++) _themeDot(i),
                        ])),
                        const SizedBox(height: 12),
                        _panel(th, 'พื้นหลัง', Wrap(spacing: 12, runSpacing: 12, children: [
                          for (int i = 0; i < kBgs.length; i++) _bgDot(i),
                        ])),
                        const SizedBox(height: 12),
                        _panel(
                          th,
                          'แจ้งเตือน',
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            _stepper('SHIFT LIGHT RPM', '${cfg.shift}', () => cfg.addShift(-1000), () => cfg.addShift(1000), th),
                            const SizedBox(height: 12),
                            _stepper('TEMP', '${cfg.tempWarn} °C', () => cfg.addTemp(-1), () => cfg.addTemp(1), th),
                            const SizedBox(height: 14),
                            _action('RESET MIN/MAX', Icons.refresh, th, () {
                              widget.c.resetMinMax();
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(duration: Duration(seconds: 1), content: Text('รีเซ็ตค่าต่ำสุด/สูงสุดแล้ว')));
                            }),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        _panel(
                          th,
                          'เฟิร์มแวร์',
                          Builder(builder: (_) {
                            final fw = widget.c.t.fwText;
                            final connected = widget.c.link == LinkState.connected;
                            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              _infoRow('เกจ (BLE)',
                                  !connected ? 'ยังไม่ได้เชื่อมต่อ' : (fw != null ? 'FW $fw' : 'ไม่ทราบ (เฟิร์มแวร์เก่า)'),
                                  col: !connected ? kAmber : (fw != null ? kGreen : kAmber)),
                              const SizedBox(height: 6),
                              Builder(builder: (_) {
                                final e = widget.c.t.ecu;
                                final id = widget.c.t.ecmId;
                                return _infoRow('กล่อง ECU',
                                    !connected ? '-' : (e != null ? '${e.name}  (${e.shin ? "Shindengen" : "Keihin"})' : (id != null ? 'ไม่รู้จัก ($id)' : '-')),
                                    col: e != null ? kGreen : (!connected ? null : kAmber));
                              }),
                              if (connected && widget.c.t.ecu != null) ...[
                                const SizedBox(height: 4),
                                _infoRow('พาร์ท', widget.c.t.ecu!.part),
                              ],
                              const SizedBox(height: 6),
                              _infoRow('TIWSHOP', 'FW $kAppFw'),
                              if (connected && fw != null && fw != kAppFw)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text('เวอร์ชันเกจกับแอพไม่ตรงกัน — บางฟีเจอร์อาจทำงานไม่ครบ',
                                      style: TextStyle(color: kAmber, fontSize: 11)),
                                ),
                            ]);
                          }),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _panel(
                        th,
                        'โลโก้ TIWSHOP บนบอร์ด',
                        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Center(
                            child: Container(
                              width: 220, height: 165,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: th.c, width: 1.4),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(7),
                                child: preview == null
                                    ? const Center(child: Text('ยังไม่ได้เลือกรูป', style: TextStyle(color: Colors.white38, fontSize: 12)))
                                    : RawImage(image: preview, fit: BoxFit.cover),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Center(child: Text('320 x 240 px', style: TextStyle(color: Colors.white38, fontSize: 10))),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            _action('เลือกรูป', Icons.image, th, _pick, enabled: !busy),
                            _action('ส่งไปบอร์ด', Icons.upload, th, _send, enabled: !busy && raw565 != null && connected),
                            _action('คืนโลโก้เดิม', Icons.restore, th, _reset, enabled: !busy && connected),
                          ]),
                          if (!connected)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text('ต้องเชื่อมต่อบอร์ดก่อนจึงจะส่งรูปได้', style: TextStyle(color: kAmber, fontSize: 11)),
                            ),
                          if (progress != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(value: progress, color: th.c, backgroundColor: Colors.white12, minHeight: 5),
                            ),
                          if (msg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg!, style: const TextStyle(fontSize: 12))),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc, AppTheme th) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: kFont, fontSize: 10, color: Colors.white70)),
          const SizedBox(height: 6),
          Row(children: [
            StepBtn(label: '−', onStep: dec, th: th),
            const SizedBox(width: 10),
            SizedBox(
              width: 110,
              child: Center(
                child: Text(value,
                    style: TextStyle(fontFamily: kFont, fontSize: 17, color: Colors.white)),
              ),
            ),
            const SizedBox(width: 10),
            StepBtn(label: '+', onStep: inc, th: th),
          ]),
        ],
      );

  Widget _infoRow(String a, String b, {Color? col}) => Row(children: [
        SizedBox(width: 150, child: Text(a, style: const TextStyle(fontSize: 12.5, color: Colors.white60))),
        Expanded(child: Text(b, style: TextStyle(fontSize: 13, color: col ?? Colors.white, fontWeight: FontWeight.bold))),
      ]);

  Widget _panel(AppTheme th, String title, Widget child) => SizedBox(
        width: double.infinity,
        child: FxPanel(
          col: th.c, glow: 0.3, padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );

  Widget _bgDot(int i) {
    final b = kBgs[i];
    final sel = Cfg.i.bgIdx == i;
    final Color fill = i == 0 ? const Color(0xFF2E8A1A) : (i == kBgs.length - 1 ? Colors.black : Color.lerp(Colors.black, b.color, i == 8 ? 0.45 : 0.6)!);
    return GestureDetector(
      onTap: () => Cfg.i.setBg(i),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52, height: 36,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 3 : 1),
          ),
          child: sel ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
        ),
        const SizedBox(height: 4),
        Text(b.name, style: TextStyle(fontSize: 11, color: sel ? Colors.white : Colors.white60)),
      ]),
    );
  }

  Widget _themeDot(int i) {
    final t = kThemes[i];
    final sel = Cfg.i.themeIdx == i;
    return GestureDetector(
      onTap: () => Cfg.i.setTheme(i),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: t.c,
            shape: BoxShape.circle,
            border: Border.all(color: sel ? Colors.white : Colors.white24, width: sel ? 3 : 1),
          ),
          child: sel ? const Icon(Icons.check, color: Colors.black) : null,
        ),
        const SizedBox(height: 4),
        Text(t.name, style: TextStyle(fontSize: 11, color: sel ? Colors.white : Colors.white60)),
      ]),
    );
  }

  Widget _action(String s, IconData ic, AppTheme th, VoidCallback f, {bool enabled = true}) => Opacity(
        opacity: enabled ? 1 : 0.4,
        child: InkWell(
          onTap: enabled ? f : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: th.c, width: 1.3), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ic, size: 16, color: th.c),
              const SizedBox(width: 6),
              Text(s, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      );
}

/// หาตำแหน่ง (ทศนิยม) ของค่า v บนแกน a (รองรับแกนเรียงขึ้นหรือลง) ; อยู่นอกช่วง = ปลายที่ใกล้สุด
double? _axisFrac(List<double> a, double? v) {
  if (v == null || a.isEmpty) return null;
  if (a.length == 1) return 0;
  for (int k = 0; k < a.length - 1; k++) {
    final x0 = a[k], x1 = a[k + 1];
    if (x0.isNaN || x1.isNaN) continue;
    if (v >= math.min(x0, x1) && v <= math.max(x0, x1)) {
      return x1 == x0 ? k.toDouble() : k + (v - x0) / (x1 - x0);
    }
  }
  return (v - a.first).abs() < (v - a.last).abs() ? 0.0 : (a.length - 1).toDouble();
}

Future<bool> askYes(BuildContext context, String title, String msg, {String ok = 'ตกลง', Color col = kAmber}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF14141A),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('ยกเลิก')),
        TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: Text(ok, style: TextStyle(color: col))),
      ],
    ),
  );
  return r == true;
}

class _TP {
  static final Map<String, TextPainter> _m = {};
  static TextPainter get(String s, double fs, Color col, {bool bold = false, double maxW = double.infinity}) {
    final k = '$s|$fs|${col.hashCode}|$bold|$maxW';
    var tp = _m[k];
    if (tp == null) {
      if (_m.length > 2500) _m.clear();
      tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: fs, color: col, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: maxW);
      _m[k] = tp;
    }
    return tp;
  }

  static void center(Canvas cv, TextPainter tp, Offset c) => tp.paint(cv, c - Offset(tp.width / 2, tp.height / 2));
}

// ---------- หน้าต่างเลือกเกจ (กด "เชื่อมต่อ") : เกจแต่ละตัวชื่อไม่ซ้ำ TIWSHOP-XXXX (เกจรุ่นเก่า FTP-GAUGE-XXXX ก็ต่อได้: ค้นหาด้วย UUID) ----------
Future<void> pickGauge(BuildContext context, GaugeController c) async {
  if (!await c.prepareBle()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('เปิดบลูทูธก่อน แล้วกดเชื่อมต่ออีกครั้ง')));
    }
    return;
  }
  if (!context.mounted) return;
  final th = Cfg.i.t;
  final found = <String, ScanResult>{};
  bool scanning = true;
  StreamSubscription? sub, run;
  void Function(void Function())? setD;
  Future<void> scan() async {
    found.clear();
    scanning = true;
    setD?.call(() {});
    await c.startPickScan();
  }

  sub = FlutterBluePlus.scanResults.listen((rs) {
    for (final r in rs) {
      found[r.device.remoteId.str] = r;
    }
    setD?.call(() {});
  });
  run = FlutterBluePlus.isScanning.listen((v) {
    scanning = v;
    setD?.call(() {});
  });
  scan();
  final picked = await showDialog<ScanResult>(
    context: context,
    builder: (dctx) => StatefulBuilder(builder: (dctx, sd) {
      setD = sd;
      final list = found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
      String nm(ScanResult r) {
        final a = r.advertisementData.advName;
        return a.isNotEmpty ? a : (r.device.platformName.isNotEmpty ? r.device.platformName : 'TIWSHOP');
      }

      Widget bars(int rssi) {
        final lvl = rssi > -55 ? 4 : rssi > -67 ? 3 : rssi > -78 ? 2 : 1;
        return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (int k = 0; k < 4; k++)
            Container(width: 5, height: 6.0 + k * 4, margin: const EdgeInsets.only(right: 2), color: k < lvl ? th.c : Colors.white24),
        ]);
      }

      return AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: th.c, width: 1.3)),
        title: Row(children: [
          Expanded(child: Text('เลือกเกจที่จะเชื่อมต่อ', style: TextStyle(fontSize: 17, color: th.c, fontWeight: FontWeight.bold))),
          if (scanning) const Text('กำลังสแกน…', style: TextStyle(fontSize: 12.5, color: kAmber)),
        ]),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(list.isEmpty ? (scanning ? 'กำลังค้นหาเกจ TIWSHOP ใกล้ ๆ …' : 'ไม่พบเกจ — เปิดเกจ และตรวจว่าเปิด MOBILE APP (BLE) = ON')
                : 'พบ ${list.length} เกจ เรียงจากสัญญาณแรงสุด (ใกล้สุด)',
                style: const TextStyle(fontSize: 12.5, color: Colors.white60)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(shrinkWrap: true, children: [
                for (final r in list)
                  Builder(builder: (_) {
                    final last = r.device.remoteId.str == c.gaugeId;
                    return InkWell(
                      onTap: () => Navigator.of(dctx).pop(r),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        decoration: BoxDecoration(
                          color: last ? th.c.withOpacity(0.18) : Colors.white.withOpacity(0.04),
                          border: Border.all(color: last ? th.c : Colors.white24, width: last ? 1.5 : 1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(nm(r), style: const TextStyle(fontFamily: kFont, fontSize: 13)),
                              if (last) const Text('เชื่อมต่อล่าสุด', style: TextStyle(fontSize: 11.5, color: kGreen)),
                            ]),
                          ),
                          bars(r.rssi),
                          const SizedBox(width: 8),
                          Text('${r.rssi} dBm', style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
                          Icon(Icons.chevron_right, color: last ? th.c : Colors.white38),
                        ]),
                      ),
                    );
                  }),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: scanning ? null : scan, child: const Text('สแกนใหม่')),
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('ยกเลิก')),
        ],
      );
    }),
  );
  setD = null;
  await sub?.cancel();
  await run?.cancel();
  if (picked == null) {
    await c.stopPickScan();
    return;
  }
  final a = picked.advertisementData.advName;
  await c.connectTo(picked.device, a.isNotEmpty ? a : picked.device.platformName);
}

class _TriPainter extends CustomPainter {
  final Color c;
  _TriPainter(this.c);
  @override
  void paint(Canvas canvas, Size z) =>
      canvas.drawPath(Path()..moveTo(0, z.height)..lineTo(z.width / 2, 0)..lineTo(z.width, z.height)..close(), Paint()..color = c);
  @override
  bool shouldRepaint(_TriPainter o) => o.c != c;
}

// ---------- AFR LOG: เก็บค่า AFR สดลงตาราง RPM × TPS ----------
// ดูอย่างเดียว | เก็บเป็นค่าเฉลี่ยสะสมต่อช่อง + จำนวนครั้ง | บันทึกลงเครื่องทุก ~10 วินาที (Documents/afr_log.json)
// แกนของหน้า AFR LOG : RPM 45 แถว (800..14000) × TPS 25 คอลัมน์ (0..100%)
final List<double> kAfrDefRpm = [for (int i = 0; i <= 44; i++) (800 + i * 300).toDouble()]; // 800..14000 (45 แถว) เลื่อนดูได้
final List<double> kAfrDefTps = [for (int i = 0; i < 25; i++) i * 100 / 24];

class AfrLog extends ChangeNotifier {
  static final AfrLog i = AfrLog._();
  AfrLog._();

  List<double> rpm = const [], tps = const []; // แกนแถว (RPM) / แกนคอลัมน์ (TPS)
  String src = ''; // ตารางที่ใช้แกน
  List<List<double>> sum = const [];
  List<List<int>> cnt = const [];
  (int, int)? liveCell;
  bool rec = true; // บันทึกอยู่
  GaugeController? _c;
  Telemetry? _lastT;
  int _lastMs = 0, _saveMs = 0;
  bool _dirty = false, _loaded = false;

  int get rows => rpm.length;
  int get cols => tps.length;
  bool get ready => rows > 1 && cols > 1;
  int get filled {
    int n = 0;
    for (final r in cnt) {
      for (final k in r) {
        if (k > 0) n++;
      }
    }
    return n;
  }

  double? at(int r, int c) => cnt[r][c] > 0 ? sum[r][c] / cnt[r][c] : null;

  /// ตั้งแกนตาราง RPM × TPS (800..14000 × 0..100%)
  void ensureDefault() {
    if (ready) return;
    rpm = kAfrDefRpm;
    tps = kAfrDefTps;
    src = 'ค่าเริ่มต้น ${kAfrDefRpm.length}×${kAfrDefTps.length}';
    sum = [for (int k = 0; k < rows; k++) List<double>.filled(cols, 0)];
    cnt = [for (int k = 0; k < rows; k++) List<int>.filled(cols, 0)];
    _restore();
    notifyListeners();
  }

  void attach(GaugeController c) {
    if (identical(_c, c)) return;
    _c?.removeListener(_feed);
    _c = c;
    c.addListener(_feed);
  }

  void _feed() {
    final c = _c;
    if (c == null || !ready) return;
    final t = c.t;
    if (identical(t, _lastT)) return;
    _lastT = t;
    final live = c.demo || c.ecuLive;
    final a = t.afr, rp = t.rpm, tp = t.tps;
    if (!live || a == null || rp == null || tp == null || !a.isFinite || a < 8 || a > 22) {
      if (liveCell != null) {
        liveCell = null;
        notifyListeners();
      }
      return;
    }
    final fr = _axisFrac(rpm, rp), fc = _axisFrac(tps, tp);
    if (fr == null || fc == null) return;
    final r = fr.round().clamp(0, rows - 1).toInt(), cc = fc.round().clamp(0, cols - 1).toInt();
    liveCell = (r, cc);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (rec && now - _lastMs >= 90) {
      _lastMs = now;
      sum[r][cc] += a;
      cnt[r][cc]++;
      _dirty = true;
      if (now - _saveMs > 10000) _save();
    }
    notifyListeners();
  }

  void clear() {
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        sum[r][c] = 0;
        cnt[r][c] = 0;
      }
    }
    _dirty = true;
    _save();
    notifyListeners();
  }

  void toggleRec() {
    rec = !rec;
    if (!rec) _save();
    notifyListeners();
  }

  Future<io.File> _file() async => io.File('${(await getApplicationDocumentsDirectory()).path}/afr_log.json');

  Future<void> _save() async {
    _saveMs = DateTime.now().millisecondsSinceEpoch;
    if (!_dirty || !ready) return;
    _dirty = false;
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'rpm': rpm, 'tps': tps, 'sum': sum, 'cnt': cnt}));
    } catch (_) {}
  }

  /// โหลดข้อมูลเก่าถ้าแกนตรงกัน (เปิดแอพใหม่แล้วข้อมูลไม่หาย)
  Future<void> _restore() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      final r = [for (final v in j['rpm'] as List) (v as num).toDouble()];
      final c = [for (final v in j['tps'] as List) (v as num).toDouble()];
      if (r.length != rows || c.length != cols) return;
      for (int k = 0; k < rows; k++) {
        if ((r[k] - rpm[k]).abs() > 1) return;
      }
      for (int k = 0; k < cols; k++) {
        if ((c[k] - tps[k]).abs() > 0.5) return;
      }
      final sj = j['sum'] as List, cj = j['cnt'] as List;
      for (int a = 0; a < rows; a++) {
        for (int b = 0; b < cols; b++) {
          sum[a][b] = ((sj[a] as List)[b] as num).toDouble();
          cnt[a][b] = ((cj[a] as List)[b] as num).toInt();
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  void flush() => _save();
}

/// สี AFR: รวย (ต่ำ) = แดง .. 14.7 = เขียว .. บาง (สูง) = ฟ้า/น้ำเงิน
Color _afrColor(double v) {
  const stops = <Color>[Color(0xFFD81B3C), Color(0xFFF0961E), Color(0xFF2ED278), Color(0xFF2896E8), Color(0xFF505ADC)];
  final t = ((v - 11.5) / (16.5 - 11.5)).clamp(0.0, 1.0).toDouble();
  final p = t * (stops.length - 1);
  final k = p.floor().clamp(0, stops.length - 2).toInt();
  return Color.lerp(stops[k], stops[k + 1], p - k)!;
}

class AfrLogPage extends StatefulWidget {
  final GaugeController c;
  const AfrLogPage({super.key, required this.c});
  @override
  State<AfrLogPage> createState() => _AfrLogPageState();
}

class _AfrLogPageState extends State<AfrLogPage> {
  final log = AfrLog.i;
  Size _sz = Size.zero;

  void _rb() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    log.attach(widget.c);
    log.addListener(_rb);
    Cfg.i.addListener(_rb);
  }

  @override
  void dispose() {
    log.removeListener(_rb);
    Cfg.i.removeListener(_rb);
    log.flush();
    super.dispose();
  }

  void _tapCell(Offset p) {
    if (!log.ready) return;
    final g = _AfrPainter.geom(_sz, log.rows, log.cols);
    final c = ((p.dx - g.$1) / g.$3).floor(), r = ((p.dy - g.$2) / g.$4).floor();
    if (r < 0 || c < 0 || r >= log.rows || c >= log.cols) return;
    final v = log.at(r, c);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('RPM ${log.rpm[r].toStringAsFixed(0)} · TPS ${log.tps[c].toStringAsFixed(1)} : '
              '${v == null ? 'ยังไม่มีข้อมูล' : 'AFR ${v.toStringAsFixed(2)} (${log.cnt[r][c]} ครั้ง)'}')));
  }

  Widget _btn(String t, Color col, VoidCallback? f, {bool active = false}) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? col.withOpacity(0.22) : Colors.black45,
              border: Border.all(color: col, width: 1.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(t, style: TextStyle(fontSize: 13, color: col, fontWeight: FontWeight.bold)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final live = widget.c.demo || widget.c.ecuLive;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(children: [
            SizedBox(
              height: 36,
              child: Row(children: [
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  child: Row(children: [
                    Icon(Icons.chevron_left, color: th.c, size: 26),
                    Text('AFR LOG', style: TextStyle(fontFamily: kFont, fontSize: 15, color: th.c)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                      log.ready
                          ? '${log.rows}×${log.cols} · แกนจาก "${log.src}" · บันทึกแล้ว ${log.filled} ช่อง${live ? '' : ' · ยังไม่มีข้อมูลสด (ต่อเกจ/เปิด DEMO)'}'
                          : 'กำลังเตรียมตาราง…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: live ? Colors.white70 : kAmber)),
                ),
                _btn(log.rec ? '● REC' : '❚❚ หยุด', log.rec ? kGreen : kAmber, log.ready ? log.toggleRec : null, active: true),
                _btn('ล้าง', th.c, log.ready
                    ? () async {
                        if (await askYes(context, 'ล้าง AFR LOG', 'ลบค่าที่บันทึกไว้ทั้งหมด?', ok: 'ล้าง', col: kBad)) log.clear();
                      }
                    : null),
              ]),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xCC060606),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: th.c.withOpacity(0.85), width: 1.1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: log.ready
                      ? LayoutBuilder(builder: (_, cs) {
                          final h = _AfrPainter.hh + log.rows * _AfrPainter.rh;
                          _sz = Size(cs.maxWidth, h);
                          return SingleChildScrollView(
                            child: GestureDetector(
                              onTapUp: (d) => _tapCell(d.localPosition),
                              child: CustomPaint(size: Size(cs.maxWidth, h), painter: _AfrPainter(log, th)),
                            ),
                          );
                        })
                      : const Center(child: Text('ยังไม่มีตาราง', style: TextStyle(color: Colors.white54))),
                ),
              ),
            ),
            SizedBox(
              height: 22,
              child: Row(children: [
                Container(
                  width: 140, height: 8,
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: LinearGradient(colors: [for (int k = 0; k <= 10; k++) _afrColor(11.5 + k * 0.5)])),
                ),
                const SizedBox(width: 6),
                const Text('11.5 รวย · 14.7 · 16.5 บาง', style: TextStyle(fontSize: 10.5, color: Colors.white60)),
                const Spacer(),
                const Text('ช่องทึบ = บันทึกหลายครั้ง · ช่องมืด = ยังไม่มีข้อมูล · กรอบขาว = ตำแหน่งเครื่องตอนนี้ · แตะช่อง = ดูรายละเอียด',
                    style: TextStyle(fontSize: 10.5, color: Colors.white54)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _AfrPainter extends CustomPainter {
  final AfrLog log;
  final AppTheme th;
  _AfrPainter(this.log, this.th);

  static const double hw = 40, hh = 18, rh = 20;   // rh = ความสูงคงที่ต่อแถว (ถ้าเกินจอให้เลื่อนดู ไม่ย่อ)
  /// (x0, y0, cw, ch) ของช่องข้อมูล — ความสูงแถวคงที่ (rh) ไม่ขึ้นกับความสูงจอ
  static (double, double, double, double) geom(Size s, int rows, int cols) =>
      (hw, hh, (s.width - hw) / cols, rh);

  @override
  void paint(Canvas canvas, Size size) {
    final rows = log.rows, cols = log.cols;
    final g = geom(size, rows, cols);
    final gx = g.$1, gy = g.$2, cw = g.$3, ch = g.$4;
    final hp = Paint()..color = const Color(0xFF1A1A20);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, hh), hp);
    canvas.drawRect(Rect.fromLTWH(0, 0, hw, size.height), hp);
    final hs = math.min(9.5, cw * 0.3);
    _TP.center(canvas, _TP.get('RPM\\TPS', 7.5, Colors.white54), Offset(hw / 2, hh / 2));
    for (int c = 0; c < cols; c++) {
      final v = log.tps[c];
      _TP.center(canvas, _TP.get(v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1), hs, Colors.white70, maxW: cw), Offset(gx + c * cw + cw / 2, hh / 2));
    }
    final rs = math.min(9.5, ch * 0.7);
    for (int r = 0; r < rows; r++) {
      _TP.center(canvas, _TP.get(log.rpm[r].toStringAsFixed(0), rs, Colors.white70, maxW: hw), Offset(hw / 2, gy + r * ch + ch / 2));
    }
    final empty = Paint()..color = const Color(0xFF121216);
    final line = Paint()
      ..color = const Color(0xFF26262C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    final fill = Paint();
    final fs = math.min(ch * 0.66, math.min(cw * 0.28, 11.0));
    int maxN = 1;
    for (final r in log.cnt) {
      for (final k in r) {
        if (k > maxN) maxN = k;
      }
    }
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final rect = Rect.fromLTWH(gx + c * cw, gy + r * ch, cw, ch);
        final v = log.at(r, c);
        if (v == null) {
          canvas.drawRect(rect, empty);
          canvas.drawRect(rect, line);
          continue;
        }
        final a = (0.4 + 0.6 * math.min(1.0, log.cnt[r][c] / math.max(10, maxN * 0.5))).clamp(0.0, 1.0);
        fill.color = Color.lerp(const Color(0xFF121216), _afrColor(v), a)!;
        canvas.drawRect(rect.deflate(0.3), fill);
        if (fs >= 4.5) _TP.center(canvas, _TP.get(v.toStringAsFixed(1), fs, const Color(0xFF000000), maxW: cw), rect.center);
      }
    }
    final lc = log.liveCell;
    if (lc != null) {
      final rect = Rect.fromLTWH(gx + lc.$2 * cw, gy + lc.$1 * ch, cw, ch);
      canvas.drawRect(rect.inflate(1), Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4);
    }
  }

  @override
  bool shouldRepaint(_AfrPainter o) => true;
}

// ===================== หน้า DASH + TOP SPEED (TIWSHOP) =====================
const _kMon = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
String _dmy(DateTime d) => '${d.day} ${_kMon[d.month - 1]} ${d.year + 543}';   // ปี พ.ศ.
String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String _hms(DateTime d) => '${_hm(d)}:${d.second.toString().padLeft(2, '0')}';
double _rad(double deg) => deg * math.pi / 180;
Offset _polar(Offset c, double deg, double r) => c + Offset(math.cos(_rad(deg)), math.sin(_rad(deg))) * r;

// วาดข้อความ: al = จุดยึด (center = กึ่งกลางข้อความอยู่ที่ p)
void _dtxt(Canvas cv, String s, Offset p, double size, Color col,
    {FontWeight w = FontWeight.w800, bool italic = true, String? family, Alignment al = Alignment.center}) {
  final tp = TextPainter(
    text: TextSpan(
        text: s,
        style: TextStyle(
            fontSize: size, color: col, fontWeight: w, height: 1.0, fontFamily: family,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(cv, Offset(p.dx - tp.width * (al.x + 1) / 2, p.dy - tp.height * (al.y + 1) / 2));
}

// ตำแหน่งชิ้นส่วนบนหน้า DASH (ใช้ร่วมกันระหว่างชั้นนิ่งกับชั้นค่าสด)
class _DashGeo {
  late final Offset tc, tempC, tpsC, mapC, afrC;
  late final double tr, gr, ar;
  late final Rect top;
  _DashGeo(Size s) {
    final w = s.width, h = s.height;
    tr = math.min(h * 0.48, w * 0.24);
    tc = Offset(w * 0.5, h * 0.5);
    gr = math.min(w * 0.095, h * 0.21);
    tempC = Offset(w * 0.12, h * 0.29);
    tpsC = Offset(w * 0.12, h * 0.76);
    mapC = Offset(w * 0.88, h * 0.27);
    ar = math.min(w * 0.08, h * 0.16);
    afrC = Offset(w * 0.88, h * 0.81);
    top = Rect.fromCenter(center: Offset(w * 0.88, h * 0.555), width: w * 0.2, height: h * 0.14);
  }
}

int _dashRmax(int shift) => (((shift / 1000).ceil() + 2) * 1000).clamp(8000, 16000).toInt();

// ---- ชั้นนิ่ง: วงรอบเครื่อง สเกล ตัวเลข โซนแดง กรอบเกจย่อย (วาดใหม่เฉพาะตอนขนาด/สีธีมเปลี่ยน) ----
class _DashStatic extends CustomPainter {
  final Color c;
  final int shift;
  _DashStatic(this.c, this.shift);

  void _arcGauge(Canvas cv, Offset ctr, double r, String lo, String hi, String label, String unit) {
    final sw = r * 0.26, rr = r - sw / 2;
    final rect = Rect.fromCircle(center: ctr, radius: rr);
    cv.drawArc(rect, _rad(135), _rad(270), false, Paint()..style = PaintingStyle.stroke..strokeWidth = sw..color = const Color(0xFF41464E));
    final ol = Paint()..style = PaintingStyle.stroke..strokeWidth = (1.3)..color = Colors.white70;
    cv.drawArc(Rect.fromCircle(center: ctr, radius: r), _rad(135), _rad(270), false, ol);
    cv.drawArc(Rect.fromCircle(center: ctr, radius: r - sw), _rad(135), _rad(270), false, ol);
    _dtxt(cv, lo, _polar(ctr, 135, rr) + Offset(0, sw * 1.05), r * 0.17, Colors.white70);
    _dtxt(cv, hi, _polar(ctr, 45, rr) + Offset(0, sw * 1.05), r * 0.17, Colors.white70);
    _dtxt(cv, label, ctr + Offset(0, r * 0.62), r * 0.24, const Color(0xFFFFE01A), w: FontWeight.w900);
    if (unit.isNotEmpty) _dtxt(cv, unit, ctr + Offset(0, r * 0.3), r * 0.15, Colors.white60, italic: false, w: FontWeight.w600);
  }

  @override
  void paint(Canvas cv, Size s) {
    final g = _DashGeo(s);
    final rmax = _dashRmax(shift);
    final tc = g.tc, tr = g.tr, bw = tr * 0.2;
    // วงนอกบาง (สีธีม) + แถบขาว + จานดำด้านใน
    cv.drawCircle(tc, tr + 3, Paint()..style = PaintingStyle.stroke..strokeWidth = (2)..color = c.withOpacity(0.7));
    cv.drawCircle(tc, tr - bw / 2, Paint()..style = PaintingStyle.stroke..strokeWidth = bw..color = const Color(0xFFE9ECEF));
    cv.drawCircle(tc, tr - bw, Paint()..color = Colors.black);
    cv.drawCircle(tc, tr - bw, Paint()..style = PaintingStyle.stroke..strokeWidth = (3)..color = const Color(0xFF2A2F36));
    // โซนแดง (ขอบนอกของแถบ)
    final double a0 = 135 + 270 * (shift / rmax).clamp(0.0, 1.0).toDouble();
    cv.drawArc(Rect.fromCircle(center: tc, radius: tr - bw * 0.07), _rad(a0), _rad(405 - a0), false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = (bw * 0.14)..color = const Color(0xFFE8202A));
    // สเกล + ตัวเลข x1000
    for (int r = 0; r <= rmax; r += 250) {
      final double a = 135 + 270 * r / rmax;
      final maj = r % 1000 == 0, mid = r % 500 == 0;
      final red = r >= shift;
      final len = maj ? bw * 0.45 : (mid ? bw * 0.3 : bw * 0.18);
      cv.drawLine(_polar(tc, a, tr - bw * 0.16), _polar(tc, a, tr - bw * 0.16 - len),
          Paint()..strokeWidth = (maj ? 2.6 : 1.3)..color = red ? const Color(0xFFE8202A) : const Color(0xFF15181C));
      if (maj) {
        _dtxt(cv, '${r ~/ 1000}', _polar(tc, a, tr - bw * 0.78), bw * 0.4, red ? const Color(0xFFE8202A) : const Color(0xFF15181C), w: FontWeight.w900);
      }
    }
    _dtxt(cv, 'x1000', _polar(tc, 62, tr - bw * 1.5), tr * 0.065, Colors.white54, w: FontWeight.w700);
    _dtxt(cv, 'RPM', _polar(tc, 62, tr - bw * 1.5) + Offset(0, tr * 0.075), tr * 0.065, Colors.white54, w: FontWeight.w700);
    // เกจย่อย
    _arcGauge(cv, g.tempC, g.gr, '40', '150', 'TEMP', '°C');
    _arcGauge(cv, g.tpsC, g.gr, '0', '100', 'TPS', '');
    _arcGauge(cv, g.mapC, g.gr, '0', '120', 'MAP', 'kPa');
    // AFR: วงขาว + จานดำ
    cv.drawCircle(g.afrC, g.ar - g.ar * 0.09, Paint()..style = PaintingStyle.stroke..strokeWidth = (g.ar * 0.18)..color = const Color(0xFFE9ECEF));
    cv.drawCircle(g.afrC, g.ar * 0.82, Paint()..color = Colors.black);
    // กล่อง TOPSPEED
    final rr = RRect.fromRectAndRadius(g.top, const Radius.circular(8));
    cv.drawRRect(rr, Paint()..color = const Color(0xFF2B3036));
    cv.drawRRect(rr, Paint()..style = PaintingStyle.stroke..strokeWidth = (1)..color = Colors.white24);
  }

  @override
  bool shouldRepaint(_DashStatic o) => o.c != c || o.shift != shift;
}

// ---- ชั้นค่าสด ----
class _DashLive extends CustomPainter {
  final Color c;
  final int shift, tempWarn;
  final double? rpm, speed, temp, tps, map, afr;
  final double top;
  final DateTime now;
  _DashLive({required this.c, required this.shift, required this.tempWarn, this.rpm, this.speed, this.temp, this.tps, this.map, this.afr,
      required this.top, required this.now});

  void _val(Canvas cv, Offset ctr, double r, double? v, double lo, double hi, Color col, int dec) {
    final sw = r * 0.26, rr = r - sw / 2;
    if (v != null) {
      final double f = ((v - lo) / (hi - lo)).clamp(0.0, 1.0).toDouble();
      if (f > 0) {
        cv.drawArc(Rect.fromCircle(center: ctr, radius: rr), _rad(135), _rad(270 * f), false,
            Paint()..style = PaintingStyle.stroke..strokeWidth = (sw * 0.72)..color = col);
      }
    }
    _dtxt(cv, v == null ? '--' : v.toStringAsFixed(dec), ctr + Offset(0, -r * 0.08), r * 0.44, Colors.white, w: FontWeight.w900);
  }

  @override
  void paint(Canvas cv, Size s) {
    final g = _DashGeo(s);
    final rmax = _dashRmax(shift);
    final tc = g.tc, tr = g.tr, bw = tr * 0.2;
    // แถบรอบเครื่อง (ขอบในของวงขาว) + เข็มสามเหลี่ยมแดง
    final double rv = (rpm ?? 0.0).clamp(0.0, rmax.toDouble()).toDouble();
    final f = rv / rmax;
    if (f > 0) {
      cv.drawArc(Rect.fromCircle(center: tc, radius: tr - bw - 4), _rad(135), _rad(270 * f), false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = (5)..strokeCap = StrokeCap.round..color = rv >= shift ? const Color(0xFFFF2A2A) : c);
    }
    final a = 135 + 270 * f;
    final tip = _polar(tc, a, tr - bw * 0.04);
    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(_polar(tc, a - 3.4, tr - bw * 1.08).dx, _polar(tc, a - 3.4, tr - bw * 1.08).dy)
      ..lineTo(_polar(tc, a + 3.4, tr - bw * 1.08).dx, _polar(tc, a + 3.4, tr - bw * 1.08).dy)
      ..close();
    cv.drawPath(p, Paint()..color = const Color(0xFFFF1E1E));
    // ความเร็ว + RPM + เวลา
    _dtxt(cv, speed == null ? '--' : speed!.toStringAsFixed(0), tc + Offset(0, -tr * 0.2), tr * 0.42, Colors.white, w: FontWeight.w900);
    _dtxt(cv, 'km/h', tc + Offset(0, tr * 0.05), tr * 0.1, Colors.white70, w: FontWeight.w700);
    cv.drawLine(tc + Offset(-tr * 0.45, tr * 0.14), tc + Offset(tr * 0.45, tr * 0.14), Paint()..strokeWidth = (2)..color = Colors.white70);
    _dtxt(cv, rpm == null ? '--' : rpm!.toStringAsFixed(0), tc + Offset(-tr * 0.08, tr * 0.27), tr * 0.16,
        rv >= shift ? const Color(0xFFFF2A2A) : Colors.white, w: FontWeight.w900);
    _dtxt(cv, 'RPM', tc + Offset(tr * 0.3, tr * 0.29), tr * 0.075, Colors.white60, w: FontWeight.w700);
    _dtxt(cv, _hm(now), tc + Offset(0, tr * 0.45), tr * 0.095, Colors.white, w: FontWeight.w800);
    _dtxt(cv, _dmy(now), tc + Offset(0, tr * 0.59), tr * 0.075, Colors.white70, w: FontWeight.w700);
    // เกจย่อย
    final tCol = temp != null && temp! >= tempWarn ? const Color(0xFFFF2A2A) : const Color(0xFF2A6BFF);
    _val(cv, g.tempC, g.gr, temp, 40, 150, tCol, 0);
    _val(cv, g.tpsC, g.gr, tps, 0, 100, const Color(0xFFFFE01A), 0);
    _val(cv, g.mapC, g.gr, map, 0, 120, c, 0);
    // AFR
    final aCol = afr == null ? Colors.white : (afr! < 13.0 ? const Color(0xFF3AA0FF) : (afr! > 15.0 ? const Color(0xFFFF8A1E) : const Color(0xFF5CFF2E)));
    _dtxt(cv, 'AFR', g.afrC + Offset(0, -g.ar * 0.32), g.ar * 0.3, const Color(0xFFFFE01A), w: FontWeight.w900);
    _dtxt(cv, afr == null ? '--' : afr!.toStringAsFixed(1), g.afrC + Offset(0, g.ar * 0.17), g.ar * 0.44, aCol, w: FontWeight.w900);
    // TOPSPEED
    _dtxt(cv, 'TOPSPEED', Offset(g.top.center.dx, g.top.top + g.top.height * 0.26), g.top.height * 0.24, const Color(0xFFFFE01A), w: FontWeight.w900);
    _dtxt(cv, top.toStringAsFixed(0), Offset(g.top.center.dx, g.top.top + g.top.height * 0.68), g.top.height * 0.42, Colors.white, w: FontWeight.w900);
  }

  @override
  bool shouldRepaint(_DashLive o) => true;
}

class DashPage extends StatelessWidget {
  final GaugeController c;
  const DashPage({super.key, required this.c});

  static String _f(double? v, int dec) => v == null ? '--' : v.toStringAsFixed(dec);

  @override
  Widget build(BuildContext context) {
    final cfg = Cfg.i;
    final th = cfg.t;
    final t = c.t;
    final live = c.demo || c.ecuLive;
    double? v(double? x) => live ? x : null;
    // รายการขวา: แตะแถวเพื่อเลือกค่าอื่น (เลือกค่าที่อยู่อีกแถว = สลับกัน)
    List<String> row(int k) {
      final kd = kKeys[k];
      final raw = (k == kSpd || k == kTop) ? c.keyVal(k) : v(c.keyVal(k));
      if (k == kStft || k == kLtft) return [kd.name, '%', _f(raw == null ? null : (raw - 1) * 100, 1)];
      if (k == kIgn) return [kd.name, 'deg', _f(raw, 1)];
      return [kd.name, kd.unit, _f(raw, kd.dec)];
    }
    final rows = [for (final k in cfg.dash) row(k)];
    return LayoutBuilder(builder: (_, cs) {
      final listW = (cs.maxWidth * 0.2).clamp(120.0, 190.0).toDouble();
      return Row(children: [
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            RepaintBoundary(child: CustomPaint(painter: _DashStatic(th.c, cfg.shift))),
            CustomPaint(
              painter: _DashLive(
                c: th.c, shift: cfg.shift, tempWarn: cfg.tempWarn,
                rpm: v(t.rpm), speed: c.shownSpeed, temp: v(t.ect ?? t.eot), tps: v(t.tps), map: v(t.map), afr: v(t.afr),
                top: c.topSpeed, now: DateTime.now(),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: listW,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10), border: Border.all(color: th.c.withOpacity(0.6))),
            child: Column(children: [
              for (int i = 0; i < rows.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => pickKey(context, cfg.dash, i),
                    child: Container(
                    decoration: BoxDecoration(border: i == rows.length - 1 ? null : const Border(bottom: BorderSide(color: Colors.white12))),
                    child: Row(children: [
                      Text(rows[i][0], style: const TextStyle(color: Color(0xFFFFE01A), fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 14)),
                      const SizedBox(width: 3),
                      Text(rows[i][1], style: const TextStyle(color: Colors.white54, fontSize: 9)),
                      const Spacer(),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(rows[i][2], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 20)),
                        ),
                      ),
                    ]),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]);
    });
  }
}

// ---- วงความเร็วด้านหลังตัวเลข TOP SPEED (วาดเฉพาะค่าสูงสุดที่บันทึกไว้) ----
class _TsArcPainter extends CustomPainter {
  final double best;
  final Color c;
  _TsArcPainter(this.best, this.c);
  @override
  void paint(Canvas cv, Size s) {
    final ctr = Offset(s.width / 2, s.height * 0.56);
    final r = math.min(s.width * 0.42, s.height * 0.5);
    final scale = best > 180 ? 300.0 : 200.0;
    final rect = Rect.fromCircle(center: ctr, radius: r);
    cv.drawArc(rect, _rad(150), _rad(240), false, Paint()..style = PaintingStyle.stroke..strokeWidth = (10)..strokeCap = StrokeCap.round..color = Colors.white12);
    final double f = (best / scale).clamp(0.0, 1.0).toDouble();
    if (f > 0) {
      cv.drawArc(rect, _rad(150), _rad(240 * f), false, Paint()..style = PaintingStyle.stroke..strokeWidth = (10)..strokeCap = StrokeCap.round..color = c);
    }
    for (int k = 0; k <= scale; k += 50) {
      final double a = 150 + 240 * k / scale;
      _dtxt(cv, '$k', _polar(ctr, a, r + 22), 11, Colors.white54, w: FontWeight.w700, italic: false);
    }
  }

  @override
  bool shouldRepaint(_TsArcPainter o) => o.best != best || o.c != c;
}

class TopSpeedPage extends StatelessWidget {
  final GaugeController c;
  const TopSpeedPage({super.key, required this.c});

  Widget _box(String label, String value, AppTheme th) => Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24), color: const Color(0xCC0A0D14)),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: const Color(0xFFCFD3D9),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(label, style: const TextStyle(color: Color(0xFF3A3F46), fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 34)),
                ),
              ),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    final at = c.tsAt;
    final best = c.tsBest;
    return LayoutBuilder(builder: (_, cs) {
      final side = (cs.maxWidth * 0.21).clamp(120.0, 200.0).toDouble();
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: side,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              height: 42,
              child: InkWell(
                onTap: c.tsClear,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFF5A5F66), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white30)),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.refresh, size: 18, color: Colors.white),
                    SizedBox(width: 6),
                    Text('CLEAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _box('RPM', c.tsRpm == null ? '--' : c.tsRpm!.toStringAsFixed(0), th)),
            const SizedBox(height: 8),
            Expanded(child: _box('AFR', c.tsAfr == null ? '--' : c.tsAfr!.toStringAsFixed(1), th)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: th.c, width: 1.5),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [th.c.withOpacity(0.35), const Color(0xEE0B0F1A)]),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(children: [
              const FittedBox(fit: BoxFit.scaleDown, child: Text('TOP SPEED', style: TextStyle(fontFamily: kFont, fontSize: 28, color: Colors.white))),
              const SizedBox(height: 2),
              Text('TIWSHOP GPS SPEED METER', style: TextStyle(fontFamily: kFont, fontSize: 9, color: th.c)),
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  CustomPaint(painter: _TsArcPainter(best, th.c)),
                  Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(best > 0 ? best.toStringAsFixed(0) : '--',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, fontSize: 96, height: 1.0)),
                      ),
                    ),
                    const Text('km/h', style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w700)),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: side,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _box('TIME', at == null ? '--' : _hms(at), th)),
            const SizedBox(height: 8),
            Expanded(child: _box('DATE', at == null ? '--' : _dmy(at), th)),
          ]),
        ),
      ]);
    });
  }
}
