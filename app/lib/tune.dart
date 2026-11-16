// tune.dart - โหลด BIN + XDF (TunerPro XDF 1.80 XML) แสดง/แก้ทุกพารามิเตอร์ (ตาราง 2D/1D/ค่าเดียว/FLAG) เหมือน TunerPro + LIVE แล้วเซฟลงคลัง
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';

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
// majorstridebits > 0 = ระยะห่างระหว่างช่อง (บิต) — ตรวจกับไฟล์จริงแล้วตรงกับ TunerPro
enum AxKind { none, rpm, tps }

class XdfAxis {
  final int count;
  final List<String> labels; // LABEL แบบคงที่
  final String? link;        // linkobjid → ใช้ค่าจากตารางนั้นเป็นหัวแกน
  final int? address;        // แกนที่ฝังใน BIN เอง
  final int bits;
  final bool lsb, signed;
  final LinMath math;
  final int dp;
  const XdfAxis(this.count, this.labels, this.link, this.address, this.bits, this.lsb, this.signed, this.math, this.dp);
}

class XdfTable {
  final String id, title;
  final bool isFlag;
  final int address, bits, rows, cols, dp, mask;
  final int elemStride, rowStride; // ไบต์
  final bool signed, lsb, colMajor;
  final LinMath math;
  final double tmin, tmax;
  final XdfAxis? x, y;
  XdfTable({
    required this.id, required this.title, required this.isFlag, required this.address, required this.bits,
    this.rows = 1, this.cols = 1, this.dp = 0, this.mask = 0, this.elemStride = 1, this.rowStride = 0,
    this.signed = false, this.lsb = true, this.colMajor = false, this.math = const LinMath(1, 0),
    this.tmin = 0, this.tmax = 255, this.x, this.y,
  });
  bool get is2d => !isFlag && rows > 1 && cols > 1;
  bool get isConst => !isFlag && rows * cols == 1;
  bool get is1d => !isFlag && !is2d && !isConst;
  int get count => rows * cols;
  String get kindLabel => isFlag ? 'FLAG' : (isConst ? 'ค่าเดียว' : '${rows}x$cols');
}

// แปลง XML entity (&#NNN; &#xHH; &amp; ฯลฯ) เป็นอักขระ — ใช้ก่อนถอด TIS-620
String _entities(String s) {
  s = s.replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)));
  return s.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'");
}

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
  XdfDoc(this.items) : byId = {for (final t in items) t.id.toLowerCase(): t};
  List<XdfTable> get tables => items.where((t) => !t.isFlag).toList();

  static XdfDoc parse(String xml) {
    // ค่าเริ่มต้นจาก <DEFAULTS>
    final dm = RegExp(r'<DEFAULTS([^>]*)>').firstMatch(xml)?.group(1) ?? '';
    final defLsb = (_attr(dm, 'lsbfirst') ?? '0') == '1';
    final defSigned = (_attr(dm, 'signed') ?? '0') == '1';
    final defBits = int.tryParse(_attr(dm, 'datasizeinbits') ?? '8') ?? 8;

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
      final link = RegExp(r'<embedinfo[^>]*linkobjid="([^"]*)"').firstMatch(a)?.group(1);
      final labs = <int, String>{};
      for (final m in RegExp(r'<LABEL\s+index="(\d+)"\s+value="([^"]*)"').allMatches(a)) {
        labs[int.parse(m[1]!)] = decodeTis620(_entities(m[2]!));
      }
      final n = cnt > 0 ? cnt : (labs.isEmpty ? 1 : labs.keys.reduce((p, q) => p > q ? p : q) + 1);
      final tf = _hex(_attr(ed, 'mmedtypeflags'));
      return XdfAxis(
        n, [for (int i = 0; i < n; i++) labs[i] ?? ''], link, _hex(_attr(ed, 'mmedaddress')),
        (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? defBits).abs(),
        tf == null ? defLsb : (tf & 2) != 0, tf == null ? defSigned : (tf & 1) != 0,
        LinMath.fromEq(_attr(a, 'equation') ?? 'X'),
        int.tryParse(RegExp(r'<decimalpl>(-?\d+)').firstMatch(a)?.group(1) ?? '') ?? 2,
      );
    }

    final out = <XdfTable>[];
    for (final m in RegExp(r'<(XDFTABLE|XDFFLAG)\b[\s\S]*?</\1>').allMatches(xml)) {
      final t = m.group(0)!;
      final kind = m.group(1)!;
      final id = _attr(t.substring(0, t.indexOf('>') + 1), 'uniqueid') ?? 'n${out.length}';
      if (kind == 'XDFFLAG') {
        final ed = RegExp(r'<EMBEDDEDDATA([^>]*)>').firstMatch(t)?.group(1) ?? '';
        final addr = _hex(_attr(ed, 'mmedaddress'));
        if (addr == null) continue;
        final tf = _hex(_attr(ed, 'mmedtypeflags'));
        final bits = (int.tryParse(_attr(ed, 'mmedelementsizebits') ?? '') ?? 8).abs();
        out.add(XdfTable(
          id: id, title: title(t), isFlag: true, address: addr, bits: bits,
          mask: _hex(RegExp(r'<mask>([^<]*)</mask>').firstMatch(t)?.group(1)) ?? 1,
          lsb: tf == null ? defLsb : (tf & 2) != 0, elemStride: math.max(1, bits ~/ 8),
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
      final mn = double.tryParse(RegExp(r'<min>([^<]*)</min>').firstMatch(z)?.group(1) ?? '') ?? 0;
      final mx = double.tryParse(RegExp(r'<max>([^<]*)</max>').firstMatch(z)?.group(1) ?? '') ?? 255;
      out.add(XdfTable(
        id: id, title: title(t), isFlag: false, address: addr, bits: bits, rows: rc, cols: cc,
        dp: int.tryParse(RegExp(r'<decimalpl>(-?\d+)').firstMatch(z)?.group(1) ?? '') ?? 2,
        elemStride: es, rowStride: minor > 0 ? math.max(1, minor ~/ 8) : 0,
        signed: tf == null ? defSigned : (tf & 1) != 0,
        lsb: tf == null ? defLsb : (tf & 2) != 0,
        colMajor: tf != null && (tf & 4) != 0,
        math: LinMath.fromEq(_attr(z, 'equation') ?? 'X'), tmin: mn, tmax: mx,
        x: axis(t, 'x'), y: axis(t, 'y'),
      ));
    }
    return XdfDoc(out);
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
    if (t.rowStride > 0) return t.address + r * t.rowStride + c * t.elemStride;
    final lin = t.colMajor ? c * t.rows + r : r * t.cols + c;
    return t.address + lin * t.elemStride;
  }
  int raw(int r, int c) => _readRaw(bin, _off(r, c), t.bits, t.lsb, t.signed);
  double disp(int r, int c) => t.math.toDisp(raw(r, c));
  void setDisp(int r, int c, double d) => _writeRaw(bin, _off(r, c), t.bits, t.lsb, t.math.toRaw(d, t.bits, t.signed));
  String fmt(double v) => v.toStringAsFixed(t.dp.clamp(0, 6));
  // ค่าทั้งหมดเรียงตามลำดับ (ใช้เป็นหัวแกนของตารางอื่น)
  List<double> flat() => [for (int i = 0; i < t.count; i++) disp(t.cols == 1 ? i : i ~/ t.cols, t.cols == 1 ? 0 : i % t.cols)];
  // FLAG
  bool get flag => (_readRaw(bin, t.address, t.bits, t.lsb, false) & t.mask) != 0;
  set flag(bool on) {
    final v = _readRaw(bin, t.address, t.bits, t.lsb, false);
    _writeRaw(bin, t.address, t.bits, t.lsb, on ? (v | t.mask) : (v & ~t.mask));
  }
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
      return AxisView(
        [for (int i = 0; i < n; i++) i < v.length ? bt.fmt(v[i]) : '$i'],
        [for (int i = 0; i < n; i++) i < v.length ? v[i] : null],
        _kindOf(lt.title),
      );
    }
  }
  if (a != null && a.address != null) {
    final st = math.max(1, a.bits ~/ 8);
    final v = [for (int i = 0; i < n; i++) a.math.toDisp(_readRaw(bin, a.address! + i * st, a.bits, a.lsb, a.signed))];
    return AxisView([for (final x in v) x.toStringAsFixed(a.dp.clamp(0, 6))], v, AxKind.none);
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

  List<XdfTable> get items => widget.xdf.items;
  XdfTable get t => items[ti];
  late BinTable bt;

  @override
  void initState() {
    super.initState();
    bin = Uint8List.fromList(widget.bin);
    // เปิดตารางน้ำมันหลักก่อน (ตาราง 2 มิติตัวแรก) เหมือนที่ใช้บ่อยสุด
    final first2d = items.indexWhere((e) => e.is2d);
    ti = first2d < 0 ? 0 : first2d;
    _load();
    _liveTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final before = _liveCell();
      liveRpm = widget.getRpm?.call();
      liveTps = widget.getTps?.call();
      if (_liveCell() != before) setState(() {});
    });
  }

  @override
  void dispose() { _liveTimer?.cancel(); _valCtl.dispose(); super.dispose(); }

  void _load() {
    bt = BinTable(bin, t);
    sel.clear();
    xa = _axisView(widget.xdf, bin, t.x, t.cols);
    ya = _axisView(widget.xdf, bin, t.y, t.rows);
    if (t.isConst) sel.add(0);
    if (!t.is2d && !t.is1d) show3d = false;
    _fit();
  }

  void _fit() {
    if (t.isFlag) return;
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
    setState(() {});
  }

  void _afterEdit() {
    dirty = true;
    // ตารางที่เป็นหัวแกนอาจถูกแก้ → อัปเดตหัวแกน
    xa = _axisView(widget.xdf, bin, t.x, t.cols);
    ya = _axisView(widget.xdf, bin, t.y, t.rows);
    setState(() {});
  }

  void _edit(void Function(int r, int c) f) {
    if (sel.isEmpty || t.isFlag) return;
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
        content: TextField(controller: ctl, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), autofocus: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'ค่าใหม่')),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('ยกเลิก')), TextButton(onPressed: () => Navigator.pop(d, double.tryParse(ctl.text)), child: const Text('ตั้งค่า'))],
      ),
    );
    if (v != null) _edit((r, c) => bt.setDisp(r, c, v));
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
    if (!live || t.isFlag || t.isConst) return null;
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

  IconData _icon(XdfTable e) => e.isFlag ? Icons.check_box_outlined : (e.is2d ? Icons.grid_on : (e.isConst ? Icons.looks_one_outlined : Icons.view_week_outlined));

  // รายการพารามิเตอร์ทั้งหมด (เหมือน Parameter Tree ของ TunerPro)
  Future<void> _pickParam() async {
    final i = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF0C0F13),
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(children: [
                const Icon(Icons.account_tree_outlined, color: Color(0xFF18D8FF), size: 18),
                const SizedBox(width: 8),
                Text('พารามิเตอร์ทั้งหมด (${items.length})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('ตาราง ${items.where((e) => !e.isFlag).length} · FLAG ${items.where((e) => e.isFlag).length}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final e = items[i];
                final cur = i == ti;
                return ListTile(
                  dense: true,
                  selected: cur,
                  selectedTileColor: const Color(0xFF18D8FF).withOpacity(0.12),
                  leading: Icon(_icon(e), size: 18, color: e.isFlag ? const Color(0xFFFFE01A) : (e.is2d ? const Color(0xFF18D8FF) : const Color(0xFF28E070))),
                  title: Text(e.title, style: TextStyle(color: cur ? const Color(0xFF18D8FF) : Colors.white, fontSize: 13)),
                  subtitle: Text('${e.kindLabel} · 0x${e.address.toRadixString(16).toUpperCase()}${e.isFlag ? ' · mask 0x${e.mask.toRadixString(16).toUpperCase()}' : ''}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  trailing: e.isFlag
                      ? Switch(value: BinTable(bin, e).flag, activeColor: const Color(0xFFFFE01A), onChanged: (v) { _toggleFlag(e, v); setS(() {}); })
                      : null,
                  onTap: () => Navigator.pop(ctx, i),
                );
              },
            )),
          ]),
        ),
      )),
    );
    if (i != null) _go(i);
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, title: const Text('จูน')), body: const Center(child: Text('XDF นี้ไม่มีพารามิเตอร์', style: TextStyle(color: Colors.white70))));
    }
    final liveC = _liveCell();
    Widget body;
    if (t.isFlag) {
      body = _flagView();
    } else if (t.isConst) {
      body = _constView();
    } else if (show3d) {
      body = t.is2d ? _surface3d(liveC) : _line1d(liveC);
    } else {
      body = _grid(liveC);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          _titleBar(),
          if (!t.isFlag) _toolbar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(children: [
              Expanded(child: Text(
                t.isFlag
                    ? 'FLAG · 0x${t.address.toRadixString(16).toUpperCase()} · mask 0x${t.mask.toRadixString(16).toUpperCase()}'
                    : '${t.kindLabel} · ${t.bits}bit · 0x${t.address.toRadixString(16).toUpperCase()} · ${widget.fileName}',
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 10))),
              if (liveRpm != null) Text('RPM ${liveRpm!.toStringAsFixed(0)} · TPS ${liveTps?.toStringAsFixed(1) ?? "-"}', style: const TextStyle(color: Color(0xFFB6FF1A), fontSize: 10)),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
    );
  }

  Widget _tb(IconData ic, String lab, VoidCallback? f, {Color col = Colors.white, bool on = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: on ? col.withOpacity(0.25) : Colors.black45, border: Border.all(color: f == null ? Colors.white12 : col.withOpacity(on ? 1 : 0.5)), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(ic, size: 14, color: f == null ? Colors.white24 : col), if (lab.isNotEmpty) ...[const SizedBox(width: 4), Text(lab, style: TextStyle(color: f == null ? Colors.white24 : col, fontSize: 11, fontWeight: FontWeight.bold))]]),
          ),
        ),
      );

  // แถวบน: ย้อนกลับ · ชื่อพารามิเตอร์ (กดเพื่อเลือกจากรายการทั้งหมด) · ก่อนหน้า/ถัดไป · เซฟ
  Widget _titleBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
      color: const Color(0xFF0C0F13),
      child: Row(children: [
        _tb(Icons.arrow_back, '', () => Navigator.pop(context), col: const Color(0xFF18D8FF)),
        Expanded(
          child: InkWell(
            onTap: _pickParam,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: const Color(0xFF18D8FF)), borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                Icon(_icon(t), size: 14, color: const Color(0xFF18D8FF)),
                const SizedBox(width: 6),
                Expanded(child: Text(t.title, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                Text('${ti + 1}/${items.length}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                const Icon(Icons.arrow_drop_down, color: Color(0xFF18D8FF), size: 18),
              ]),
            ),
          ),
        ),
        _tb(Icons.chevron_left, '', ti > 0 ? () => _go(ti - 1) : null, col: const Color(0xFF18D8FF)),
        _tb(Icons.chevron_right, '', ti < items.length - 1 ? () => _go(ti + 1) : null, col: const Color(0xFF18D8FF)),
        _tb(Icons.save, 'เซฟ', _save, col: dirty ? const Color(0xFF28E070) : Colors.white, on: dirty),
      ]),
    );
  }

  Widget _toolbar() {
    final can = sel.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      color: const Color(0xFF0C0F13),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          // ช่องค่า (ใช้กับ +/- และ % เหมือน TunerPro)
          Container(
            width: 56, height: 30, margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: const Color(0xFFFFE01A)), borderRadius: BorderRadius.circular(6)),
            child: Center(child: TextField(
              controller: _valCtl, textAlign: TextAlign.center,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'ค่า', contentPadding: EdgeInsets.zero),
            )),
          ),
          _tb(Icons.remove, '', can ? () => _add(-_val) : null, col: const Color(0xFF18D8FF)),
          _tb(Icons.add, '', can ? () => _add(_val) : null, col: const Color(0xFF18D8FF)),
          _tb(Icons.percent, '-', can ? () => _pct(-_val) : null, col: const Color(0xFFFF8A1E)),
          _tb(Icons.percent, '+', can ? () => _pct(_val) : null, col: const Color(0xFF28E070)),
          _tb(Icons.edit, 'ตั้งค่า', can ? _setValue : null),
          if (!t.isConst) ...[
            _tb(Icons.select_all, 'ทั้งหมด', () => setState(() { sel..clear()..addAll([for (int i = 0; i < t.count; i++) i]); })),
            _tb(Icons.copy, 'COPY', can ? _copy : null),
            _tb(Icons.paste, 'PASTE', clip == null || !can ? null : _paste),
          ],
          _tb(Icons.undo, '', undo.isEmpty ? null : _applyUndo),
          if (!t.isConst) ...[
            _tb(Icons.straighten, 'FIT', () => setState(_fit)),
            _tb(show3d ? Icons.grid_on : (t.is2d ? Icons.view_in_ar : Icons.show_chart), show3d ? 'ตาราง' : (t.is2d ? '3D' : 'กราฟ'), () => setState(() => show3d = !show3d), col: const Color(0xFFE040FB), on: show3d),
            _tb(Icons.circle, 'LIVE', () => setState(() => live = !live), col: const Color(0xFFB6FF1A), on: live),
          ],
        ]),
      ),
    );
  }

  double _textW(String s, double perChar) => s.length * perChar + 10;

  Widget _grid(int? liveC) {
    // ความกว้างช่องปรับตามความยาวตัวเลข/หัวแกน
    double cw = 44;
    for (int r = 0; r < bt.rows; r++) for (int c = 0; c < bt.cols; c++) { cw = math.max(cw, _textW(bt.fmt(bt.disp(r, c)), 6.2)); }
    for (final s in xa.text) { cw = math.max(cw, _textW(s, 6.0)); }
    cw = math.min(cw, 96);
    double hw = 40;
    for (final s in ya.text) { hw = math.max(hw, _textW(s, 6.0)); }
    hw = math.min(hw, 110);
    const ch = 26.0;
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // หัวคอลัมน์ (แกน X)
          Row(children: [
            Container(width: hw, height: ch, alignment: Alignment.center, color: const Color(0xFF12161C), child: Text('${bt.rows}x${bt.cols}', style: const TextStyle(color: Colors.white38, fontSize: 9))),
            for (int c = 0; c < bt.cols; c++)
              GestureDetector(
                onTap: () => setState(() { final col = [for (int r = 0; r < bt.rows; r++) r * bt.cols + c]; if (col.every(sel.contains)) { sel.removeAll(col); } else { sel.addAll(col); } }),
                child: Container(width: cw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                  child: Text(xa.text[c], maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(color: Color(0xFF18D8FF), fontSize: 9, fontWeight: FontWeight.bold))),
              ),
          ]),
          for (int r = 0; r < bt.rows; r++)
            Row(children: [
              GestureDetector(
                onTap: () => setState(() { final row = [for (int c = 0; c < bt.cols; c++) r * bt.cols + c]; if (row.every(sel.contains)) { sel.removeAll(row); } else { sel.addAll(row); } }),
                child: Container(width: hw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                  child: Text(ya.text[r], maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(color: Color(0xFFFFE01A), fontSize: 9, fontWeight: FontWeight.bold))),
              ),
              for (int c = 0; c < bt.cols; c++) _cell(r, c, cw, ch, liveC),
            ]),
        ]),
      ),
    );
  }

  Widget _cell(int r, int c, double w, double h, int? liveC) {
    final k = r * bt.cols + c;
    final v = bt.disp(r, c);
    final selected = sel.contains(k);
    final isLive = liveC == k;
    return GestureDetector(
      onTap: () => setState(() { if (selected) sel.remove(k); else sel.add(k); }),
      onLongPress: () => setState(() { sel..clear()..add(k); }),
      child: Container(
        width: w, height: h, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _heat(v, cLo, cHi),
          border: Border.all(color: isLive ? Colors.white : (selected ? const Color(0xFFE040FB) : Colors.black26), width: isLive ? 2 : (selected ? 2 : 0.3)),
        ),
        child: Text(bt.fmt(v), style: TextStyle(color: Colors.black.withOpacity(0.85), fontSize: 9.5, fontWeight: isLive ? FontWeight.w900 : FontWeight.w600)),
      ),
    );
  }

  Widget _constView() {
    final v = bt.disp(0, 0);
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: const Color(0xFF28E070)), borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _setValue,
            child: Text(bt.fmt(v), style: const TextStyle(color: Color(0xFF28E070), fontSize: 48, fontWeight: FontWeight.w900)),
          ),
          const SizedBox(height: 6),
          Text('ดิบ ${bt.raw(0, 0)} · แตะตัวเลขเพื่อพิมพ์ค่า', style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 16),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _tb(Icons.remove, _valCtl.text, () => _add(-_val), col: const Color(0xFF18D8FF)),
            const SizedBox(width: 12),
            _tb(Icons.add, _valCtl.text, () => _add(_val), col: const Color(0xFF18D8FF)),
          ]),
        ]),
      ),
    );
  }

  Widget _flagView() {
    final on = bt.flag;
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: const Color(0xFFFFE01A)), borderRadius: BorderRadius.circular(14)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Transform.scale(scale: 1.6, child: Switch(value: on, activeColor: const Color(0xFFFFE01A), onChanged: (v) => _toggleFlag(t, v))),
          const SizedBox(height: 10),
          Text(on ? 'เปิด (ติ๊ก)' : 'ปิด (ไม่ติ๊ก)', style: TextStyle(color: on ? const Color(0xFFFFE01A) : Colors.white54, fontSize: 14, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _line1d(int? liveC) => CustomPaint(painter: _LinePainter(bt, cLo, cHi, t.rows == 1 ? xa.text : ya.text, liveC), size: Size.infinite);

  Widget _surface3d(int? liveC) {
    return GestureDetector(
      onPanUpdate: (d) => setState(() { _yaw += d.delta.dx * 0.01; _pitch = (_pitch - d.delta.dy * 0.01).clamp(0.1, 1.4); }),
      child: CustomPaint(painter: _SurfPainter(bt, cLo, cHi, _yaw, _pitch, liveC), size: Size.infinite),
    );
  }
  double _yaw = -0.6, _pitch = 0.9;
}

// กราฟเส้นสำหรับตาราง 1 มิติ
class _LinePainter extends CustomPainter {
  final BinTable bt;
  final double lo, hi;
  final List<String> labels;
  final int? liveC;
  _LinePainter(this.bt, this.lo, this.hi, this.labels, this.liveC);
  @override
  void paint(Canvas cv, Size s) {
    final n = bt.t.count;
    if (n < 2) return;
    double v(int i) => bt.rows == 1 ? bt.disp(0, i) : bt.disp(i, 0);
    const l = 44.0, r = 12.0, top = 16.0, bot = 30.0;
    final w = s.width - l - r, h = s.height - top - bot;
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : (hi - lo);
    Offset p(int i) => Offset(l + w * i / (n - 1), top + h * (1 - (v(i) - lo) / span));
    final grid = Paint()..color = Colors.white10..strokeWidth = 1;
    for (int k = 0; k <= 4; k++) {
      final y = top + h * k / 4;
      cv.drawLine(Offset(l, y), Offset(l + w, y), grid);
      final tp = TextPainter(text: TextSpan(text: bt.fmt(hi - span * k / 4), style: const TextStyle(color: Colors.white38, fontSize: 9)), textDirection: TextDirection.ltr)..layout();
      tp.paint(cv, Offset(l - tp.width - 4, y - tp.height / 2));
    }
    final path = Path()..moveTo(p(0).dx, p(0).dy);
    for (int i = 1; i < n; i++) { path.lineTo(p(i).dx, p(i).dy); }
    cv.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2..color = const Color(0xFF18D8FF));
    final step = math.max(1, (n / 8).ceil());
    for (int i = 0; i < n; i++) {
      cv.drawCircle(p(i), 3, Paint()..color = _heat(v(i), lo, hi));
      if (i % step == 0 && i < labels.length) {
        final tp = TextPainter(text: TextSpan(text: labels[i], style: const TextStyle(color: Color(0xFF18D8FF), fontSize: 9)), textDirection: TextDirection.ltr)..layout();
        tp.paint(cv, Offset(p(i).dx - tp.width / 2, top + h + 8));
      }
    }
    if (liveC != null && liveC! < n) {
      cv.drawCircle(p(liveC!), 7, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.white);
    }
  }
  @override
  bool shouldRepaint(_LinePainter o) => true;
}

class _SurfPainter extends CustomPainter {
  final BinTable bt;
  final double lo, hi, yaw, pitch;
  final int? liveC;
  _SurfPainter(this.bt, this.lo, this.hi, this.yaw, this.pitch, this.liveC);
  @override
  void paint(Canvas cv, Size s) {
    final R = bt.rows, C = bt.cols;
    final cx = s.width / 2, cy = s.height * 0.62;
    final scale = math.min(s.width, s.height) * 0.9;
    final zr = (hi - lo).abs() < 1e-6 ? 1 : (hi - lo);
    Offset pt(int r, int c) {
      final x = (c / (C - 1) - 0.5), y = (r / (R - 1) - 0.5);
      final z = ((bt.disp(r, c) - lo) / zr - 0.5);
      final rx = x * math.cos(yaw) - y * math.sin(yaw);
      final ry = x * math.sin(yaw) + y * math.cos(yaw);
      final sy = ry * math.cos(pitch) - z * 0.6 * math.sin(pitch);
      final depth = ry * math.sin(pitch) + z * 0.6 * math.cos(pitch);
      final f = 1.0 / (1.6 - depth * 0.4);
      return Offset(cx + rx * scale * f, cy + sy * scale * f);
    }
    final fill = Paint()..style = PaintingStyle.fill;
    for (int r = 0; r < R - 1; r++) {
      for (int c = 0; c < C - 1; c++) {
        final p0 = pt(r, c), p1 = pt(r, c + 1), p2 = pt(r + 1, c + 1), p3 = pt(r + 1, c);
        final vavg = (bt.disp(r, c) + bt.disp(r, c + 1) + bt.disp(r + 1, c + 1) + bt.disp(r + 1, c)) / 4;
        fill.color = _heat(vavg, lo, hi).withOpacity(0.92);
        cv.drawPath(Path()..moveTo(p0.dx, p0.dy)..lineTo(p1.dx, p1.dy)..lineTo(p2.dx, p2.dy)..lineTo(p3.dx, p3.dy)..close(), fill);
        cv.drawPath(Path()..moveTo(p0.dx, p0.dy)..lineTo(p1.dx, p1.dy)..lineTo(p2.dx, p2.dy)..lineTo(p3.dx, p3.dy)..close(), Paint()..style = PaintingStyle.stroke..color = Colors.black26..strokeWidth = 0.4);
      }
    }
    if (liveC != null) {
      final lr = liveC! ~/ C, lc = liveC! % C;
      final p = pt(lr, lc);
      cv.drawCircle(p, 6, Paint()..color = Colors.white);
      cv.drawCircle(p, 6, Paint()..style = PaintingStyle.stroke..color = const Color(0xFFE040FB)..strokeWidth = 2);
    }
  }
  @override
  bool shouldRepaint(_SurfPainter o) => true;
}
