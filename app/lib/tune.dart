// tune.dart - โหลด BIN + XDF (TunerPro XDF 1.80 XML) แก้ตารางน้ำมัน/ไฟ แบบ 2D/3D + LIVE แล้วเซฟลงคลัง
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

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
    return double.tryParse(s.substring(st, p)) ?? 0;
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

// ---------- ตาราง ----------
class XdfTable {
  final String title;
  final int address, bits, rows, cols;
  final bool signed;
  final LinMath math;
  final double tmin, tmax;
  XdfTable(this.title, this.address, this.bits, this.rows, this.cols, this.signed, this.math, this.tmin, this.tmax);
  bool get is2d => rows > 1 && cols > 1;
  bool get is1d => (rows > 1) ^ (cols > 1) || (rows > 1 && cols <= 1);
  int get count => rows * (cols <= 0 ? 1 : cols);
}

class XdfDoc {
  final List<XdfTable> tables;
  XdfDoc(this.tables);
  static XdfDoc parse(String xml) {
    final doc = XmlDocument.parse(xml);
    final out = <XdfTable>[];
    for (final t in doc.findAllElements('XDFTABLE')) {
      final title = decodeTis620(t.getElement('title')?.innerText.trim() ?? 'table');
      XmlElement? z;
      for (final ax in t.findElements('XDFAXIS')) {
        if (ax.getAttribute('id') == 'z') z = ax;
      }
      if (z == null) continue;
      final ed = z.getElement('EMBEDDEDDATA');
      if (ed == null) continue;
      final addr = _hex(ed.getAttribute('mmedaddress'));
      if (addr == null) continue;
      final bits = int.tryParse(ed.getAttribute('mmedelementsizebits') ?? '8') ?? 8;
      final rc = int.tryParse(ed.getAttribute('mmedrowcount') ?? '1') ?? 1;
      final cc = int.tryParse(ed.getAttribute('mmedcolcount') ?? '1') ?? 1;
      final eq = z.getElement('MATH')?.getAttribute('equation') ?? 'X';
      final mn = double.tryParse(z.getElement('min')?.innerText ?? '') ?? 0;
      final mx = double.tryParse(z.getElement('max')?.innerText ?? '') ?? 255;
      final signed = mn < 0;
      out.add(XdfTable(title, addr, bits, rc, cc, signed, LinMath.fromEq(eq), mn, mx));
    }
    return XdfDoc(out);
  }
  static int? _hex(String? s) {
    if (s == null) return null;
    s = s.trim();
    return s.startsWith('0x') || s.startsWith('0X') ? int.tryParse(s.substring(2), radix: 16) : int.tryParse(s);
  }
}

// ---------- อ่าน/เขียนค่าในไฟล์ BIN (16-bit = little-endian) ----------
class BinTable {
  final Uint8List bin;
  final XdfTable t;
  BinTable(this.bin, this.t);
  int get rows => t.rows;
  int get cols => t.cols <= 0 ? 1 : t.cols;
  int _rawAt(int i) {
    if (t.bits == 16) {
      final o = t.address + i * 2;
      int v = bin[o] | (bin[o + 1] << 8);
      if (t.signed && v >= 0x8000) v -= 0x10000;
      return v;
    } else {
      int v = bin[t.address + i];
      if (t.signed && v >= 0x80) v -= 0x100;
      return v;
    }
  }
  void _setRaw(int i, int v) {
    if (t.bits == 16) {
      final o = t.address + i * 2;
      bin[o] = v & 0xFF; bin[o + 1] = (v >> 8) & 0xFF;
    } else {
      bin[t.address + i] = v & 0xFF;
    }
  }
  double disp(int r, int c) => t.math.toDisp(_rawAt(r * cols + c));
  void setDisp(int r, int c, double d) => _setRaw(r * cols + c, t.math.toRaw(d, t.bits, t.signed));
  List<double> row(int r) => [for (int c = 0; c < cols; c++) disp(r, c)];
}

// ---------- หาแกน label (RPM = แถว, TPS = คอลัมน์) จากตาราง 1 มิติในไฟล์เดียวกัน ----------
List<double>? _axisLabels(XdfDoc doc, Uint8List bin, int n, List<String> keys) {
  for (final t in doc.tables) {
    final cnt = t.rows * (t.cols <= 0 ? 1 : t.cols);
    if (cnt == n && (t.rows == 1 || t.cols == 1)) {
      final up = t.title.toUpperCase();
      if (keys.any((k) => up.contains(k))) {
        final bt = BinTable(bin, t);
        return [for (int i = 0; i < n; i++) t.math.toDisp(bt._rawAt(i))];
      }
    }
  }
  return null;
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
  List<double>? rowLab, colLab;
  double? liveRpm, liveTps;
  Timer? _liveTimer;

  List<XdfTable> get tabs => widget.xdf.tables.where((t) => t.is2d).toList();
  XdfTable get t => tabs[ti];
  late BinTable bt;

  @override
  void initState() {
    super.initState();
    bin = Uint8List.fromList(widget.bin);
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
  void dispose() { _liveTimer?.cancel(); super.dispose(); }

  void _load() {
    bt = BinTable(bin, t);
    sel.clear();
    rowLab = _axisLabels(widget.xdf, bin, bt.rows, ['RPM', 'ROB', 'รอบ']);
    colLab = _axisLabels(widget.xdf, bin, bt.cols, ['TPS', 'MAP', 'โหลด', 'LOAD']);
    _fit();
  }

  void _fit() {
    double lo = 1e9, hi = -1e9;
    for (int r = 0; r < bt.rows; r++) for (int c = 0; c < bt.cols; c++) { final v = bt.disp(r, c); if (v < lo) lo = v; if (v > hi) hi = v; }
    cLo = lo; cHi = hi;
  }

  void _pushUndo() { undo.add(Uint8List.fromList(bin)); if (undo.length > 30) undo.removeAt(0); }
  void _applyUndo() { if (undo.isEmpty) return; bin = undo.removeLast(); bt = BinTable(bin, t); setState(() {}); }

  void _edit(void Function(int r, int c) f) {
    if (sel.isEmpty) return;
    _pushUndo();
    for (final k in sel) { f(k ~/ bt.cols, k % bt.cols); }
    dirty = true;
    setState(() {});
  }

  void _add(double d) => _edit((r, c) => bt.setDisp(r, c, bt.disp(r, c) + d));
  void _pct(double p) => _edit((r, c) => bt.setDisp(r, c, bt.disp(r, c) * (1 + p / 100)));

  Future<void> _setValue() async {
    final ctl = TextEditingController();
    final v = await showDialog<double>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: const Text('ตั้งค่า', style: TextStyle(color: Colors.white)),
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
    dirty = true; setState(() {});
  }

  int? _liveCell() {
    if (!live || liveRpm == null || liveTps == null || rowLab == null || colLab == null) return null;
    int nr = 0; double bd = 1e18;
    for (int i = 0; i < rowLab!.length; i++) { final d = (rowLab![i] - liveRpm!).abs(); if (d < bd) { bd = d; nr = i; } }
    int nc = 0; bd = 1e18;
    for (int i = 0; i < colLab!.length; i++) { final d = (colLab![i] - liveTps!).abs(); if (d < bd) { bd = d; nc = i; } }
    return nr * bt.cols + nc;
  }

  Future<void> _save() async {
    final base = widget.fileName.replaceAll(RegExp(r'\.bin$', caseSensitive: false), '');
    final name = '${base}_tuned.bin';
    await widget.onSave(name, Uint8List.fromList(bin));
    dirty = false;
    if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('เซฟลงคลัง: $name'))); }
  }

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) {
      return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, title: const Text('จูน')), body: const Center(child: Text('XDF นี้ไม่มีตาราง 2 มิติ', style: TextStyle(color: Colors.white70))));
    }
    final liveC = _liveCell();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          _toolbar(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(children: [
              Text('BIN: ${widget.fileName}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
              const Spacer(),
              if (liveRpm != null) Text('RPM ${liveRpm!.toStringAsFixed(0)} · TPS ${liveTps?.toStringAsFixed(1) ?? "-"}', style: const TextStyle(color: Color(0xFFB6FF1A), fontSize: 10)),
            ]),
          ),
          Expanded(child: show3d ? _surface3d(liveC) : _grid(liveC)),
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

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      color: const Color(0xFF0C0F13),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _tb(Icons.arrow_back, '', () => Navigator.pop(context), col: const Color(0xFF18D8FF)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: const Color(0xFF18D8FF)), borderRadius: BorderRadius.circular(6)),
            child: SizedBox(
              width: 170,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: ti, dropdownColor: const Color(0xFF12161C), isDense: true, isExpanded: true,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: [for (int i = 0; i < tabs.length; i++) DropdownMenuItem(value: i, child: Text(tabs[i].title, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) { if (v != null) setState(() { ti = v; _load(); }); },
                ),
              ),
            ),
          ),
          _tb(Icons.remove, '', sel.isEmpty ? null : () => _add(-_step()), col: const Color(0xFF18D8FF)),
          _tb(Icons.add, '', sel.isEmpty ? null : () => _add(_step()), col: const Color(0xFF18D8FF)),
          _tb(Icons.percent, '-', sel.isEmpty ? null : () => _pct(-2), col: const Color(0xFFFF8A1E)),
          _tb(Icons.percent, '+', sel.isEmpty ? null : () => _pct(2), col: const Color(0xFF28E070)),
          _tb(Icons.edit, 'ตั้งค่า', sel.isEmpty ? null : _setValue),
          _tb(Icons.copy, 'COPY', sel.isEmpty ? null : _copy),
          _tb(Icons.paste, 'PASTE', clip == null ? null : _paste),
          _tb(Icons.undo, '', undo.isEmpty ? null : _applyUndo),
          _tb(Icons.straighten, 'FIT', () => setState(_fit)),
          _tb(show3d ? Icons.grid_on : Icons.view_in_ar, show3d ? '2D' : '3D', () => setState(() => show3d = !show3d), col: const Color(0xFFE040FB), on: show3d),
          _tb(Icons.circle, 'LIVE', () => setState(() => live = !live), col: const Color(0xFFB6FF1A), on: live),
          _tb(Icons.save, 'เซฟ', _save, col: dirty ? const Color(0xFF28E070) : Colors.white, on: dirty),
        ]),
      ),
    );
  }

  double _step() {
    // ก้าวปรับตามความละเอียดของตาราง
    final span = (cHi - cLo).abs();
    if (span > 1000) return 10;
    if (span > 100) return 1;
    if (span > 10) return 0.1;
    return 0.1;
  }

  Widget _grid(int? liveC) {
    const cw = 50.0, ch = 26.0, hw = 46.0;
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // header row (TPS)
          Row(children: [
            Container(width: hw, height: ch, alignment: Alignment.center, color: const Color(0xFF12161C), child: Text('${bt.rows}x${bt.cols}', style: const TextStyle(color: Colors.white38, fontSize: 9))),
            for (int c = 0; c < bt.cols; c++)
              Container(width: cw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                child: Text(colLab != null ? colLab![c].toStringAsFixed(colLab![c] < 100 ? 1 : 0) : '$c', style: const TextStyle(color: Color(0xFF18D8FF), fontSize: 9, fontWeight: FontWeight.bold))),
          ]),
          for (int r = 0; r < bt.rows; r++)
            Row(children: [
              Container(width: hw, height: ch, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF12161C), border: Border.all(color: Colors.white10, width: 0.3)),
                child: Text(rowLab != null ? rowLab![r].toStringAsFixed(0) : '$r', style: const TextStyle(color: Color(0xFFFFE01A), fontSize: 9, fontWeight: FontWeight.bold))),
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
        child: Text(v.toStringAsFixed(v.abs() < 100 ? 1 : 0), style: TextStyle(color: Colors.black.withOpacity(0.85), fontSize: 9.5, fontWeight: isLive ? FontWeight.w900 : FontWeight.w600)),
      ),
    );
  }

  Widget _surface3d(int? liveC) {
    return GestureDetector(
      onPanUpdate: (d) => setState(() { _yaw += d.delta.dx * 0.01; _pitch = (_pitch - d.delta.dy * 0.01).clamp(0.1, 1.4); }),
      child: CustomPaint(painter: _SurfPainter(bt, cLo, cHi, _yaw, _pitch, liveC), size: Size.infinite),
    );
  }
  double _yaw = -0.6, _pitch = 0.9;
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
