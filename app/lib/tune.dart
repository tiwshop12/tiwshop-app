// tune.dart - โหลด BIN + XDF (TunerPro XDF 1.80 XML) แสดง/แก้ทุกพารามิเตอร์ (ตาราง 2D/1D/ค่าเดียว/FLAG) เหมือน TunerPro + LIVE แล้วเซฟลงคลัง
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- ถอดรหัสชื่อ TIS-620 (XDF เก็บ &#164; ฯลฯ เป็นไบต์ TIS-620) ----------
String decodeTis620(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xA1 && r <= 0xFB) {
      sb.writeCharCode(0x0E00 + (r - 0xA0));
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

// ---------- ประเมินสมการเชิงเส้น a*X+b จาก MATH (รองรับ + - * / วงเล็บ ตัวแปร X) ----------
class _Expr {
  final String s;
  int p = 0;
  _Expr(this.s);
  double eval(double x) {
    p = 0;
    final v = _add(x);
    return v;
  }
  void _ws() { while (p < s.length && s[p] == ' ') p++; }
  double _add(double x) {
    double v = _mul(x);
    while (true) {
      _ws();
      if (p < s.length && (s[p] == '+' || s[p] == '-')) {
        final op = s[p++]; final r = _mul(x); v = op == '+' ? v + r : v - r;
      } else break;
    }
    return v;
  }
  double _mul(double x) {
    double v = _un(x);
    while (true) {
      _ws();
      if (p < s.length && (s[p] == '*' || s[p] == '/')) {
        final op = s[p++]; final r = _un(x); v = op == '*' ? v * r : (r == 0 ? 0 : v / r);
      } else break;
    }
    return v;
  }
  double _un(double x) {
    _ws();
    if (p < s.length && s[p] == '-') { p++; return -_un(x); }
    if (p < s.length && s[p] == '+') { p++; return _un(x); }
    return _atom(x);
  }
  double _atom(double x) {
    _ws();
    if (p < s.length && s[p] == '(') { p++; final v = _add(x); _ws(); if (p < s.length && s[p] == ')') p++; return v; }
    if (p < s.length && (s[p] == 'X' || s[p] == 'x')) { p++; return x; }
    final st = p;
    while (p < s.length && (RegExp(r'[0-9.eE]').hasMatch(s[p]) || ((s[p] == '+' || s[p] == '-') && p > st && (s[p - 1] == 'e' || s[p - 1] == 'E')))) p++;
    var num = s.substring(st, p);
    if (num.startsWith('.')) num = '0$num';          // ".001" -> "0.001" (Dart ไม่รับเลขขึ้นต้นด้วยจุด)
    if (num.endsWith('.')) num = '${num}0';
    return double.tryParse(num) ?? 0;
  }
}

class LinMath {
  final double a, b; // display = a*raw + b
  const LinMath(this.a, this.b);
  factory LinMath.fromEq(String eq) {
    final e = _Expr(eq);
    final b = e.eval(0), a = e.eval(1) - b;
    return LinMath(a == 0 ? 1 : a, b);
  }
  double toDisp(num raw) => a * raw + b;
  int toRaw(double disp, int bits, bool signed) {
    int v = ((disp - b) / a).round();
    final mx = (1 << bits) - 1;
    if (signed) { final lim = 1 << (bits - 1); if (v < -lim) v = -lim; if (v > lim - 1) v = lim - 1; if (v < 0) v += (1 << bits); }
    else { if (v < 0) v = 0; if (v > mx) v = mx; }
    return v;
  }
}

// ---------- โมเดล XDF (อ่านตามกติกา TunerPro) ----------
// typeflags: 0x01 = signed, 0x02 = LSB first (little-endian), 0x04 = column-major
// majorstridebits > 0 = ระยะห่างระหว่างช่องที่อยู่ติดกันในลำดับการเก็บ (ในแถวเดียวกัน; ถ้า column-major = ในคอลัมน์เดียวกัน)
// minorstridebits > 0 = ระยะห่างระหว่างจุดเริ่มแต่ละแถว (column-major = แต่ละคอลัมน์)  — ตรวจกับไฟล์จริง 88 รุ่นแล้ว
// แกน X/Y: embedinfo type 3 + linkobjid = ใช้ค่าตารางอื่น, type 1 = อ่านจาก BIN ตามที่อยู่ของแกน, ไม่มี embedinfo = LABEL คงที่
// outputtype: 1 ทศนิยม, 2 จำนวนเต็ม, 3 เลขฐาน 16, 4 ตัวอักษร (ASCII)
// ฟอนต์ของข้อความที่วาดเองใน CustomPainter (null = ฟอนต์ระบบตามปกติ) — ใช้ตอนถ่ายรูปหน้าจออัตโนมัติ
String? kPaintFont;
List<String>? kPaintFallback;

enum AxKind { none, rpm, tps }
// table = ตาราง/ค่าเดียว, flag = ติ๊กบิต, patch = แพตช์ (เช่น ล็อคโหมด / ปลดมัดไฟ / ปิดอิโม), info = หัวข้อ/หมายเหตุ/ฟังก์ชัน/checksum ใน XDF
enum ItemKind { table, flag, patch, info }

class PatchEntry {
  final int addr;
  final Uint8List patch, base;
  const PatchEntry(this.addr, this.patch, this.base);
}

class XdfAxis {
  final int count;
  final List<String> labels; // LABEL แบบคงที่
  final String? link;        // linkobjid → ใช้ค่าจากตารางนั้นเป็นหัวแกน
  final int? address;        // แกนที่ฝังใน BIN เอง
  final int bits;
  final bool lsb, signed;
  final LinMath math;
  final int? dp;            // null = ไม่ได้กำหนด
  final String? type;       // embedinfo type ('1' จาก BIN, '3' ลิงก์)
  final int stride;         // ไบต์ระหว่างค่า (แกนจาก BIN)
  const XdfAxis(this.count, this.labels, this.link, this.address, this.bits, this.lsb, this.signed, this.math, this.dp, this.type, this.stride);
}

class XdfTable {
  final String id, title, desc, info;
  final ItemKind kind;
  final List<PatchEntry> patches;
  final List<int> cats;      // หมวด (index ของ CATEGORY ใน XDFHEADER)
  final int address, bits, rows, cols, dp, mask, out;
  final int elemStride, rowStride; // ไบต์
  final bool signed, lsb, colMajor;
  final LinMath math;
  final double tmin, tmax;
  final XdfAxis? x, y;
  XdfTable({
    required this.id, required this.title, this.kind = ItemKind.table, this.address = 0, this.bits = 8,
    this.desc = '', this.info = '', this.patches = const [], this.cats = const [],
    this.rows = 1, this.cols = 1, this.dp = 0, this.mask = 0, this.out = 1, this.elemStride = 1, this.rowStride = 0,
    this.signed = false, this.lsb = true, this.colMajor = false, this.math = const LinMath(1, 0),
    this.tmin = 0, this.tmax = 255, this.x, this.y,
  });
  bool get isFlag => kind == ItemKind.flag;
  bool get isPatch => kind == ItemKind.patch;
  bool get isInfo => kind == ItemKind.info;
  bool get isTable => kind == ItemKind.table;
  bool get special => kind != ItemKind.table;   // ไม่ใช่ตัวเลข (ไม่มีตาราง/แถบเครื่องมือ)
  bool get is2d => isTable && rows > 1 && cols > 1;
  bool get isConst => isTable && rows * cols == 1;
  bool get is1d => isTable && !is2d && !isConst;
  int get count => rows * cols;
  String get kindLabel => isFlag ? 'FLAG' : isPatch ? 'แพตช์ ${patches.length} จุด' : isInfo ? 'หมายเหตุ' : (isConst ? 'ค่าเดียว' : '${rows}x$cols');
}

// แปลง XML entity (&#NNN; &#xHH; &amp; ฯลฯ) เป็นอักขระ — ใช้ก่อนถอด TIS-620
String _entities(String s) {
  s = s.replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)));
  return s.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'");
}

// สมการ: ถอด entity (&#013;&#010;), ตัดช่องว่าง/ขึ้นบรรทัด, ชื่อตัวแปรใด ๆ (x, X1. ฯลฯ) = ค่าดิบ X
String _eq(String? e) {
  var s = _entities(e ?? 'X').replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
  s = s.replaceAll(RegExp(r'(?<![0-9.])[A-Za-z_][A-Za-z0-9_]*\.?(?![0-9])'), 'X');
  return s.isEmpty ? 'X' : s;
}

// ชื่อร้านอื่น (ZAR RACING) และเบอร์โทรศัพท์ในไฟล์ XDF -> ตัดทิ้ง
final _bad = RegExp(r'zar\s*racing|(?<!\d)0\d{1,2}[- ]?\d{3}[- ]?\d{4}(?!\d)', caseSensitive: false);

String? _attr(String src, String name) => RegExp('$name="([^"]*)"').firstMatch(src)?.group(1);
int? _hex(String? s) {
  if (s == null) return null;
  s = s.trim();
  if (s.isEmpty) return null;
  return s.startsWith('0x') || s.startsWith('0X') ? int.tryParse(s.substring(2), radix: 16) : int.tryParse(s);
}

class XdfDoc {
  final List<XdfTable> items; // ตามลำดับในไฟล์ (เหมือน Parameter Ordered List ของ TunerPro)
  final Map<String, XdfTable> byId;
  final String title, desc, credit;
  final Map<int, String> cats;  // CATEGORY index -> ชื่อหมวด
  XdfDoc(this.items, {this.title = '', this.desc = '', this.cats = const {}, this.credit = ''}) : byId = {for (final t in items) t.id.toLowerCase(): t};
  List<XdfTable> get tables => items.where((t) => t.isTable).toList();

  static XdfDoc parse(String xml) {
    // ค่าเริ่มต้นจาก <DEFAULTS>
    // TunerPro: <DEFAULTS> เป็นแค่ค่าเริ่มต้นตอนสร้างตารางใหม่ใน editor — ตอนอ่านไฟล์ ถ้าไม่มี typeflags = MSB first, unsigned, 8 บิต
    const defLsb = false;
    const defSigned = false;
    const defBits = 8;

    String title(String t) {
      final raw = RegExp(r'<title>([\s\S]*?)</title>').firstMatch(t)?.group(1)?.trim() ?? '';
      final s = decodeTis620(_entities(raw)).trim();
      return s.isEmpty ? '(ไม่มีชื่อ)' : s;
    }

    XdfAxis? axis(String t, String id) {
      final am = RegExp('<XDFAXIS\\s+id="$id"[\\s\\S]*?</XDFAXIS>').firstMatch(t);
      if (am == null) return null;
      final a = am.group(0)!;
      final ed = RegExp(r'<EMBEDDEDDATA([^>]*)>').firstMatch(a)?.group(1) ?? '';
      final cnt = int.tryParse(RegExp(r'<indexcount>(\d+)').firstMatch(a)?.group(1) ?? '') ?? 0;
      final ei = RegExp(r'<embedinfo\s+type="(\d+)"').firstMatch(a)?.group(1);
      final link = ei == '3' ? RegExp(r'<embedinfo[^>]*linkobjid="([^"]*)"').firstMatch(a)?.group(1) : null;
      final abits = (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? defBits).abs();
      final amaj = int.tryParse(_attr(ed, 'mmedmajorstridebits') ?? '') ?? 0;
      final labs = <int, String>{};
      for (final m in RegExp(r'<LABEL\s+index="(\d+)"\s+value="([^"]*)"').allMatches(a)) {
        labs[int.parse(m[1]!)] = decodeTis620(_entities(m[2]!));
      }
      final n = cnt > 0 ? cnt : (labs.isEmpty ? 1 : labs.keys.reduce((p, q) => p > q ? p : q) + 1);
      final tf = _hex(_attr(ed, 'mmedtypeflags'));
      return XdfAxis(
        n, labs.isEmpty ? [for (int i = 0; i < n; i++) '${i + 1}'] : [for (int i = 0; i < n; i++) labs[i] ?? ''],
        link, ei == '1' ? _hex(_attr(ed, 'mmedaddress')) : null,
        abits,
        tf == null ? defLsb : (tf & 2) != 0, tf == null ? defSigned : (tf & 1) != 0,
        LinMath.fromEq(_eq(_attr(a, 'equation'))),
        int.tryParse(RegExp(r'<decimalpl>(-?\d+)').firstMatch(a)?.group(1) ?? ''),
        ei, amaj > 0 ? math.max(1, amaj ~/ 8) : math.max(1, abits ~/ 8),
      );
    }

    String desc(String t) => decodeTis620(_entities(RegExp(r'<description>([\s\S]*?)</description>').firstMatch(t)?.group(1)?.trim() ?? '')).trim();
    // หมวด: CATEGORYMEM category = (index ของ CATEGORY) + 1  (ตรวจกับไฟล์จริงแล้ว)
    List<int> cats(String t) => [for (final m in RegExp(r'<CATEGORYMEM[^>]*category="(\d+)"').allMatches(t)) int.parse(m[1]!) - 1];
    Uint8List hexBytes(String? h, int n) {
      final s = (h ?? '').replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      final k = math.min(n, s.length ~/ 2);
      return Uint8List.fromList([for (int i = 0; i < k; i++) int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)]);
    }

    final out = <XdfTable>[];
    String credit = '';
    for (final m in RegExp(r'<(XDFTABLE|XDFFLAG|XDFPATCH|XDFCONSTANT|XDFFUNCTION|XDFCHECKSUM)\b[\s\S]*?</\1>').allMatches(xml)) {
      final t = m.group(0)!;
      final kind = m.group(1)!;
      final id = _attr(t.substring(0, t.indexOf('>') + 1), 'uniqueid') ?? 'n${out.length}';
      final ti0 = title(t);
      if (ti0.contains('0810124526')) { if (credit.isEmpty) credit = ti0; continue; }   // เครดิตผู้จัดทำ (แสดงที่หัวรายการ)
      if (_bad.hasMatch(ti0)) continue;   // ชื่อร้านอื่น / เบอร์โทร ไม่แสดง
      // รายการที่ไม่มีค่าให้แก้ (หัวข้อไม่มีที่อยู่ / แพตช์ว่าง / ฟังก์ชัน / checksum) ไม่ใส่ในรายการ
      if (kind == 'XDFPATCH') {
        final es = <PatchEntry>[];
        for (final em in RegExp(r'<XDFPATCHENTRY\b[^>]*>').allMatches(t)) {
          final e = em.group(0)!;
          final ad = _hex(_attr(e, 'address'));
          final n = _hex(_attr(e, 'datasize')) ?? 0;
          if (ad == null || n <= 0) continue;
          es.add(PatchEntry(ad, hexBytes(_attr(e, 'patchdata'), n), hexBytes(_attr(e, 'basedata'), n)));
        }
        if (es.isEmpty) { continue; }
        out.add(XdfTable(id: id, title: title(t), kind: ItemKind.patch, address: es.first.addr, patches: es, desc: desc(t), cats: cats(t)));
        continue;
      }
      if (kind == 'XDFFUNCTION') continue;
      if (kind == 'XDFCHECKSUM') continue;
      if (kind == 'XDFFLAG') {
        final ed = RegExp(r'<EMBEDDEDDATA([^>]*)>').firstMatch(t)?.group(1) ?? '';
        final addr = _hex(_attr(ed, 'mmedaddress'));
        if (addr == null) continue;
        final tf = _hex(_attr(ed, 'mmedtypeflags'));
        final bits = (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? 8).abs();
        out.add(XdfTable(
          id: id, title: title(t), kind: ItemKind.flag, address: addr, bits: bits, desc: desc(t), cats: cats(t),
          mask: _hex(RegExp(r'<mask>([^<]*)</mask>').firstMatch(t)?.group(1)) ?? 1,
          lsb: tf == null ? defLsb : (tf & 2) != 0, elemStride: math.max(1, bits ~/ 8),
        ));
        continue;
      }
      if (kind == 'XDFCONSTANT') {
        final ed = RegExp(r'<EMBEDDEDDATA([^>]*)>').firstMatch(t)?.group(1) ?? '';
        final addr = _hex(_attr(ed, 'mmedaddress'));
        if (addr == null) continue;
        final tf = _hex(_attr(ed, 'mmedtypeflags'));
        final bits = (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? defBits).abs();
        final ot = int.tryParse(RegExp(r'<outputtype>(\d+)').firstMatch(t)?.group(1) ?? '') ?? 1;
        out.add(XdfTable(
          id: id, title: title(t), address: addr, bits: bits, desc: desc(t), cats: cats(t),
          dp: ot == 2 ? 0 : (int.tryParse(RegExp(r'<decimalpl>(-?\d+)').firstMatch(t)?.group(1) ?? '') ?? 2), out: ot,
          signed: tf == null ? defSigned : (tf & 1) != 0, lsb: tf == null ? defLsb : (tf & 2) != 0,
          math: LinMath.fromEq(_eq(RegExp(r'<MATH\s+equation="([^"]*)"').firstMatch(t)?.group(1))),
          tmin: double.tryParse(RegExp(r'<rangelow>([^<]*)<').firstMatch(t)?.group(1) ?? '') ?? 0,
          tmax: double.tryParse(RegExp(r'<rangehigh>([^<]*)<').firstMatch(t)?.group(1) ?? '') ?? 255,
        ));
        continue;
      }
      final zm = RegExp(r'<XDFAXIS\s+id="z"[\s\S]*?</XDFAXIS>').firstMatch(t);
      if (zm == null) continue;
      final z = zm.group(0)!;
      final ed = RegExp(r'<EMBEDDEDDATA([^>]*)>').firstMatch(z)?.group(1) ?? '';
      final addr = _hex(_attr(ed, 'mmedaddress'));
      if (addr == null) continue;
      final tf = _hex(_attr(ed, 'mmedtypeflags'));
      final bits = (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? defBits).abs();
      final rc = math.max(1, int.tryParse(_attr(ed, 'mmedrowcount') ?? '') ?? 1);
      final cc = math.max(1, int.tryParse(_attr(ed, 'mmedcolcount') ?? '') ?? 1);
      final major = int.tryParse(_attr(ed, 'mmedmajorstridebits') ?? '') ?? 0;
      final minor = int.tryParse(_attr(ed, 'mmedminorstridebits') ?? '') ?? 0;
      final es = major > 0 ? math.max(1, major ~/ 8) : math.max(1, bits ~/ 8);
      final ot = int.tryParse(RegExp(r'<outputtype>(\d+)').firstMatch(z)?.group(1) ?? '') ?? 1;
      final mn = double.tryParse(RegExp(r'<min>([^<]*)</min>').firstMatch(z)?.group(1) ?? '') ?? 0;
      final mx = double.tryParse(RegExp(r'<max>([^<]*)</max>').firstMatch(z)?.group(1) ?? '') ?? 255;
      out.add(XdfTable(
        id: id, title: title(t), address: addr, bits: bits, rows: rc, cols: cc, desc: desc(t), cats: cats(t),
        dp: ot == 2 ? 0 : (int.tryParse(RegExp(r'<decimalpl>(-?\d+)').firstMatch(z)?.group(1) ?? '') ?? 2),
        out: ot,
        elemStride: es, rowStride: minor > 0 ? math.max(1, minor ~/ 8) : 0,
        signed: tf == null ? defSigned : (tf & 1) != 0,
        lsb: tf == null ? defLsb : (tf & 2) != 0,
        colMajor: tf != null && (tf & 4) != 0,
        math: LinMath.fromEq(_eq(_attr(z, 'equation'))), tmin: mn, tmax: mx,
        x: axis(t, 'x'), y: axis(t, 'y'),
      ));
    }
    final head = RegExp(r'<XDFHEADER>[\s\S]*?</XDFHEADER>').firstMatch(xml)?.group(0) ?? '';
    final cm = <int, String>{};
    for (final m in RegExp(r'<CATEGORY\s+index="([^"]+)"\s+name="([^"]*)"').allMatches(head)) {
      final i = _hex(m[1]); if (i != null) cm[i] = decodeTis620(_entities(m[2]!));
    }
    String hg(String k) => decodeTis620(_entities(RegExp('<$k>([\\s\\S]*?)</$k>').firstMatch(head)?.group(1)?.trim() ?? '')).trim();
    String clean(String v) => _bad.hasMatch(v) ? '' : v;
    return XdfDoc(out, title: clean(hg('deftitle')), desc: clean(hg('description')), cats: cm, credit: credit);
  }
}

// ---------- อ่าน/เขียนค่าดิบ ----------
int _readRaw(Uint8List bin, int off, int bits, bool lsb, bool signed) {
  final n = math.max(1, bits ~/ 8);
  if (off < 0 || off + n > bin.length) return 0;
  int v = 0;
  for (int i = 0; i < n; i++) {
    final b = bin[lsb ? off + n - 1 - i : off + i];
    v = (v << 8) | b;
  }
  if (signed && v >= (1 << (n * 8 - 1))) v -= (1 << (n * 8));
  return v;
}

void _writeRaw(Uint8List bin, int off, int bits, bool lsb, int v) {
  final n = math.max(1, bits ~/ 8);
  if (off < 0 || off + n > bin.length) return;
  for (int i = 0; i < n; i++) {
    final b = (v >> (8 * i)) & 0xFF;
    bin[lsb ? off + i : off + n - 1 - i] = b;
  }
}

class BinTable {
  final Uint8List bin;
  final XdfTable t;
  BinTable(this.bin, this.t);
  int get rows => t.rows;
  int get cols => t.cols;
  int _off(int r, int c) {
    final es = t.elemStride;
    final eb = math.max(1, t.bits ~/ 8);
    // แถว/คอลัมน์ถัดไปเริ่มต่อจากไบต์สุดท้ายของค่าสุดท้าย: (n-1)*stride + ขนาดค่า  (ตารางสลับค่ากับจุดแบ่ง เช่น องศาฉีด)
    if (t.colMajor) {
      final cs = t.rowStride > 0 ? t.rowStride : (t.rows - 1) * es + eb;
      return t.address + c * cs + r * es;
    }
    final rs = t.rowStride > 0 ? t.rowStride : (t.cols - 1) * es + eb;
    return t.address + r * rs + c * es;
  }
  int raw(int r, int c) => _readRaw(bin, _off(r, c), t.bits, t.lsb, t.signed);
  double disp(int r, int c) => t.math.toDisp(raw(r, c));
  void setDisp(int r, int c, double d) => _writeRaw(bin, _off(r, c), t.bits, t.lsb, t.math.toRaw(d, t.bits, t.signed));
  String fmt(double v) {
    switch (t.out) {
      case 2: return v.round().toString();
      case 3: {
        final n = v.round() & ((1 << t.bits) - 1);
        return n.toRadixString(16).toUpperCase().padLeft(math.max(1, t.bits ~/ 4), '0');
      }
      case 4: {
        final n = v.round() & ((1 << t.bits) - 1);
        final cs = <int>[for (int i = t.bits ~/ 8 - 1; i >= 0; i--) (n >> (8 * i)) & 0xFF];
        return String.fromCharCodes(cs.map((c) => (c >= 32 && c < 127) ? c : 46));
      }
      default: return v.toStringAsFixed(t.dp.clamp(0, 6));
    }
  }
  // แปลงข้อความที่ผู้ใช้พิมพ์ -> ค่าแสดงผล (ฐาน 16 รองรับ 0x / ตัวอักษร)
  double? parseIn(String s) {
    s = s.trim();
    if (t.out == 3 || s.toLowerCase().startsWith('0x')) {
      final h = int.tryParse(s.toLowerCase().replaceFirst('0x', ''), radix: 16);
      return h?.toDouble();
    }
    return double.tryParse(s);
  }
  // ค่าทั้งหมดเรียงตามลำดับ (ใช้เป็นหัวแกนของตารางอื่น)
  List<double> flat() => [for (int i = 0; i < t.count; i++) disp(t.cols == 1 ? i : i ~/ t.cols, t.cols == 1 ? 0 : i % t.cols)];
  // FLAG
  bool get flag => (_readRaw(bin, t.address, t.bits, t.lsb, false) & t.mask) != 0;
  set flag(bool on) {
    final v = _readRaw(bin, t.address, t.bits, t.lsb, false);
    _writeRaw(bin, t.address, t.bits, t.lsb, on ? (v | t.mask) : (v & ~t.mask));
  }
  // PATCH: 1 = ใช้แพตช์อยู่ (ทุกจุดตรง patchdata), 0 = ค่าเดิม (ตรง basedata), -1 = ไม่ตรงทั้งสองแบบ
  static bool _eqAt(Uint8List bin, int a, Uint8List d) {
    if (d.isEmpty || a < 0 || a + d.length > bin.length) return false;
    for (int i = 0; i < d.length; i++) { if (bin[a + i] != d[i]) return false; }
    return true;
  }
  int get patchState {
    if (t.patches.isEmpty) return 0;
    if (t.patches.every((e) => _eqAt(bin, e.addr, e.patch))) return 1;
    if (t.patches.every((e) => e.base.isEmpty || _eqAt(bin, e.addr, e.base))) return 0;
    return -1;
  }
  bool get patchOn => patchState == 1;
  void setPatch(bool on) {
    for (final e in t.patches) {
      final d = on ? e.patch : e.base;
      if (d.isEmpty || e.addr < 0 || e.addr + d.length > bin.length) continue;
      for (int i = 0; i < d.length; i++) { bin[e.addr + i] = d[i]; }
    }
  }
  List<int> cur(PatchEntry e) => [for (int i = 0; i < math.max(e.patch.length, e.base.length); i++) e.addr + i < bin.length ? bin[e.addr + i] : 0];
}

// ---------- หัวแกน: ข้อความ + ตัวเลข (สำหรับ LIVE) + ชนิดแกน ----------
class AxisView {
  final List<String> text;
  final List<double?> num;
  final AxKind kind;
  AxisView(this.text, this.num, this.kind);
}

AxKind _kindOf(String s) {
  final u = s.toUpperCase();
  if (s.contains('รอบ') || u.contains('RPM')) return AxKind.rpm;
  if (s.contains('คันเร่ง') || u.contains('TPS') || u.contains('THROTTLE')) return AxKind.tps;
  return AxKind.none;
}

AxisView _axisView(XdfDoc doc, Uint8List bin, XdfAxis? a, int n) {
  if (a != null && a.link != null) {
    final lt = doc.byId[a.link!.toLowerCase()];
    if (lt != null && !lt.isFlag) {
      final bt = BinTable(bin, lt);
      final v = bt.flat();
      String f(double x) => a.dp != null && lt.out == 1 ? x.toStringAsFixed(a.dp!.clamp(0, 6)) : bt.fmt(x);
      return AxisView(
        [for (int i = 0; i < n; i++) i < v.length ? f(v[i]) : '$i'],
        [for (int i = 0; i < n; i++) i < v.length ? v[i] : null],
        _kindOf(lt.title),
      );
    }
  }
  if (a != null && a.type == '1' && a.address != null) {
    final v = [for (int i = 0; i < n; i++) a.math.toDisp(_readRaw(bin, a.address! + i * a.stride, a.bits, a.lsb, a.signed))];
    return AxisView([for (final x in v) x.toStringAsFixed((a.dp ?? 0).clamp(0, 6))], v, AxKind.none);
  }
  final labs = a?.labels ?? const <String>[];
  final text = [for (int i = 0; i < n; i++) i < labs.length ? labs[i] : '${i + 1}'];
  return AxisView(text, [for (final s in text) double.tryParse(s)], AxKind.none);
}

Color _heat(double v, double lo, double hi) {
  if (hi <= lo) return const Color(0xFF2A6BFF);
  double f = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  // น้ำเงิน -> ฟ้า -> เขียว -> เหลือง -> ส้ม -> แดง
  const stops = [Color(0xFF2A4BFF), Color(0xFF17C7FF), Color(0xFF28E070), Color(0xFFF2E400), Color(0xFFFF8A1E), Color(0xFFFF2A2A)];
  final x = f * (stops.length - 1);
  final i = x.floor().clamp(0, stops.length - 2);
  return Color.lerp(stops[i], stops[i + 1], x - i)!;
}

class TunePage extends StatefulWidget {
  final String fileName;
  final Uint8List bin;
  final XdfDoc xdf;
  final double? Function()? getRpm, getTps; // อ่านค่าสดจากกล่อง (null = ไม่มี)
  final Future<void> Function(String name, Uint8List bytes) onSave;
  const TunePage({super.key, required this.fileName, required this.bin, required this.xdf, required this.onSave, this.getRpm, this.getTps});
  @override
  State<TunePage> createState() => _TunePageState();
}

const _kCyan = Color(0xFF18D8FF), _kYel = Color(0xFFFFE01A), _kGrn = Color(0xFF28E070), _kMag = Color(0xFFE040FB), _kOrg = Color(0xFFFF8A1E), _kLime = Color(0xFFB6FF1A);

class _TunePageState extends State<TunePage> {
  late Uint8List bin;
  int ti = 0;
  bool dirty = false, show3d = false, live = true;
  double cLo = 0, cHi = 1;
  final Set<int> sel = {}; // r*cols+c
  List<List<double>>? clip;
  final List<Uint8List> undo = [];
  late AxisView xa, ya; // x = หัวคอลัมน์, y = หัวแถว
  double? liveRpm, liveTps;
  Timer? _liveTimer;
  final _valCtl = TextEditingController(text: '1');
  double get _val => double.tryParse(_valCtl.text) ?? 1;
  // ขนาดหน้าจูน (ตัวอักษร/ช่อง/ปุ่ม) — ปรับได้ จำค่าไว้
  double ui = 0;
  // ลากเลือกหลายช่อง (กดค้างแล้วลาก)
  final _hs = ScrollController(), _vs = ScrollController();
  final _gridKey = GlobalKey(), _viewKey = GlobalKey();
  int? _aR, _aC; // จุดเริ่มลาก (-1 = หัวแถว/หัวคอลัมน์)
  Offset? _dragG; Timer? _edgeTimer;
  double _gcw = 44, _gch = 26, _ghw = 40;
  // 3D
  double _yaw = -0.6, _pitch = 0.9, _zoom = 1, _zoom0 = 1;
  Offset _pan = Offset.zero;
  bool _spin = false; Timer? _spinT;

  List<XdfTable> get items => widget.xdf.items;
  XdfTable get t => items[ti];
  late BinTable bt;
  double s(double v) => v * ui;

  @override
  void initState() {
    super.initState();
    bin = Uint8List.fromList(widget.bin);
    // เปิดตารางน้ำมันหลักก่อน (ตาราง 2 มิติตัวแรก) เหมือนที่ใช้บ่อยสุด
    final first2d = items.indexWhere((e) => e.is2d);
    final firstTab = items.indexWhere((e) => e.isTable);
    ti = first2d >= 0 ? first2d : (firstTab >= 0 ? firstTab : 0);
    _load();
    SharedPreferences.getInstance().then((p) { final v = p.getDouble('tuneScale'); if (v != null && mounted) setState(() => ui = v.clamp(0.7, 1.8)); });
    _liveTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final before = _liveCell();
      liveRpm = widget.getRpm?.call();
      liveTps = widget.getTps?.call();
      if (_liveCell() != before) setState(() {});
    });
  }

  @override
  void dispose() { _liveTimer?.cancel(); _spinT?.cancel(); _edgeTimer?.cancel(); _valCtl.dispose(); _hs.dispose(); _vs.dispose(); super.dispose(); }

  void _setUi(double v) {
    setState(() => ui = v.clamp(0.7, 1.8));
    SharedPreferences.getInstance().then((p) => p.setDouble('tuneScale', ui));
  }

  void _load() {
    bt = BinTable(bin, t);
    sel.clear();
    xa = _axisView(widget.xdf, bin, t.x, t.cols);
    ya = _axisView(widget.xdf, bin, t.y, t.rows);
    if (t.isConst) sel.add(0);
    if (!t.is2d && !t.is1d) { show3d = false; _setSpin(false); }
    _fit();
  }

  void _fit() {
    if (!t.isTable) return;
    double lo = 1e18, hi = -1e18;
    for (int r = 0; r < bt.rows; r++) for (int c = 0; c < bt.cols; c++) { final v = bt.disp(r, c); if (v < lo) lo = v; if (v > hi) hi = v; }
    cLo = lo; cHi = hi;
  }

  void _pushUndo() { undo.add(Uint8List.fromList(bin)); if (undo.length > 30) undo.removeAt(0); }
  void _applyUndo() {
    if (undo.isEmpty) return;
    bin = undo.removeLast();
    final keep = Set<int>.from(sel);
    _load(); sel..clear()..addAll(keep);
    dirty = true;
    setState(() {});
  }

  void _afterEdit() {
    dirty = true;
    xa = _axisView(widget.xdf, bin, t.x, t.cols);
    ya = _axisView(widget.xdf, bin, t.y, t.rows);
    setState(() {});
  }

  void _edit(void Function(int r, int c) f) {
    if (sel.isEmpty || !t.isTable) return;
    _pushUndo();
    for (final k in sel) { f(k ~/ bt.cols, k % bt.cols); }
    _afterEdit();
  }

  void _add(double d) => _edit((r, c) => bt.setDisp(r, c, bt.disp(r, c) + d));
  void _pct(double p) => _edit((r, c) => bt.setDisp(r, c, bt.disp(r, c) * (1 + p / 100)));

  Future<void> _setValue() async {
    final ctl = TextEditingController(text: sel.length == 1 ? bt.fmt(bt.disp(sel.first ~/ bt.cols, sel.first % bt.cols)) : '');
    final v = await showDialog<double>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: Text('ตั้งค่า (${sel.length} ช่อง)', style: const TextStyle(color: Colors.white)),
        content: TextField(controller: ctl, keyboardType: t.out == 3 ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true, signed: true), autofocus: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'ค่าใหม่')),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('ยกเลิก')), TextButton(onPressed: () => Navigator.pop(d, bt.parseIn(ctl.text)), child: const Text('ตั้งค่า'))],
      ),
    );
    if (v != null) _edit((r, c) => bt.setDisp(r, c, v));
  }

  // ไล่ค่าเชิงเส้นระหว่างช่องแรกกับช่องสุดท้ายของแต่ละแถวในช่วงที่เลือก (เหมือน Interpolate ของ TunerPro)
  void _interp() {
    if (sel.length < 3 || !t.isTable) return;
    _pushUndo();
    final rows = <int, List<int>>{};
    for (final k in sel) { rows.putIfAbsent(k ~/ bt.cols, () => []).add(k % bt.cols); }
    final multiCol = rows.values.any((l) => l.length > 2);
    if (multiCol) {
      rows.forEach((r, cs) {
        cs.sort(); if (cs.length < 3) return;
        final a = bt.disp(r, cs.first), b = bt.disp(r, cs.last);
        for (final c in cs) { bt.setDisp(r, c, a + (b - a) * (c - cs.first) / (cs.last - cs.first)); }
      });
    } else {
      final cols = <int, List<int>>{};
      for (final k in sel) { cols.putIfAbsent(k % bt.cols, () => []).add(k ~/ bt.cols); }
      cols.forEach((c, rs) {
        rs.sort(); if (rs.length < 3) return;
        final a = bt.disp(rs.first, c), b = bt.disp(rs.last, c);
        for (final r in rs) { bt.setDisp(r, c, a + (b - a) * (r - rs.first) / (rs.last - rs.first)); }
      });
    }
    _afterEdit();
  }

  void _copy() {
    if (sel.isEmpty) return;
    int r0 = 1 << 30, r1 = -1, c0 = 1 << 30, c1 = -1;
    for (final k in sel) { final r = k ~/ bt.cols, c = k % bt.cols; r0 = math.min(r0, r); r1 = math.max(r1, r); c0 = math.min(c0, c); c1 = math.max(c1, c); }
    clip = [for (int r = r0; r <= r1; r++) [for (int c = c0; c <= c1; c++) bt.disp(r, c)]];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('คัดลอก ${clip!.length}x${clip![0].length}'), duration: const Duration(milliseconds: 800)));
    setState(() {});
  }

  void _paste() {
    if (clip == null || sel.isEmpty) return;
    int r0 = 1 << 30, c0 = 1 << 30;
    for (final k in sel) { r0 = math.min(r0, k ~/ bt.cols); c0 = math.min(c0, k % bt.cols); }
    _pushUndo();
    for (int r = 0; r < clip!.length; r++) for (int c = 0; c < clip![r].length; c++) {
      final rr = r0 + r, cc = c0 + c;
      if (rr < bt.rows && cc < bt.cols) bt.setDisp(rr, cc, clip![r][c]);
    }
    _afterEdit();
  }

  void _toggleFlag(XdfTable f, bool on) {
    _pushUndo();
    BinTable(bin, f).flag = on;
    dirty = true;
    setState(() {});
  }

  void _togglePatch(XdfTable f, bool on) {
    _pushUndo();
    BinTable(bin, f).setPatch(on);
    dirty = true;
    setState(() {});
  }

  int _nearest(AxisView a, double v) {
    int best = -1; double bd = 1e18;
    for (int i = 0; i < a.num.length; i++) { final n = a.num[i]; if (n == null) continue; final d = (n - v).abs(); if (d < bd) { bd = d; best = i; } }
    return best;
  }

  int? _axisIdx(AxisView a, int n) {
    if (n == 1) return 0;
    if (a.kind == AxKind.rpm && liveRpm != null) { final i = _nearest(a, liveRpm!); return i < 0 ? null : i; }
    if (a.kind == AxKind.tps && liveTps != null) { final i = _nearest(a, liveTps!); return i < 0 ? null : i; }
    return null;
  }

  int? _liveCell() {
    if (!live || !t.isTable || t.isConst) return null;
    final r = _axisIdx(ya, bt.rows), c = _axisIdx(xa, bt.cols);
    if (r == null || c == null) return null;
    return r * bt.cols + c;
  }

  Future<void> _save() async {
    final base = widget.fileName.replaceAll(RegExp(r'\.bin$', caseSensitive: false), '');
    final name = base.endsWith('_tuned') ? '$base.bin' : '${base}_tuned.bin';
    await widget.onSave(name, Uint8List.fromList(bin));
    dirty = false;
    if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('เซฟลงคลัง: $name'))); }
  }

  void _go(int i) { if (i < 0 || i >= items.length) return; setState(() { ti = i; _load(); }); }

  IconData _icon(XdfTable e) => e.isFlag ? Icons.check_box_outlined : e.isPatch ? Icons.build_circle_outlined : e.isInfo ? Icons.info_outline
      : (e.is2d ? Icons.grid_on : (e.isConst ? Icons.looks_one_outlined : Icons.view_week_outlined));
  Color _icol(XdfTable e) => e.isFlag ? _kYel : e.isPatch ? _kOrg : e.isInfo ? Colors.white38 : (e.is2d ? _kCyan : _kGrn);

  // รายการพารามิเตอร์ทั้งหมด (Parameter Tree ของ TunerPro) + กรองชนิด/หมวด
  int _fk = 0; int? _fcat;
  Future<void> _pickParam() async {
    const fl = ['ทั้งหมด', 'ตาราง', 'ค่าเดียว', 'FLAG', 'แพตช์'];
    bool ok(XdfTable e) {
      switch (_fk) {
        case 1: if (!(e.isTable && !e.isConst)) return false; break;
        case 2: if (!e.isConst) return false; break;
        case 3: if (!e.isFlag) return false; break;
        case 4: if (!e.isPatch) return false; break;
        case 5: if (!e.isInfo) return false; break;
      }
      if (_fcat != null && !e.cats.contains(_fcat)) return false;
      return true;
    }
    int n(int k) { final o = _fk; _fk = k; final r = items.where(ok).length; _fk = o; return r; }
    final usedCats = <int>{for (final e in items) ...e.cats}.where((c) => widget.xdf.cats.containsKey(c)).toList()..sort();
    final i = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF0C0F13),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final idx = [for (int k = 0; k < items.length; k++) if (ok(items[k])) k];
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.88,
            child: Column(children: [
              Padding(
                padding: EdgeInsets.fromLTRB(s(14), s(10), s(14), s(4)),
                child: Row(children: [
                  Icon(Icons.account_tree_outlined, color: _kCyan, size: s(18)),
                  SizedBox(width: s(8)),
                  Expanded(child: Text(widget.xdf.title.isEmpty ? 'พารามิเตอร์ทั้งหมด' : widget.xdf.title, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: s(14)))),
                  Text('${items.length} รายการ', style: TextStyle(color: Colors.white38, fontSize: s(11))),
                ]),
              ),
              if (widget.xdf.credit.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(s(14), 0, s(14), s(6)),
                  child: Row(children: [
                    Icon(Icons.verified_outlined, color: _kLime, size: s(14)),
                    SizedBox(width: s(6)),
                    Expanded(child: Text(widget.xdf.credit, style: TextStyle(color: _kLime, fontSize: s(12), fontWeight: FontWeight.bold))),
                  ]),
                ),
              SizedBox(
                height: s(34),
                child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.symmetric(horizontal: s(8)), children: [
                  for (int k = 0; k < fl.length; k++)
                    Padding(padding: EdgeInsets.symmetric(horizontal: s(3)), child: ChoiceChip(
                      label: Text('${fl[k]} ${n(k)}', style: TextStyle(fontSize: s(11), color: _fk == k ? Colors.black : Colors.white70)),
                      selected: _fk == k, selectedColor: _kCyan, backgroundColor: const Color(0xFF151A21), visualDensity: VisualDensity.compact,
                      onSelected: (_) => setS(() => _fk = k))),
                ]),
              ),
              if (usedCats.isNotEmpty)
                SizedBox(
                  height: s(32),
                  child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.symmetric(horizontal: s(8)), children: [
                    Padding(padding: EdgeInsets.symmetric(horizontal: s(3)), child: ChoiceChip(
                      label: Text('ทุกหมวด', style: TextStyle(fontSize: s(10.5), color: _fcat == null ? Colors.black : Colors.white60)),
                      selected: _fcat == null, selectedColor: _kYel, backgroundColor: const Color(0xFF151A21), visualDensity: VisualDensity.compact,
                      onSelected: (_) => setS(() => _fcat = null))),
                    for (final c in usedCats)
                      Padding(padding: EdgeInsets.symmetric(horizontal: s(3)), child: ChoiceChip(
                        label: Text(widget.xdf.cats[c]!, style: TextStyle(fontSize: s(10.5), color: _fcat == c ? Colors.black : Colors.white60)),
                        selected: _fcat == c, selectedColor: _kYel, backgroundColor: const Color(0xFF151A21), visualDensity: VisualDensity.compact,
                        onSelected: (_) => setS(() => _fcat = c))),
                  ]),
                ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: idx.isEmpty
                  ? Center(child: Text('ไม่พบรายการ', style: TextStyle(color: Colors.white38, fontSize: s(13))))
                  : ListView.builder(
                      itemCount: idx.length,
                      itemBuilder: (_, j) {
                        final i = idx[j];
                        final e = items[i];
                        final cur = i == ti;
                        Widget? trail;
                        if (e.isFlag) {
                          trail = Switch(value: BinTable(bin, e).flag, activeColor: _kYel, onChanged: (v) { _toggleFlag(e, v); setS(() {}); });
                        } else if (e.isPatch) {
                          final st = BinTable(bin, e).patchState;
                          trail = Row(mainAxisSize: MainAxisSize.min, children: [
                            if (st < 0) Icon(Icons.warning_amber, color: _kOrg, size: s(16)),
                            Switch(value: st == 1, activeColor: _kOrg, onChanged: (v) { _togglePatch(e, v); setS(() {}); }),
                          ]);
                        }
                        return ListTile(
                          dense: true,
                          selected: cur,
                          selectedTileColor: _kCyan.withOpacity(0.12),
                          leading: Icon(_icon(e), size: s(18), color: _icol(e)),
                          title: Text(e.title, style: TextStyle(color: cur ? _kCyan : (e.isInfo ? Colors.white54 : Colors.white), fontSize: s(13))),
                          subtitle: Text(
                            e.isInfo ? e.info.split('\n').first : '${e.kindLabel} · 0x${e.address.toRadixString(16).toUpperCase()}${e.isFlag ? ' · mask 0x${e.mask.toRadixString(16).toUpperCase()}' : ''}${e.cats.isNotEmpty && widget.xdf.cats[e.cats.last] != null ? ' · ${widget.xdf.cats[e.cats.last]}' : ''}',
                            style: TextStyle(color: Colors.white38, fontSize: s(10))),
                          trailing: trail,
                          onTap: () => Navigator.pop(ctx, i),
                        );
                      },
                    )),
            ]),
          ),
        );
      }),
    );
    if (i != null) _go(i);
  }

  Future<void> _sizeSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0C0F13),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ขนาดหน้าจูน  ${(ui * 100).round()}%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('ปรับตัวอักษร ช่องตาราง และปุ่ม ให้พอดีกับจอ (จำค่าไว้)', style: TextStyle(color: Colors.white54, fontSize: 12)),
          Slider(value: ui, min: 0.7, max: 1.8, divisions: 22, activeColor: _kCyan, label: '${(ui * 100).round()}%', onChanged: (v) { _setUi(v); setS(() {}); }),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in const [0.8, 0.9, 1.0, 1.15, 1.3, 1.5])
              OutlinedButton(onPressed: () { _setUi(p); setS(() {}); }, child: Text('${(p * 100).round()}%')),
            OutlinedButton(onPressed: () { _setUi(_autoUi(context)); setS(() {}); }, child: const Text('อัตโนมัติตามจอ')),
          ]),
        ]),
      ))),
    );
  }

  double _autoUi(BuildContext c) {
    final mq = MediaQuery.of(c);
    final w = mq.size.shortestSide;
    return (w / 400).clamp(0.8, 1.4);
  }

  @override
  Widget build(BuildContext context) {
    if (ui == 0) ui = _autoUi(context);
    if (items.isEmpty) {
      return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, title: const Text('จูน')), body: const Center(child: Text('XDF นี้ไม่มีพารามิเตอร์', style: TextStyle(color: Colors.white70))));
    }
    final liveC = _liveCell();
    Widget body;
    if (t.isFlag) {
      body = _flagView();
    } else if (t.isPatch) {
      body = _patchView();
    } else if (t.isInfo) {
      body = _infoView();
    } else if (t.isConst) {
      body = _constView();
    } else if (show3d) {
      body = t.is2d ? _surface3d(liveC) : _line1d(liveC);
    } else {
      body = _grid(liveC);
    }
    String info;
    if (t.isFlag) {
      info = 'FLAG · 0x${t.address.toRadixString(16).toUpperCase()} · mask 0x${t.mask.toRadixString(16).toUpperCase()}';
    } else if (t.isPatch) {
      info = 'แพตช์ · ${t.patches.length} จุด · 0x${t.address.toRadixString(16).toUpperCase()}';
    } else if (t.isInfo) {
      info = 'หมายเหตุใน XDF';
    } else {
      info = '${t.kindLabel} · ${t.bits}bit · 0x${t.address.toRadixString(16).toUpperCase()} · ${widget.fileName}';
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          _titleBar(),
          if (t.isTable) _toolbar(),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: s(8), vertical: s(2)),
            child: Row(children: [
              Expanded(child: Text(info, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white38, fontSize: s(10)))),
              if (t.isTable && !t.isConst && sel.length > 1) Text('เลือก ${sel.length} ช่อง  ', style: TextStyle(color: _kMag, fontSize: s(10), fontWeight: FontWeight.bold)),
              if (liveRpm != null) Text('RPM ${liveRpm!.toStringAsFixed(0)} · TPS ${liveTps?.toStringAsFixed(1) ?? "-"}', style: TextStyle(color: _kLime, fontSize: s(10))),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
    );
  }

  Widget _tb(IconData ic, String lab, VoidCallback? f, {Color col = Colors.white, bool on = false}) => Padding(
        padding: EdgeInsets.symmetric(horizontal: s(2.5)),
        child: InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: BoxConstraints(minHeight: s(30), minWidth: s(30)),
            padding: EdgeInsets.symmetric(horizontal: s(8), vertical: s(6)),
            decoration: BoxDecoration(color: on ? col.withOpacity(0.25) : Colors.black45, border: Border.all(color: f == null ? Colors.white12 : col.withOpacity(on ? 1 : 0.5)), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(ic, size: s(15), color: f == null ? Colors.white24 : col),
              if (lab.isNotEmpty) ...[SizedBox(width: s(4)), Text(lab, style: TextStyle(color: f == null ? Colors.white24 : col, fontSize: s(11.5), fontWeight: FontWeight.bold))],
            ]),
          ),
        ),
      );

  // แถวบน: ย้อนกลับ · ชื่อพารามิเตอร์ (กดเพื่อเลือกจากรายการทั้งหมด) · ก่อนหน้า/ถัดไป · ขนาด · เซฟ
  Widget _titleBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(s(4), s(6), s(4), s(2)),
      color: const Color(0xFF0C0F13),
      child: Row(children: [
        _tb(Icons.arrow_back, '', () => Navigator.pop(context), col: _kCyan),
        Expanded(
          child: InkWell(
            onTap: _pickParam,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: s(3)),
              padding: EdgeInsets.symmetric(horizontal: s(8), vertical: s(5)),
              decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: _kCyan), borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                Icon(_icon(t), size: s(15), color: _icol(t)),
                SizedBox(width: s(6)),
                Expanded(child: Text(t.title, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: s(13), fontWeight: FontWeight.bold))),
                Text('${ti + 1}/${items.length}', style: TextStyle(color: Colors.white38, fontSize: s(10))),
                Icon(Icons.arrow_drop_down, color: _kCyan, size: s(18)),
              ]),
            ),
          ),
        ),
        _tb(Icons.chevron_left, '', ti > 0 ? () => _go(ti - 1) : null, col: _kCyan),
        _tb(Icons.chevron_right, '', ti < items.length - 1 ? () => _go(ti + 1) : null, col: _kCyan),
        _tb(Icons.format_size, '', _sizeSheet, col: Colors.white70),
        _tb(Icons.save, 'เซฟ', _save, col: dirty ? _kGrn : Colors.white, on: dirty),
      ]),
    );
  }

  Widget _toolbar() {
    final can = sel.isNotEmpty;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: s(4), vertical: s(4)),
      color: const Color(0xFF0C0F13),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          // ช่องค่า (ใช้กับ +/- และ % เหมือน TunerPro)
          Container(
            width: s(58), height: s(32), margin: EdgeInsets.symmetric(horizontal: s(3)),
            decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: _kYel), borderRadius: BorderRadius.circular(6)),
            child: Center(child: TextField(
              controller: _valCtl, textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              style: TextStyle(color: Colors.white, fontSize: s(12.5)),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'ค่า', contentPadding: EdgeInsets.zero),
            )),
          ),
          _tb(Icons.remove, '', can ? () => _add(-_val) : null, col: _kCyan),
          _tb(Icons.add, '', can ? () => _add(_val) : null, col: _kCyan),
          _tb(Icons.percent, '-', can ? () => _pct(-_val) : null, col: _kOrg),
          _tb(Icons.percent, '+', can ? () => _pct(_val) : null, col: _kGrn),
          _tb(Icons.edit, 'ตั้งค่า', can ? _setValue : null),
          if (!t.isConst) ...[
            _tb(Icons.linear_scale, 'ไล่ค่า', sel.length >= 3 ? _interp : null, col: _kYel),
            _tb(Icons.select_all, 'ทั้งหมด', () => setState(() { sel..clear()..addAll([for (int i = 0; i < t.count; i++) i]); })),
            _tb(Icons.deselect, 'ล้าง', can ? () => setState(sel.clear) : null),
            _tb(Icons.copy, 'COPY', can ? _copy : null),
            _tb(Icons.paste, 'PASTE', clip == null || !can ? null : _paste),
          ],
          _tb(Icons.undo, '', undo.isEmpty ? null : _applyUndo),
          if (!t.isConst) ...[
            _tb(Icons.straighten, 'FIT', () => setState(_fit)),
            _tb(show3d ? Icons.grid_on : (t.is2d ? Icons.view_in_ar : Icons.show_chart), show3d ? 'ตาราง' : (t.is2d ? '3D' : 'กราฟ'), () => setState(() { show3d = !show3d; if (!show3d) _setSpin(false); }), col: _kMag, on: show3d),
            _tb(Icons.circle, 'LIVE', () => setState(() => live = !live), col: _kLime, on: live),
          ],
        ]),
      ),
    );
  }

  double _textW(String str, double perChar) => str.length * perChar + 10;

  // ---------- ลากเลือกหลายช่อง: กดค้างที่ช่อง แล้วลากนิ้ว ----------
  (int, int) _cellAt(Offset p) {
    final c = ((p.dx - _ghw) / _gcw).floor(), r = ((p.dy - _gch) / _gch).floor();
    return (p.dy < _gch ? -1 : r.clamp(0, bt.rows - 1), p.dx < _ghw ? -1 : c.clamp(0, bt.cols - 1));
  }
  void _dragSel(Offset local) {
    if (_aR == null || _aC == null) return;
    final (r, c) = _cellAt(local);
    final ar = _aR!, ac = _aC!;
    final r0 = ar < 0 ? 0 : math.min(ar, math.max(r, 0)), r1 = ar < 0 ? bt.rows - 1 : math.max(ar, math.max(r, 0));
    final c0 = ac < 0 ? 0 : math.min(ac, math.max(c, 0)), c1 = ac < 0 ? bt.cols - 1 : math.max(ac, math.max(c, 0));
    final ns = <int>{for (int y = r0; y <= r1; y++) for (int x = c0; x <= c1; x++) y * bt.cols + x};
    if (ns.length != sel.length || !ns.containsAll(sel)) setState(() { sel..clear()..addAll(ns); });
  }
  void _edgeScroll() {
    final g = _dragG; final vb = _viewKey.currentContext?.findRenderObject() as RenderBox?; final cb = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (g == null || vb == null || cb == null) return;
    final p = vb.globalToLocal(g); final sz = vb.size; final e = s(36); final sp = s(14);
    bool moved = false;
    void mv(ScrollController sc, double d) { if (!sc.hasClients) return; final o = (sc.offset + d).clamp(0.0, sc.position.maxScrollExtent); if (o != sc.offset) { sc.jumpTo(o); moved = true; } }
    if (p.dx > sz.width - e) mv(_hs, sp); else if (p.dx < e) mv(_hs, -sp);
    if (p.dy > sz.height - e) mv(_vs, sp); else if (p.dy < e) mv(_vs, -sp);
    if (moved) _dragSel(cb.globalToLocal(g));
  }

  Widget _grid(int? liveC) {
    final f = ui;
    double cw = 44 * f;
    for (int r = 0; r < bt.rows; r++) for (int c = 0; c < bt.cols; c++) { cw = math.max(cw, _textW(bt.fmt(bt.disp(r, c)), 6.4 * f)); }
    for (final str in xa.text) { cw = math.max(cw, _textW(str, 6.0 * f)); }
    cw = math.min(cw, 100 * f);
    double hw = 40 * f;
    for (final str in ya.text) { hw = math.max(hw, _textW(str, 6.0 * f)); }
    hw = math.min(hw, 116 * f);
    final ch = 27.0 * f;
    _gcw = cw; _gch = ch; _ghw = hw;
    return Column(children: [
      Expanded(child: SizedBox(
        key: _viewKey,
        child: Scrollbar(controller: _vs, child: SingleChildScrollView(
          controller: _vs,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _hs,
            scrollDirection: Axis.horizontal,
            child: GestureDetector(
              key: _gridKey,
              onLongPressStart: (d) {
                final (r, c) = _cellAt(d.localPosition);
                if (r < 0 && c < 0) return;
                HapticFeedback.selectionClick();
                _aR = r; _aC = c; _dragG = d.globalPosition;
                setState(() => sel.clear());
                _dragSel(d.localPosition);
                _edgeTimer?.cancel();
                _edgeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _edgeScroll());
              },
              onLongPressMoveUpdate: (d) { _dragG = d.globalPosition; _dragSel(d.localPosition); },
              onLongPressEnd: (_) { _aR = _aC = null; _dragG = null; _edgeTimer?.cancel(); _edgeTimer = null; },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: hw, height: ch, alignment: Alignment.center, color: const Color(0xFF12161C), child: Text('${bt.rows}x${bt.cols}', style: TextStyle(color: Colors.white38, fontSize: 9 * f))),
                  for (int c = 0; c < bt.cols; c++)
                    GestureDetector(
                      onTap: () => setState(() { final col = [for (int r = 0; r < bt.rows; r++) r * bt.cols + c]; if (col.every(sel.contains)) { sel.removeAll(col); } else { sel.addAll(col); } }),
                      child: Container(width: cw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                        child: Text(xa.text[c], maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(color: _kCyan, fontSize: 9.5 * f, fontWeight: FontWeight.bold))),
                    ),
                ]),
                for (int r = 0; r < bt.rows; r++)
                  Row(children: [
                    GestureDetector(
                      onTap: () => setState(() { final row = [for (int c = 0; c < bt.cols; c++) r * bt.cols + c]; if (row.every(sel.contains)) { sel.removeAll(row); } else { sel.addAll(row); } }),
                      child: Container(width: hw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                        child: Text(ya.text[r], maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(color: _kYel, fontSize: 9.5 * f, fontWeight: FontWeight.bold))),
                    ),
                    for (int c = 0; c < bt.cols; c++) _cell(r, c, cw, ch, liveC),
                  ]),
              ]),
            ),
          ),
        )),
      )),
      Container(
        width: double.infinity,
        color: const Color(0xFF0C0F13),
        padding: EdgeInsets.symmetric(vertical: s(3), horizontal: s(8)),
        child: Text('แตะ = เลือก/ยกเลิกทีละช่อง · กดค้างแล้วลาก = เลือกหลายช่อง (ลากที่หัวแถว/หัวคอลัมน์ = ทั้งแถว/คอลัมน์)', style: TextStyle(color: Colors.white38, fontSize: s(9.5))),
      ),
    ]);
  }

  Widget _cell(int r, int c, double w, double h, int? liveC) {
    final k = r * bt.cols + c;
    final v = bt.disp(r, c);
    final selected = sel.contains(k);
    final isLive = liveC == k;
    return GestureDetector(
      onTap: () => setState(() { if (selected) sel.remove(k); else sel.add(k); }),
      child: Container(
        width: w, height: h, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _heat(v, cLo, cHi),
          border: Border.all(color: isLive ? Colors.white : (selected ? _kMag : Colors.black26), width: isLive ? 2 : (selected ? 2 : 0.3)),
        ),
        foregroundDecoration: selected ? BoxDecoration(color: _kMag.withOpacity(0.18)) : null,
        child: Text(bt.fmt(v), style: TextStyle(color: Colors.black.withOpacity(0.85), fontSize: 10 * ui, fontWeight: isLive ? FontWeight.w900 : FontWeight.w600)),
      ),
    );
  }

  Widget _card(Color col, List<Widget> kids) => Center(
        child: SingleChildScrollView(
          child: Container(
            margin: EdgeInsets.all(s(20)),
            padding: EdgeInsets.all(s(22)),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: col), borderRadius: BorderRadius.circular(14)),
            child: Column(mainAxisSize: MainAxisSize.min, children: kids),
          ),
        ),
      );
  List<Widget> _desc() => t.desc.isEmpty ? const [] : [SizedBox(height: s(8)), Text(t.desc, textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: s(11.5)))];

  Widget _constView() {
    final v = bt.disp(0, 0);
    return _card(_kGrn, [
      Text(t.title, textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: s(14))),
      ..._desc(),
      SizedBox(height: s(14)),
      GestureDetector(onTap: _setValue, child: Text(bt.fmt(v), style: TextStyle(color: _kGrn, fontSize: s(48), fontWeight: FontWeight.w900))),
      SizedBox(height: s(6)),
      Text('ดิบ ${bt.raw(0, 0)} · แตะตัวเลขเพื่อพิมพ์ค่า', style: TextStyle(color: Colors.white38, fontSize: s(11))),
      SizedBox(height: s(16)),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _tb(Icons.remove, _valCtl.text, () => _add(-_val), col: _kCyan),
        SizedBox(width: s(12)),
        _tb(Icons.add, _valCtl.text, () => _add(_val), col: _kCyan),
      ]),
    ]);
  }

  Widget _flagView() {
    final on = bt.flag;
    return _card(_kYel, [
      Text(t.title, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: s(16), fontWeight: FontWeight.bold)),
      ..._desc(),
      SizedBox(height: s(16)),
      Transform.scale(scale: 1.6 * ui, child: Switch(value: on, activeColor: _kYel, onChanged: (v) => _toggleFlag(t, v))),
      SizedBox(height: s(10)),
      Text(on ? 'เปิด (ติ๊ก)' : 'ปิด (ไม่ติ๊ก)', style: TextStyle(color: on ? _kYel : Colors.white54, fontSize: s(14), fontWeight: FontWeight.bold)),
    ]);
  }

  String _hx(List<int> b) => b.map((x) => x.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');

  Widget _patchView() {
    final st = bt.patchState;
    final lab = st == 1 ? 'ใช้แพตช์อยู่ (เปิด)' : st == 0 ? 'ค่าเดิม (ปิด)' : 'ค่าในไฟล์ไม่ตรงทั้งค่าเดิมและแพตช์';
    final lc = st == 1 ? _kOrg : st == 0 ? Colors.white54 : const Color(0xFFFF5050);
    return _card(_kOrg, [
      Icon(Icons.build_circle_outlined, color: _kOrg, size: s(30)),
      SizedBox(height: s(6)),
      Text(t.title, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: s(17), fontWeight: FontWeight.bold)),
      ..._desc(),
      SizedBox(height: s(14)),
      Transform.scale(scale: 1.6 * ui, child: Switch(value: st == 1, activeColor: _kOrg, onChanged: (v) => _togglePatch(t, v))),
      SizedBox(height: s(8)),
      Text(lab, textAlign: TextAlign.center, style: TextStyle(color: lc, fontSize: s(14), fontWeight: FontWeight.bold)),
      if (st < 0) Padding(padding: EdgeInsets.only(top: s(4)), child: Text('เปิด = เขียนค่าแพตช์ทับ · ปิด = เขียนค่าเดิมกลับ', style: TextStyle(color: Colors.white38, fontSize: s(11)))),
      SizedBox(height: s(14)),
      Table(
        columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth(), 2: FlexColumnWidth(), 3: FlexColumnWidth()},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            for (final h in const ['ที่อยู่', 'เดิม', 'แพตช์', 'ในไฟล์'])
              Padding(padding: EdgeInsets.all(s(4)), child: Text(h, style: TextStyle(color: Colors.white54, fontSize: s(10.5), fontWeight: FontWeight.bold))),
          ]),
          for (final e in t.patches)
            TableRow(children: [
              Padding(padding: EdgeInsets.all(s(4)), child: Text('0x${e.addr.toRadixString(16).toUpperCase()}', style: TextStyle(color: _kCyan, fontSize: s(10.5), fontFamily: 'monospace'))),
              Padding(padding: EdgeInsets.all(s(4)), child: Text(_hx(e.base), style: TextStyle(color: Colors.white70, fontSize: s(10.5), fontFamily: 'monospace'))),
              Padding(padding: EdgeInsets.all(s(4)), child: Text(_hx(e.patch), style: TextStyle(color: _kOrg, fontSize: s(10.5), fontFamily: 'monospace'))),
              Padding(padding: EdgeInsets.all(s(4)), child: Text(_hx(bt.cur(e)), style: TextStyle(color: Colors.white, fontSize: s(10.5), fontFamily: 'monospace', fontWeight: FontWeight.bold))),
            ]),
        ],
      ),
    ]);
  }

  Widget _infoView() => _card(Colors.white24, [
        Icon(Icons.info_outline, color: Colors.white54, size: s(28)),
        SizedBox(height: s(8)),
        Text(t.title, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: s(16), fontWeight: FontWeight.bold)),
        ..._desc(),
        SizedBox(height: s(10)),
        Text(t.info, textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: s(12), height: 1.5)),
      ]);

  Widget _line1d(int? liveC) => CustomPaint(painter: _LinePainter(bt, cLo, cHi, t.rows == 1 ? xa.text : ya.text, liveC, ui), size: Size.infinite);

  // ---------- 3D: ลากนิ้วเดียว = หมุน · สองนิ้ว = ซูม/เลื่อน · พรีวิว = หมุนช้า ๆ เอง ----------
  void _setSpin(bool on) {
    _spin = on; _spinT?.cancel(); _spinT = null;
    if (on) _spinT = Timer.periodic(const Duration(milliseconds: 33), (_) { if (mounted) setState(() => _yaw += 0.006); });
  }
  Widget _surface3d(int? liveC) {
    return Stack(children: [
      Positioned.fill(child: GestureDetector(
        onScaleStart: (d) { _zoom0 = _zoom; },
        onScaleUpdate: (d) => setState(() {
          if (d.pointerCount >= 2) {
            _zoom = (_zoom0 * d.scale).clamp(0.4, 5.0);
            _pan += d.focalPointDelta;
          } else {
            _yaw += d.focalPointDelta.dx * 0.01;
            _pitch = (_pitch - d.focalPointDelta.dy * 0.01).clamp(0.05, 1.5);
          }
        }),
        onDoubleTap: () => setState(() { _zoom = 1; _pan = Offset.zero; _yaw = -0.6; _pitch = 0.9; }),
        child: CustomPaint(painter: _SurfPainter(bt, cLo, cHi, _yaw, _pitch, _zoom, _pan, liveC, xa, ya, ui), size: Size.infinite),
      )),
      Positioned(right: s(8), top: s(8), child: Column(children: [
        _tb(_spin ? Icons.pause : Icons.threesixty, _spin ? 'หยุด' : 'พรีวิว', () => setState(() => _setSpin(!_spin)), col: _kMag, on: _spin),
        SizedBox(height: s(6)),
        _tb(Icons.zoom_in, '', () => setState(() => _zoom = (_zoom * 1.25).clamp(0.4, 5.0)), col: _kCyan),
        SizedBox(height: s(6)),
        _tb(Icons.zoom_out, '', () => setState(() => _zoom = (_zoom / 1.25).clamp(0.4, 5.0)), col: _kCyan),
        SizedBox(height: s(6)),
        _tb(Icons.center_focus_strong, '', () => setState(() { _zoom = 1; _pan = Offset.zero; _yaw = -0.6; _pitch = 0.9; }), col: Colors.white70),
      ])),
      Positioned(left: s(8), bottom: s(6), child: Text('ลาก = หมุน · 2 นิ้ว = ซูม/เลื่อน · แตะ 2 ครั้ง = มุมเริ่มต้น', style: TextStyle(color: Colors.white38, fontSize: s(9.5)))),
    ]);
  }
}

// กราฟเส้นสำหรับตาราง 1 มิติ
class _LinePainter extends CustomPainter {
  final BinTable bt;
  final double lo, hi, ui;
  final List<String> labels;
  final int? liveC;
  _LinePainter(this.bt, this.lo, this.hi, this.labels, this.liveC, this.ui);
  @override
  void paint(Canvas cv, Size s) {
    final n = bt.t.count;
    if (n < 2) return;
    double v(int i) => bt.rows == 1 ? bt.disp(0, i) : bt.disp(i, 0);
    final l = 46.0 * ui, r = 12.0 * ui, top = 16.0 * ui, bot = 30.0 * ui;
    final w = s.width - l - r, h = s.height - top - bot;
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : (hi - lo);
    Offset p(int i) => Offset(l + w * i / (n - 1), top + h * (1 - (v(i) - lo) / span));
    final grid = Paint()..color = Colors.white10..strokeWidth = 1;
    for (int k = 0; k <= 4; k++) {
      final y = top + h * k / 4;
      cv.drawLine(Offset(l, y), Offset(l + w, y), grid);
      final tp = TextPainter(text: TextSpan(text: bt.fmt(hi - span * k / 4), style: TextStyle(color: Colors.white38, fontSize: 9.5 * ui, fontFamily: kPaintFont, fontFamilyFallback: kPaintFallback)), textDirection: TextDirection.ltr)..layout();
      tp.paint(cv, Offset(l - tp.width - 4, y - tp.height / 2));
    }
    final path = Path()..moveTo(p(0).dx, p(0).dy);
    for (int i = 1; i < n; i++) { path.lineTo(p(i).dx, p(i).dy); }
    cv.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2 * ui..color = _kCyan);
    final step = math.max(1, (n / (8 * math.min(1.6, s.width / 360))).ceil());
    for (int i = 0; i < n; i++) {
      cv.drawCircle(p(i), 3 * ui, Paint()..color = _heat(v(i), lo, hi));
      if (i % step == 0 && i < labels.length) {
        final tp = TextPainter(text: TextSpan(text: labels[i], style: TextStyle(color: _kCyan, fontSize: 9.5 * ui, fontFamily: kPaintFont, fontFamilyFallback: kPaintFallback)), textDirection: TextDirection.ltr)..layout();
        tp.paint(cv, Offset(p(i).dx - tp.width / 2, top + h + 8));
      }
    }
    if (liveC != null && liveC! < n) {
      cv.drawCircle(p(liveC!), 7 * ui, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.white);
    }
  }
  @override
  bool shouldRepaint(_LinePainter o) => true;
}

// พื้นผิว 3 มิติ: วาดจากไกลไปใกล้ (เรียงตามความลึก) + พื้น/แกน/ตัวเลขหัวแกน + ซูม/เลื่อน
class _SurfPainter extends CustomPainter {
  final BinTable bt;
  final double lo, hi, yaw, pitch, zoom, ui;
  final Offset pan;
  final int? liveC;
  final AxisView xa, ya;
  _SurfPainter(this.bt, this.lo, this.hi, this.yaw, this.pitch, this.zoom, this.pan, this.liveC, this.xa, this.ya, this.ui);
  @override
  void paint(Canvas cv, Size s) {
    final R = bt.rows, C = bt.cols;
    if (R < 2 || C < 2) return;
    final cx = s.width / 2 + pan.dx, cy = s.height * 0.56 + pan.dy;
    final scale = math.min(s.width, s.height) * 0.86 * zoom;
    final zr = (hi - lo).abs() < 1e-6 ? 1.0 : (hi - lo);
    final cy0 = math.cos(yaw), sy0 = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    // (x, y, z) ใน -0.5..0.5 -> จุดบนจอ + ความลึก
    (Offset, double) prj(double x, double y, double z) {
      final rx = x * cy0 - y * sy0;
      final ry = x * sy0 + y * cy0;
      final py = ry * cp - z * 0.6 * sp;
      final depth = ry * sp + z * 0.6 * cp;
      final f = 1.0 / (1.6 - depth * 0.4);
      return (Offset(cx + rx * scale * f, cy + py * scale * f), depth);
    }
    // แกน TPS/MAP ไว้ซ้าย แกนรอบเครื่องไว้ขวา (ถ้าแถวเป็นรอบเครื่อง -> สลับแกนในภาพ 3D)
    final swap = ya.kind == AxKind.rpm && xa.kind != AxKind.rpm;
    double rf(int r) => r / (R - 1) - 0.5;
    double cf(int c) => c / (C - 1) - 0.5;
    double gz(int r, int c) => (bt.disp(r, c) - lo) / zr - 0.5;
    (Offset, double) pq(double a, double b, double z) => swap ? prj(a, b, z) : prj(b, a, z); // a = ตำแหน่งแถว, b = ตำแหน่งคอลัมน์
    final pts = List.generate(R, (r) => List.generate(C, (c) => pq(rf(r), cf(c), gz(r, c))));
    // พื้น + เส้นกริด
    final floor = Paint()..style = PaintingStyle.stroke..color = Colors.white12..strokeWidth = 1;
    Offset fp(double a, double b) => pq(a, b, -0.5).$1;
    for (int c = 0; c < C; c += math.max(1, (C / 8).ceil())) { cv.drawLine(fp(-0.5, cf(c)), fp(0.5, cf(c)), floor); }
    for (int r = 0; r < R; r += math.max(1, (R / 8).ceil())) { cv.drawLine(fp(rf(r), -0.5), fp(rf(r), 0.5), floor); }
    cv.drawPath(Path()..addPolygon([fp(-0.5, -0.5), fp(0.5, -0.5), fp(0.5, 0.5), fp(-0.5, 0.5)], true), Paint()..style = PaintingStyle.stroke..color = Colors.white24..strokeWidth = 1.2);
    // สี่เหลี่ยมเรียงจากไกลไปใกล้
    final quads = <(double, int, int)>[];
    for (int r = 0; r < R - 1; r++) {
      for (int c = 0; c < C - 1; c++) {
        quads.add(((pts[r][c].$2 + pts[r][c + 1].$2 + pts[r + 1][c + 1].$2 + pts[r + 1][c].$2) / 4, r, c));
      }
    }
    quads.sort((a, b) => a.$1.compareTo(b.$1));
    final fill = Paint()..style = PaintingStyle.fill;
    final edge = Paint()..style = PaintingStyle.stroke..color = Colors.black38..strokeWidth = 0.5;
    for (final q in quads) {
      final r = q.$2, c = q.$3;
      final p0 = pts[r][c].$1, p1 = pts[r][c + 1].$1, p2 = pts[r + 1][c + 1].$1, p3 = pts[r + 1][c].$1;
      final vavg = (bt.disp(r, c) + bt.disp(r, c + 1) + bt.disp(r + 1, c + 1) + bt.disp(r + 1, c)) / 4;
      fill.color = _heat(vavg, lo, hi);
      final path = Path()..moveTo(p0.dx, p0.dy)..lineTo(p1.dx, p1.dy)..lineTo(p2.dx, p2.dy)..lineTo(p3.dx, p3.dy)..close();
      cv.drawPath(path, fill);
      cv.drawPath(path, edge);
    }
    // หัวแกน X (คอลัมน์) และ Y (แถว) บนขอบพื้น
    void lab(String t, Offset at, Color col) {
      final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(color: col, fontSize: 9 * ui, fontWeight: FontWeight.bold, fontFamily: kPaintFont, fontFamilyFallback: kPaintFallback)), textDirection: TextDirection.ltr)..layout();
      tp.paint(cv, at - Offset(tp.width / 2, tp.height / 2));
    }
    final sx = math.max(1, (C / 6).ceil()), sr = math.max(1, (R / 6).ceil());
    for (int c = 0; c < C; c += sx) { if (c < xa.text.length) lab(xa.text[c], fp(swap ? -0.62 : 0.62, cf(c)), _kCyan); }
    for (int r = 0; r < R; r += sr) { if (r < ya.text.length) lab(ya.text[r], fp(rf(r), swap ? 0.62 : -0.62), _kYel); }
    // ค่าสูงสุด / ต่ำสุด
    final tp = TextPainter(text: TextSpan(text: 'สูงสุด ${bt.fmt(hi)}   ต่ำสุด ${bt.fmt(lo)}   ซูม ${(zoom * 100).round()}%', style: TextStyle(color: Colors.white54, fontSize: 10 * ui, fontFamily: kPaintFont, fontFamilyFallback: kPaintFallback)), textDirection: TextDirection.ltr)..layout();
    tp.paint(cv, Offset(8 * ui, 8 * ui));
    if (liveC != null) {
      final lr = liveC! ~/ C, lc = liveC! % C;
      final p = pts[lr][lc].$1;
      cv.drawCircle(p, 6 * ui, Paint()..color = Colors.white);
      cv.drawCircle(p, 6 * ui, Paint()..style = PaintingStyle.stroke..color = _kMag..strokeWidth = 2);
    }
  }
  @override
  bool shouldRepaint(_SurfPainter o) => true;
}

// ---------- ใช้ตรวจสอบความถูกต้อง (เทียบกับสคริปต์อ้างอิง) : สรุปค่าทุกพารามิเตอร์ ----------
List<String> xdfDigest(XdfDoc doc, Uint8List bin) {
  final out = <String>[];
  for (final t in doc.items) {
    if (t.isPatch || t.isInfo) continue;
    final bt = BinTable(bin, t);
    if (t.isFlag) { out.add('${t.id}|F|${bt.flag ? 1 : 0}'); continue; }
    double s = 0;
    for (int r = 0; r < t.rows; r++) { for (int c = 0; c < t.cols; c++) { s += bt.disp(r, c); } }
    final xa = _axisView(doc, bin, t.x, t.cols), ya = _axisView(doc, bin, t.y, t.rows);
    out.add('${t.id}|${t.rows}x${t.cols}|${s.toStringAsFixed(2)}|${bt.fmt(bt.disp(0, 0))}|${bt.fmt(bt.disp(t.rows - 1, t.cols - 1))}|${xa.text.first}|${xa.text.last}|${ya.text.first}|${ya.text.last}');
  }
  return out;
}
