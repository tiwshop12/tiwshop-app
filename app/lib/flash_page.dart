part of 'main.dart';

// ===================== หน้า FLASH ECU (คลังจูนในแอพ + ไฟล์ของฉัน + ส่งไปเกจ + เขียนกล่อง + จูน) =====================
// ซ้าย: สถานะกล่อง/เกจ และขั้นตอนเขียน 1-2-3   ขวา: แท็บ คลังจูน / ไฟล์ของฉัน / XDF

// ไฟล์ที่เลือกไว้สำหรับส่งไปเกจ
class _FlashSel {
  final String name, src; // src: 'คลังจูน' / 'ไฟล์ของฉัน'
  final int size;
  final Future<Uint8List> Function() load;
  final String key; // ใช้ไฮไลต์แถวที่เลือก
  const _FlashSel(this.name, this.src, this.size, this.load, this.key);
}

class FlashPage extends StatefulWidget {
  final GaugeController c;
  const FlashPage({super.key, required this.c});
  @override
  State<FlashPage> createState() => _FlashPageState();
}

class _FlashPageState extends State<FlashPage> {
  List<io.File> files = [], xdfs = [];
  List<Map<String, dynamic>> lib = [];
  bool loading = true, sending = false;
  double? sendProg;
  String? sentName; // ไฟล์ที่ส่งไปเกจสำเร็จล่าสุด
  int vendor = 0; // 0 อัตโนมัติ, 1 Keihin, 2 Shindengen
  String? msg;
  bool msgErr = false;
  int tab = 0; // 0 คลังจูน, 1 ไฟล์ของฉัน, 2 XDF
  String q = '', fam = 'ทั้งหมด';
  _FlashSel? sel;
  final _qCtl = TextEditingController();

  GaugeController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final l = await c.listBins();
    final x = await c.listXdfs();
    if (lib.isEmpty) {
      try {
        final j = jsonDecode(await rootBundle.loadString('assets/tunelib/index.json')) as List;
        lib = j.cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() { files = l; xdfs = x; loading = false; });
  }

  void _say(String s, {bool err = false}) => setState(() { msg = s; msgErr = err; });

  // ---------------- คลังจูน ----------------
  static String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  bool _isEcu(Map<String, dynamic> e) {
    final id = c.t.ecmId?.toUpperCase();
    final ecm = (e['ecm'] as String? ?? '').toUpperCase();
    if (id != null && ecm.isNotEmpty && id == ecm) return true;
    final p = c.t.ecu?.part;
    return p != null && _norm(p).contains(_norm(e['part'] as String));
  }

  List<String> get _fams {
    final s = <String>[];
    for (final e in lib) { final f = e['family'] as String; if (!s.contains(f)) s.add(f); }
    s.sort();
    final o = s.remove('อื่นๆ');
    if (o) s.add('อื่นๆ');
    return ['ทั้งหมด', ...s];
  }

  List<Map<String, dynamic>> get _libView {
    final qq = _norm(q);
    final l = lib.where((e) {
      if (fam != 'ทั้งหมด' && e['family'] != fam) return false;
      if (qq.isEmpty) return true;
      return _norm('${e['part']} ${e['family']} ${e['title']} ${e['ecm']}').contains(qq);
    }).toList();
    l.sort((a, b) {
      final ma = _isEcu(a) ? 0 : 1, mb = _isEcu(b) ? 0 : 1;
      if (ma != mb) return ma - mb;
      final f = (a['family'] as String).compareTo(b['family'] as String);
      return f != 0 ? f : (a['part'] as String).compareTo(b['part'] as String);
    });
    return l;
  }

  Future<Uint8List> _asset(String f) async => (await rootBundle.load('assets/tunelib/$f')).buffer.asUint8List();

  Future<Map<String, dynamic>?> _pickLibBin(Map<String, dynamic> e) async {
    final bins = (e['bins'] as List).cast<Map<String, dynamic>>();
    if (bins.length == 1) return bins.first;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: const Color(0xFF0E1116),
      builder: (sctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        Padding(padding: const EdgeInsets.all(14), child: Text('เลือกไฟล์ BIN · ${e['part']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
        for (final b in bins)
          ListTile(
            leading: const Icon(Icons.memory, color: kAmber),
            title: Text(b['name'] as String, style: const TextStyle(color: Colors.white, fontSize: 13)),
            onTap: () => Navigator.pop(sctx, b),
          ),
      ])),
    );
  }

  Future<void> _libSelect(Map<String, dynamic> e) async {
    final b = await _pickLibBin(e);
    if (b == null) return;
    final f = b['file'] as String;
    final bytes = await _asset(f);
    setState(() {
      sel = _FlashSel(b['name'] as String, 'คลังจูน · ${e['part']}', bytes.length, () async => bytes, 'lib:$f');
      msg = null;
    });
  }

  Future<void> _libTune(Map<String, dynamic> e) async {
    try {
      if ((e['xdf'] as String).isEmpty) { _say('รุ่นนี้ไม่มี XDF ที่เปิดได้ (ไฟล์ XDF เข้ารหัส) — ใช้ส่งไปเขียนกล่องได้อย่างเดียว', err: true); return; }
      final b = await _pickLibBin(e);
      if (b == null) return;
      await _openTune(b['name'] as String, await _asset(b['file'] as String), await _asset(e['xdf'] as String));
    } catch (err) {
      _say('เปิดไฟล์จากคลังจูนไม่สำเร็จ: $err', err: true);
    }
  }

  Future<void> _libCopy(Map<String, dynamic> e) async {
    try {
      final b = await _pickLibBin(e);
      if (b == null) return;
      await c.importBinBytes(b['name'] as String, await _asset(b['file'] as String));
      if ((e['xdf'] as String).isNotEmpty) {
        await c.importXdfBytes('${e['part']} ${e['family']}.xdf', await _asset(e['xdf'] as String));
      }
      _say('เพิ่ม ${b['name']} เข้า "ไฟล์ของฉัน" แล้ว');
      await _load();
    } catch (err) {
      _say('เพิ่มเข้าคลังไม่สำเร็จ: $err', err: true);
    }
  }

  // ---------------- ไฟล์ของฉัน ----------------
  Future<Uint8List?> _bytesOf(PlatformFile f) async {
    if (f.bytes != null) return f.bytes;
    if (f.path != null) {
      final ff = io.File(f.path!);
      if (await ff.exists()) return ff.readAsBytes();
    }
    return null;
  }

  bool _looksXdf(Uint8List b) {
    final head = String.fromCharCodes(b.take(4000));
    return head.contains('XDFFORMAT') || head.contains('XDFTABLE') || head.contains('XDFHEADER');
  }

  Future<void> _import() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true, allowMultiple: true);
      if (res == null || res.files.isEmpty) return;
      int nb = 0, nx = 0;
      final bad = <String>[];
      for (final f in res.files) {
        final bytes = await _bytesOf(f);
        if (bytes == null) { bad.add('${f.name} (อ่านไม่ได้)'); continue; }
        final isXdf = f.name.toLowerCase().trim().endsWith('.xdf') || _looksXdf(bytes);
        if (isXdf) {
          if (!_looksXdf(bytes)) { bad.add('${f.name} (XDF เข้ารหัส)'); continue; }
          await c.importXdfBytes(f.name, bytes); nx++;
        } else if (f.name.toLowerCase().endsWith('.rar') || f.name.toLowerCase().endsWith('.zip')) {
          bad.add('${f.name} (ต้องแตกไฟล์ก่อน)');
        } else {
          if (bytes.length < 1024 || bytes.length > 1100000) { bad.add('${f.name} (ขนาดไม่ใช่ไฟล์ ECU)'); continue; }
          await c.importBinBytes(f.name, bytes); nb++;
        }
      }
      _say('นำเข้า BIN $nb ไฟล์, XDF $nx ไฟล์${bad.isEmpty ? '' : '\nข้าม: ${bad.join(', ')}'}', err: bad.isNotEmpty && nb + nx == 0);
      setState(() => tab = nx > 0 && nb == 0 ? 2 : 1);
      await _load();
    } catch (e) {
      _say('นำเข้าไฟล์ไม่สำเร็จ: $e', err: true);
    }
  }

  Future<void> _delete(io.File f) async {
    final name = f.path.split('/').last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: const Text('ลบไฟล์?', style: TextStyle(color: Colors.white)),
        content: Text(name, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('ลบ', style: TextStyle(color: kBad))),
        ],
      ),
    );
    if (ok != true) return;
    await c.deleteBinFile(f);
    if (sel?.key == 'file:${f.path}') sel = null;
    await _load();
  }

  void _fileSelect(io.File f) {
    final name = f.path.split('/').last;
    setState(() {
      sel = _FlashSel(name, 'ไฟล์ของฉัน', f.lengthSync(), () => f.readAsBytes(), 'file:${f.path}');
      msg = null;
    });
  }

  int _match(String bin, String xdf) {
    final tok = RegExp(r'[A-Z0-9]{2,4}-[A-Z0-9]{3}').allMatches(bin.toUpperCase()).map((m) => m.group(0)!).toSet();
    final x = xdf.toUpperCase();
    return tok.where(x.contains).length;
  }

  // จูน BIN ของฉัน: เลือก XDF จากไฟล์ของฉัน / คลังจูน / เครื่อง
  Future<void> _tuneFile(io.File f) async {
    try {
      final binName = f.path.split('/').last;
      final mine = [...xdfs]..sort((a, b) => _match(binName, b.path.split('/').last).compareTo(_match(binName, a.path.split('/').last)));
      final libX = lib.where((e) => (e['xdf'] as String).isNotEmpty).toList()
        ..sort((a, b) => _match(binName, b['part'] as String).compareTo(_match(binName, a['part'] as String)));
      final choice = await showModalBottomSheet<Object>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF0E1116),
        builder: (sctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sctx).size.height * 0.85,
            child: ListView(children: [
              Padding(padding: const EdgeInsets.all(14), child: Text('เลือก XDF สำหรับ $binName', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
              ListTile(
                leading: const Icon(Icons.folder_open, color: kAmber),
                title: const Text('เลือกไฟล์ .xdf จากเครื่อง', style: TextStyle(color: kAmber)),
                onTap: () => Navigator.pop(sctx, 'pick'),
              ),
              if (mine.isNotEmpty) _sheetHead('XDF ของฉัน'),
              for (final x in mine)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.description, color: _match(binName, x.path.split('/').last) > 0 ? kGreen : Colors.white54),
                  title: Text(x.path.split('/').last, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: _match(binName, x.path.split('/').last) > 0 ? const Text('ชื่อตรงกับ BIN', style: TextStyle(color: kGreen, fontSize: 11)) : null,
                  onTap: () => Navigator.pop(sctx, x),
                ),
              _sheetHead('XDF จากคลังจูนในแอพ'),
              for (final e in libX)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.two_wheeler, color: _match(binName, e['part'] as String) > 0 ? kGreen : Colors.white54),
                  title: Text('${e['part']}  ${e['family']}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text('${_match(binName, e['part'] as String) > 0 ? 'ชื่อตรงกับ BIN · ' : ''}${e['title']} · ${e['items']} รายการ',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _match(binName, e['part'] as String) > 0 ? kGreen : Colors.white38, fontSize: 11)),
                  onTap: () => Navigator.pop(sctx, e),
                ),
            ]),
          ),
        ),
      );
      if (choice == null) return;
      Uint8List? xb;
      if (choice is io.File) {
        xb = await choice.readAsBytes();
      } else if (choice is Map<String, dynamic>) {
        xb = await _asset(choice['xdf'] as String);
      } else {
        final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
        if (res == null || res.files.isEmpty) return;
        xb = await _bytesOf(res.files.first);
        if (xb != null && _looksXdf(xb)) { await c.importXdfBytes(res.files.first.name, xb); await _load(); }
      }
      if (xb == null) { _say('อ่าน XDF ไม่ได้', err: true); return; }
      if (!_looksXdf(xb)) { _say('ไฟล์นี้ไม่ใช่ XDF แบบ XML (อาจเข้ารหัส หรือยังอยู่ใน .rar)', err: true); return; }
      await _openTune(binName, await f.readAsBytes(), xb);
    } catch (e) {
      _say('เปิดหน้าจูนไม่สำเร็จ: $e', err: true);
    }
  }

  Widget _sheetHead(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(s, style: const TextStyle(color: kAmber, fontSize: 12, fontWeight: FontWeight.bold)),
      );

  Future<void> _openTune(String binName, Uint8List bin, Uint8List xb) async {
    final doc = XdfDoc.parse(String.fromCharCodes(xb));
    if (doc.items.isEmpty) { _say('XDF นี้ไม่มีพารามิเตอร์ หรือเป็นแบบเข้ารหัส', err: true); return; }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TunePage(
      fileName: binName,
      bin: bin,
      xdf: doc,
      getRpm: () => (c.demo || c.ecuLive) ? c.t.rpm : null,
      getTps: () => (c.demo || c.ecuLive) ? c.t.tps : null,
      onSave: (name, bytes) async { await c.importBinBytes(name, bytes); },
    )));
    await _load();
  }

  // ---------------- ส่งไปเกจ / เขียนกล่อง ----------------
  Future<void> _send() async {
    final s = sel;
    if (sending || s == null) return;
    if (c.link != LinkState.connected) { _say('ยังไม่ได้เชื่อมต่อเกจ — กด "เชื่อมต่อ" ที่หน้าหลักก่อน', err: true); return; }
    if (!c.flashSupported) { _say('เฟิร์มแวร์เกจยังไม่รองรับ (ต้อง FW 1.3.0 ขึ้นไป)', err: true); return; }
    final bytes = await s.load();
    setState(() { sending = true; sendProg = 0; msg = null; });
    final err = await c.sendBinFile(bytes, s.name, (p) { if (mounted) setState(() => sendProg = p); });
    if (!mounted) return;
    setState(() {
      sending = false; sendProg = null;
      if (err == null) { sentName = s.name; msg = 'ส่ง ${s.name} ไปเกจแล้ว — ขั้นต่อไป: กดเขียนลงกล่อง'; msgErr = false; }
      else { msg = err; msgErr = true; }
    });
  }

  Future<void> _flash() async {
    if (c.link != LinkState.connected) { _say('ยังไม่ได้เชื่อมต่อเกจ', err: true); return; }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: kBad), SizedBox(width: 8), Text('ยืนยันเขียนลงกล่อง?', style: TextStyle(color: Colors.white))]),
        content: Text(
          'ไฟล์: ${sentName ?? 'ไฟล์ในเกจ'}\nกล่อง: ${c.t.ecu?.name ?? c.t.ecmId ?? 'ไม่ทราบ'}\n\n'
          '• ยังไม่ทดสอบกับกล่องจริง เขียนผิดพลาดกล่องพังถาวรได้\n• ใช้กับกล่องสำรองก่อน\n• ห้ามดับไฟ/ถอดสายระหว่างเขียน\n• แบตเตอรี่ต้องเต็ม',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ยกเลิก')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('เขียนเลย', style: TextStyle(color: kBad, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await c.startFlash(vendor);
    if (!mounted) return;
    _say(err ?? 'เริ่มเขียนแล้ว อย่าดับไฟ/ถอดสาย', err: err != null);
  }

  Future<void> _clearGauge() async {
    final err = await c.deleteGaugeBin();
    if (!mounted) return;
    if (err == null) sentName = null;
    _say(err ?? 'ลบไฟล์ในเกจแล้ว', err: err != null);
  }

  String _stateText(int s) {
    switch (s) {
      case 1: return 'เตรียมเขียน...';
      case 2: return 'ปลดล็อกกล่อง...';
      case 3: return 'ลบข้อมูลเก่า...';
      case 4: return 'กำลังเขียนข้อมูล...';
      case 5: return 'กำลังตรวจสอบ...';
      case 6: return 'เขียนสำเร็จ';
      case 7: return 'เขียนไม่สำเร็จ';
      default: return '';
    }
  }

  static String _kb(int n) => n >= 1024 ? '${(n / 1024).toStringAsFixed(0)} KB' : '$n B';

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    final th = Cfg.i.t;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        RepaintBoundary(child: _Bg(dim: 0.45, idx: Cfg.i.bgIdx)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Column(children: [
              _header(th),
              const SizedBox(height: 8),
              Expanded(
                child: LayoutBuilder(builder: (ctx, bc) {
                  final wide = bc.maxWidth >= 720;
                  if (wide) {
                    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      SizedBox(width: math.min(340.0, bc.maxWidth * 0.38), child: SingleChildScrollView(child: _leftPane(th))),
                      const SizedBox(width: 10),
                      Expanded(child: _rightPane(th, scroll: true)),
                    ]);
                  }
                  return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _leftPane(th),
                    const SizedBox(height: 10),
                    _rightPane(th, scroll: false),
                  ]));
                }),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _header(AppTheme th) {
    return Row(children: [
      InkWell(
        onTap: () => Navigator.of(context).pop(),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.black45, border: Border.all(color: th.c), borderRadius: BorderRadius.circular(8)),
          child: Icon(Icons.arrow_back, color: th.c, size: 20),
        ),
      ),
      const SizedBox(width: 12),
      Icon(Icons.memory, color: th.c, size: 24),
      const SizedBox(width: 8),
      Text('FLASH ECU', style: TextStyle(fontFamily: kFont, fontSize: 20, color: th.c)),
      const SizedBox(width: 14),
      Expanded(
        child: AnimatedBuilder(
          animation: c,
          builder: (_, __) {
            final conn = c.link == LinkState.connected;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _pill(conn ? 'เกจเชื่อมต่อแล้ว' : 'ยังไม่ได้เชื่อมต่อเกจ', conn ? kGreen : kBad),
                _pill(c.t.ecu != null ? c.t.ecu!.name : (c.t.ecmId != null ? 'ECM ${c.t.ecmId}' : 'ไม่พบกล่อง'), c.t.ecmId != null ? kGreen : Colors.white38),
              ]),
            );
          },
        ),
      ),
      _hbtn('นำเข้าไฟล์', Icons.add, th.c, _import),
    ]);
  }

  Widget _pill(String s, Color col) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: col.withOpacity(0.8)), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(s, style: TextStyle(color: col == Colors.white38 ? Colors.white54 : Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _hbtn(String s, IconData ic, Color col, VoidCallback? f, {bool filled = false, bool big = false}) => Opacity(
        opacity: f == null ? 0.4 : 1,
        child: InkWell(
          onTap: f,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: big ? 14 : 12, vertical: big ? 12 : 8),
            decoration: BoxDecoration(
              color: filled ? col.withOpacity(0.28) : Colors.black45,
              border: Border.all(color: col, width: filled ? 1.6 : 1.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(ic, size: big ? 20 : 16, color: col),
              const SizedBox(width: 6),
              Flexible(child: Text(s, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: big ? 14 : 12, fontWeight: FontWeight.bold, color: Colors.white))),
            ]),
          ),
        ),
      );

  Widget _card(AppTheme th, {required Widget child, Color? col, String? title, IconData? icon, Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: FxPanel(
          col: col ?? th.c,
          glow: 0.25,
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null) ...[
              Row(children: [
                if (icon != null) ...[Icon(icon, size: 16, color: col ?? th.c), const SizedBox(width: 6)],
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Colors.white))),
                if (trailing != null) trailing,
              ]),
              const SizedBox(height: 10),
            ],
            child,
          ]),
        ),
      );

  Widget _kv(String k, String v, {Color col = Colors.white}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(children: [
          SizedBox(width: 92, child: Text(k, style: const TextStyle(color: Colors.white54, fontSize: 12))),
          Expanded(child: Text(v, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: TextStyle(color: col, fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]),
      );

  // ---------- ซ้าย: สถานะ + ขั้นตอน ----------
  Widget _leftPane(AppTheme th) {
    return AnimatedBuilder(
      animation: c,
      builder: (_, __) {
        final t = c.t;
        final conn = c.link == LinkState.connected;
        final active = t.flashState >= 1 && t.flashState <= 5;
        final done = t.flashState == 6, fail = t.flashState == 7;
        final inGauge = sentName != null || t.fileRx == 2;
        final canSend = sel != null && conn && c.flashSupported && !sending && !active;
        final canFlash = conn && c.flashSupported && !active && inGauge;
        final vDet = t.flashVendor == 1 ? 'Keihin' : (t.flashVendor == 2 ? 'Shindengen' : null);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // สถานะกล่อง
          _card(th, title: 'กล่อง ECU', icon: Icons.developer_board, child: Column(children: [
            _kv('รุ่น', t.ecu?.name ?? '—', col: t.ecu != null ? Colors.white : Colors.white38),
            _kv('พาร์ท', t.ecu?.part ?? '—', col: t.ecu != null ? Colors.white : Colors.white38),
            _kv('ECM ID', t.ecmId ?? '—', col: t.ecmId != null ? th.c2 : Colors.white38),
            _kv('ชนิดกล่อง', vDet ?? (t.ecu != null ? (t.ecu!.shin ? 'Shindengen' : 'Keihin') : '—'), col: Colors.white),
            _kv('เกจ FW', t.fwText ?? '—', col: t.flashSup ? kGreen : (conn ? kAmber : Colors.white38)),
          ])),
          // ขั้นตอน 1-2-3
          _card(th, title: 'ขั้นตอนเขียนกล่อง', icon: Icons.bolt, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _step(th, 1, 'เลือกไฟล์', sel != null,
                sel == null
                    ? const Text('แตะไฟล์จากคลังจูน หรือไฟล์ของฉัน ทางขวา', style: TextStyle(color: Colors.white54, fontSize: 11.5))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(sel!.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold)),
                        Text('${sel!.src} · ${_kb(sel!.size)}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ])),
            _step(th, 2, 'ส่งไฟล์ไปเกจ', inGauge, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (sending) ...[
                ClipRRect(borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(value: sendProg, minHeight: 8, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(th.c))),
                const SizedBox(height: 4),
                Text('กำลังส่ง ${((sendProg ?? 0) * 100).toInt()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ] else ...[
                if (inGauge) Text('ในเกจ: ${sentName ?? 'มีไฟล์พร้อมเขียน'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kGreen, fontSize: 11.5)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: _hbtn('ส่งไปเกจ', Icons.upload, th.c, canSend ? _send : null, filled: true)),
                  if (inGauge) ...[const SizedBox(width: 6), _hbtn('ลบในเกจ', Icons.delete_outline, kBad, active ? null : _clearGauge)],
                ]),
                if (!conn) const Padding(padding: EdgeInsets.only(top: 4), child: Text('ต้องเชื่อมต่อเกจก่อน', style: TextStyle(color: kAmber, fontSize: 11))),
                if (conn && !c.flashSupported) const Padding(padding: EdgeInsets.only(top: 4), child: Text('เฟิร์มแวร์เกจต้อง 1.3.0 ขึ้นไป', style: TextStyle(color: kAmber, fontSize: 11))),
              ],
            ])),
            _step(th, 3, 'เขียนลงกล่อง', done, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final v in const [[0, 'อัตโนมัติ'], [1, 'Keihin'], [2, 'Shindengen']])
                  InkWell(
                    onTap: active ? null : () => setState(() => vendor = v[0] as int),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: vendor == v[0] ? th.c.withOpacity(0.3) : Colors.black38,
                        border: Border.all(color: vendor == v[0] ? th.c : Colors.white24),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(v[1] as String, style: TextStyle(color: vendor == v[0] ? Colors.white : Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              if (active || done || fail) ...[
                Row(children: [
                  Icon(done ? Icons.check_circle : (fail ? Icons.error : Icons.sync), size: 16, color: done ? kGreen : (fail ? kBad : th.c)),
                  const SizedBox(width: 6),
                  Text(_stateText(t.flashState), style: TextStyle(color: done ? kGreen : (fail ? kBad : th.c), fontWeight: FontWeight.bold, fontSize: 13)),
                  const Spacer(),
                  if (active) Text('${t.flashPct}%', style: TextStyle(fontFamily: kFont, fontSize: 14, color: th.c)),
                ]),
                if (active) ...[
                  const SizedBox(height: 6),
                  ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: t.flashPct / 100.0, minHeight: 10, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(th.c))),
                  const SizedBox(height: 4),
                  const Text('ห้ามดับไฟ / ถอดสาย', style: TextStyle(color: kAmber, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
                if (fail) const Text('ต่อสายไว้ ห้ามดับไฟ แล้วลองเขียนใหม่', style: TextStyle(color: kAmber, fontSize: 11)),
                if (done) const Text('ดับกุญแจ รอ 5 วินาที แล้วสตาร์ทใหม่', style: TextStyle(color: Colors.white60, fontSize: 11)),
                const SizedBox(height: 8),
              ],
              _hbtn(active ? 'กำลังเขียน...' : 'เขียนลงกล่อง', Icons.save_alt, kBad, canFlash ? _flash : null, filled: true, big: true),
            ]), last: true),
          ])),
          // คำเตือน
          FxPanel(
            col: kBad, glow: 0.2, padding: const EdgeInsets.all(10),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, color: kBad, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('ระบบเขียนกล่องยังไม่ทดสอบกับกล่องจริง เขียนผิดพลาดกล่องพังถาวรได้ ใช้กับกล่องสำรองก่อน และห้ามดับไฟระหว่างเขียน',
                  style: TextStyle(color: kBad, fontSize: 11.5, fontWeight: FontWeight.w600))),
            ]),
          ),
          if (msg != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: msgErr ? kBad : kGreen), borderRadius: BorderRadius.circular(8)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(msgErr ? Icons.error_outline : Icons.info_outline, size: 16, color: msgErr ? kBad : kGreen),
                const SizedBox(width: 6),
                Expanded(child: Text(msg!, style: const TextStyle(color: Colors.white, fontSize: 12))),
                InkWell(onTap: () => setState(() => msg = null), child: const Icon(Icons.close, size: 16, color: Colors.white54)),
              ]),
            ),
          ),
        ]);
      },
    );
  }

  Widget _step(AppTheme th, int n, String title, bool ok, Widget body, {bool last = false}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(children: [
        Container(
          width: 24, height: 24, alignment: Alignment.center,
          decoration: BoxDecoration(color: ok ? kGreen.withOpacity(0.25) : Colors.black54, border: Border.all(color: ok ? kGreen : th.c), shape: BoxShape.circle),
          child: ok ? const Icon(Icons.check, size: 14, color: kGreen) : Text('$n', style: TextStyle(color: th.c, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      ]),
      const SizedBox(width: 10),
      Expanded(child: Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          body,
        ]),
      )),
    ]);
  }

  // ---------- ขวา: แท็บ ----------
  Widget _rightPane(AppTheme th, {required bool scroll}) {
    final tabs = [
      ['คลังจูน', '${lib.length}', Icons.inventory_2_outlined],
      ['ไฟล์ของฉัน', '${files.length}', Icons.folder_outlined],
      ['XDF', '${xdfs.length}', Icons.description_outlined],
    ];
    final List<Widget> body = loading
        ? [const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))]
        : (tab == 0 ? _libBody(th) : (tab == 1 ? _filesBody(th) : _xdfBody(th)));
    final head = Row(children: [
      for (int i = 0; i < tabs.length; i++)
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < tabs.length - 1 ? 6 : 0),
            child: InkWell(
              onTap: () => setState(() => tab = i),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: tab == i ? th.c.withOpacity(0.25) : Colors.black45,
                  border: Border.all(color: tab == i ? th.c : Colors.white24, width: tab == i ? 1.6 : 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(tabs[i][2] as IconData, size: 16, color: tab == i ? th.c : Colors.white54),
                  const SizedBox(width: 6),
                  Text(tabs[i][0] as String, style: TextStyle(color: tab == i ? Colors.white : Colors.white60, fontSize: 12.5, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                    child: Text(tabs[i][1] as String, style: TextStyle(color: tab == i ? th.c2 : Colors.white38, fontSize: 10.5)),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
    if (scroll) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        const SizedBox(height: 8),
        if (tab == 0) _libFilters(th),
        Expanded(child: ListView(padding: EdgeInsets.zero, children: body)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      const SizedBox(height: 8),
      if (tab == 0) _libFilters(th),
      ...body,
    ]);
  }

  Widget _libFilters(AppTheme th) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.search, size: 18, color: Colors.white54),
            const SizedBox(width: 6),
            Expanded(child: TextField(
              controller: _qCtl,
              onChanged: (v) => setState(() => q = v),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'ค้นหา พาร์ท / รุ่น / ECM ID เช่น K03-H01, PCX, 0101880D01', hintStyle: TextStyle(color: Colors.white38, fontSize: 12)),
            )),
            if (q.isNotEmpty) InkWell(onTap: () => setState(() { q = ''; _qCtl.clear(); }), child: const Icon(Icons.close, size: 16, color: Colors.white54)),
          ]),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final f in _fams)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () => setState(() => fam = f),
                  borderRadius: BorderRadius.circular(15),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fam == f ? th.c.withOpacity(0.3) : Colors.black45,
                      border: Border.all(color: fam == f ? th.c : Colors.white24),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(f, style: TextStyle(color: fam == f ? Colors.white : Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  List<Widget> _libBody(AppTheme th) {
    final l = _libView;
    if (l.isEmpty) return [const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('ไม่พบรุ่นที่ค้นหา', style: TextStyle(color: Colors.white54))))];
    return [for (final e in l) _libRow(th, e)];
  }

  Widget _libRow(AppTheme th, Map<String, dynamic> e) {
    final isEcu = _isEcu(e);
    final bins = (e['bins'] as List).cast<Map<String, dynamic>>();
    final selected = sel != null && bins.any((b) => sel!.key == 'lib:${b['file']}');
    final shin = e['brand'] == 'Shindengen';
    final hasX = (e['xdf'] as String).isNotEmpty;
    final col = selected ? th.c : (isEcu ? kGreen : Colors.white24);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected ? th.c.withOpacity(0.14) : Colors.black54,
        border: Border.all(color: col, width: selected || isEcu ? 1.5 : 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: () => _libSelect(e),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(children: [
            Container(
              width: 34, height: 34, alignment: Alignment.center,
              decoration: BoxDecoration(color: (shin ? kAmber : th.c).withOpacity(0.18), border: Border.all(color: shin ? kAmber : th.c), borderRadius: BorderRadius.circular(8)),
              child: Text(shin ? 'S' : 'K', style: TextStyle(fontFamily: kFont, fontSize: 14, color: shin ? kAmber : th.c)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(e['part'] as String, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
                _tag(e['family'] as String, th.c2),
                if (isEcu) ...[const SizedBox(width: 4), _tag('ตรงกับกล่อง', kGreen)],
              ]),
              const SizedBox(height: 2),
              Text(e['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              Text(
                '${e['brand']} · ${e['size']}${bins.length > 1 ? ' · ${bins.length} ไฟล์' : ''} · ${hasX ? 'XDF ${e['items']} รายการ' : 'ไม่มี XDF'}${(e['ecm'] as String).isNotEmpty ? ' · ${e['ecm']}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: hasX ? Colors.white38 : kAmber.withOpacity(0.8), fontSize: 10.5),
              ),
            ])),
            _iconAct(Icons.tune, kAmber, hasX ? () => _libTune(e) : null, 'จูน'),
            _iconAct(Icons.download, th.c, () => _libCopy(e), 'เพิ่มเข้าไฟล์ของฉัน'),
            _iconAct(selected ? Icons.radio_button_checked : Icons.radio_button_off, selected ? th.c : Colors.white38, () => _libSelect(e), 'เลือกไว้เขียน'),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String s, Color col) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: col.withOpacity(0.15), border: Border.all(color: col.withOpacity(0.7)), borderRadius: BorderRadius.circular(4)),
        child: Text(s, style: TextStyle(color: col, fontSize: 9.5, fontWeight: FontWeight.bold)),
      );

  Widget _iconAct(IconData ic, Color col, VoidCallback? f, String tip) => IconButton(
        onPressed: f,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(ic, size: 20, color: f == null ? Colors.white12 : col),
      );

  List<Widget> _filesBody(AppTheme th) {
    if (files.isEmpty) {
      return [_empty(th, Icons.folder_open, 'ยังไม่มีไฟล์ของคุณ', 'กด "นำเข้าไฟล์" เพื่อเพิ่ม .bin / .xdf หรือกด ⬇ จากคลังจูน\nไฟล์ที่จูนแล้วเซฟ จะมาอยู่ที่นี่')];
    }
    final l = [...files]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return [for (final f in l) _fileRow(th, f)];
  }

  Widget _fileRow(AppTheme th, io.File f) {
    final name = f.path.split('/').last;
    final selected = sel?.key == 'file:${f.path}';
    final tuned = name.toLowerCase().contains('_tuned');
    final dt = f.lastModifiedSync();
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: selected ? th.c.withOpacity(0.14) : Colors.black54,
        border: Border.all(color: selected ? th.c : Colors.white24, width: selected ? 1.5 : 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: () => _fileSelect(f),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(children: [
            Icon(tuned ? Icons.auto_fix_high : Icons.memory, color: tuned ? kAmber : th.c, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
                if (tuned) ...[const SizedBox(width: 6), _tag('จูนแล้ว', kAmber)],
              ]),
              Text('${_kb(f.lengthSync())} · $when', style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
            ])),
            _iconAct(Icons.tune, kAmber, () => _tuneFile(f), 'จูน'),
            _iconAct(Icons.delete_outline, kBad, sending ? null : () => _delete(f), 'ลบ'),
            _iconAct(selected ? Icons.radio_button_checked : Icons.radio_button_off, selected ? th.c : Colors.white38, () => _fileSelect(f), 'เลือกไว้เขียน'),
          ]),
        ),
      ),
    );
  }

  List<Widget> _xdfBody(AppTheme th) {
    if (xdfs.isEmpty) {
      return [_empty(th, Icons.description_outlined, 'ยังไม่มี XDF ของคุณ', 'คลังจูนในแอพมี XDF ให้แล้ว\nถ้ามี XDF ของตัวเอง กด "นำเข้าไฟล์" (ต้องเป็น XDF แบบ XML ไม่เข้ารหัส)')];
    }
    return [
      for (final x in xdfs)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(Icons.description, color: th.c2, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(x.path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
              Text(_kb(x.lengthSync()), style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
            ])),
            _iconAct(Icons.delete_outline, kBad, () => _delete(x), 'ลบ'),
          ]),
        ),
    ];
  }

  Widget _empty(AppTheme th, IconData ic, String t, String sub) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
        child: Column(children: [
          Icon(ic, size: 40, color: th.c.withOpacity(0.6)),
          const SizedBox(height: 10),
          Text(t, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(sub, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 12),
          _hbtn('นำเข้าไฟล์', Icons.add, th.c, _import),
        ]),
      );
}
