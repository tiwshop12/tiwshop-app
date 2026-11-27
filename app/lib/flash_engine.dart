// โปรแกรมอัด ECU Honda ผ่าน K-Line (Keihin + Shindengen) — ย้ายจาก ecu_flash.h ของเฟิร์มแวร์
// ⚠️ ESP32/สาย วิ่งได้แค่ 10400 (ไม่มี fast-write) ต้องทดสอบกับกล่องสำรองก่อนใช้จริงเสมอ เขียนพลาด = กล่องพังถาวร
import 'dart:async';
import 'dart:typed_data';
import 'kline.dart';
import 'ecu_flash_db.dart';

// สถานะ (ตรงกับ FL_*)
const flIdle = 0, flInit = 1, flUnlock = 2, flErase = 3, flWrite = 4, flVerify = 5, flOk = 6, flFail = 7;
// ชนิดกล่อง
const _keihinOther = 0, _keihinH8C = 1, _keihinM32R = 2, _shinV850 = 3, _shinRH850 = 4, _shinRH850B = 5;

const _sigShbin = [0x5A, 0x5A, 0x5A, 0x5A];
const _sigWkey = [0x11, 0x12, 0x13, 0x14, 0x15, 0x15, 0x17];
const _sigRkey = [0x91, 0x91, 0x0D, 0x00, 0x9E, 0x8D];
const _sigV850 = [0x53, 0x56, 0x38, 0x35, 0x30];
const _sigRH850 = [0x53, 0x48, 0x38, 0x35, 0x30];
const _sigStart0 = [0xA5, 0xA5, 0xA5, 0xA5, 0x00];
const _sigH8C = [0xFF, 0xFF, 0xAA, 0xAA];
const _sigM32R = [0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0xAA];
const _sigKRH850 = [0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00];
const _sigMPC560 = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
const _sigSH705X = [0xFF, 0xFF, 0xFF, 0xAA, 0xAA, 0xAA, 0xAA];

int _csHonda(List<int> d, int start, int size) {
  int s = 0;
  for (int i = 0; i < size; i++) s += d[start + i];
  return ((s ^ 0xFF) + 1) & 0xFF;
}

int _csBit(List<int> d, int start, int size) {
  int s = 0;
  for (int i = 0; i < size; i++) s += d[start + i];
  return (255 - ((s - 1) >> 8)) & 0xFF;
}

class FlashResult {
  final bool ok;
  final int failCode; // 1 ไฟล์, 2 ต่อกล่องไม่ได้, 5 ปลดล็อค/ลบ, 6 เขียน, 7 ชนิดไม่ตรง, 8 checksum เกินไฟล์
  final String? part;
  final int vendorDet; // 1 Keihin, 2 Shindengen
  final List<int>? ecm;
  FlashResult(this.ok, this.failCode, {this.part, this.vendorDet = 0, this.ecm});
}

class FlashEngine {
  final KLine kl;
  final Uint8List bin; // สำเนาที่แก้ checksum ได้
  final void Function(int state, int pct)? onProgress;
  final void Function(String msg)? onLog;

  FlashEngine(this.kl, Uint8List source, {this.onProgress, this.onLog}) : bin = Uint8List.fromList(source);

  int get fsize => bin.length;
  List<int> _rb = const [];
  int _ecuType = 0;
  int _startOffset = 0;
  int _cksumOffset = 0;
  bool _isShin = false;
  final List<int> _ecm = [0, 0, 0, 0, 0];
  bool _ecmOk = false;

  void _st(int s, int p) => onProgress?.call(s, p);
  void _log(String m) => onLog?.call(m);

  Future<bool> _cmd(List<int> frame, {int sleepMs = 0}) async {
    final r = await kl.flCmd(frame, sleepMs: sleepMs);
    if (r == null) return false;
    _rb = r;
    return true;
  }

  // ---------- หา signature ----------
  int _find(List<int> sig, [int start = 0]) {
    final n = sig.length;
    for (int i = start; i + n <= bin.length; i++) {
      int k = 0;
      while (k < n && bin[i + k] == sig[k]) k++;
      if (k == n) return i;
    }
    return -1;
  }

  bool _endIs(List<int> sig) {
    if (bin.length < sig.length) return false;
    final off = bin.length - sig.length;
    for (int i = 0; i < sig.length; i++) if (bin[off + i] != sig[i]) return false;
    return true;
  }

  bool _sigAt(int off, List<int> sig) {
    if (off + sig.length > bin.length) return false;
    for (int i = 0; i < sig.length; i++) if (bin[off + i] != sig[i]) return false;
    return true;
  }

  // ---------- ชนิดกล่องจากไฟล์ (= GetEcuType) ----------
  int _getEcuType() {
    if (_endIs(_sigShbin)) {
      final w = _find(_sigWkey), v = _find(_sigV850), r = _find(_sigRH850);
      if (v >= 0 && (r < 0 || v < r)) { _startOffset = 0x10000; return _shinV850; }
      if (r >= 0) {
        if (bin.length > 40960 + 5 && _sigAt(40960, _sigStart0)) { _startOffset = 0xA000; return _shinRH850B; }
        _startOffset = 0x10000; return _shinRH850;
      }
      if (w >= 0) { _startOffset = 0x10000; return _shinV850; }
    }
    if ((fsize == 57344 || fsize == 32768) && _endIs(_sigH8C)) return _keihinH8C;
    if (fsize == 262144 && _endIs(_sigM32R)) return _keihinM32R;
    return _keihinOther;
  }

  void _offsetsFromBinType() {
    _startOffset = 0; _cksumOffset = 0;
    switch (fsize) {
      case 49152: _startOffset = 0x4000; _cksumOffset = 0x7600; return;
      case 57344: _startOffset = 0; _cksumOffset = 0xDFEF; return;
      case 65536:
      case 98304: _startOffset = 0x8000; _cksumOffset = 0; return;
      case 131072: _startOffset = 0xE0000; _cksumOffset = 0xB000; return;
    }
    if (fsize < 262144) return;
    if (_endIs(_sigShbin)) return;
    if (fsize == 262144 && (_endIs(_sigKRH850) || _endIs(_sigM32R) || _endIs(_sigMPC560))) { _cksumOffset = 0x3FFF8; return; }
    if (fsize == 524288) { if (_endIs(_sigMPC560)) _cksumOffset = 0x7FFF8; return; }
    if (fsize == 1048576) { _cksumOffset = _endIs(_sigSH705X) ? 0xFFFF8 : 0x7FFF8; return; }
  }

  // ---------- checksum ----------
  void _keihinChecksum(int ckOff) {
    int sum = 0;
    for (int i = 0; i < fsize; i++) { if (i == ckOff) continue; sum += bin[i]; }
    bin[ckOff] = (-(sum & 0xFF)) & 0xFF;
  }

  int _sum32(int start, int len) {
    int s = 0;
    final end = start + (len & ~3);
    for (int i = start; i + 4 <= end; i += 4) {
      s = (s + (bin[i] | (bin[i + 1] << 8) | (bin[i + 2] << 16) | (bin[i + 3] << 24))) & 0xFFFFFFFF;
    }
    return s;
  }

  void _shinChecksum() {
    final si = _find(_sigWkey);
    if (si < 0) return;
    for (int j = si + 7; j + 2 <= fsize; j++) {
      if (bin[j] == 0xD0 && bin[j + 1] == 0x07) {
        int num = j;
        if (((j - 4) & 3) == 2) num = j - 6;
        final total = (_sum32(0, num - 4) + _sum32(num, fsize - num)) & 0xFFFFFFFF;
        final ck = (0 - total) & 0xFFFFFFFF;
        bin[num - 4] = ck & 0xFF;
        bin[num - 3] = (ck >> 8) & 0xFF;
        bin[num - 2] = (ck >> 16) & 0xFF;
        bin[num - 1] = (ck >> 24) & 0xFF;
        return;
      }
    }
  }

  // ---------- Shindengen seed/key ----------
  List<int>? _shinKey(int s0, int s1, bool recovery) {
    final seed = (s0 * 256 + s1) & 0xFFFF;
    if (!recovery) {
      final si = _find(_sigWkey);
      if (si < 0) return null;
      for (int j = si + 7; j + 10 <= fsize; j++) {
        if (bin[j + 8] == 0xEE && (bin[j + 9] == 0x00 || bin[j + 9] == 0xFF)) {
          final a = bin[j] | (bin[j + 1] << 8), b = bin[j + 2] | (bin[j + 3] << 8), c = bin[j + 4] | (bin[j + 5] << 8);
          final m = (b * ((seed + a) & 0xFFFF)) & 0xFFFF;
          final key = (c > 0 ? (m + seed % c) : (m + seed)) & 0xFFFF;
          return [key >> 8, key & 0xFF];
        }
      }
      return null;
    }
    final i = _find(_sigRkey);
    if (i < 6) return null;
    final o = i - 6;
    final a = bin[o] | (bin[o + 1] << 8), b = bin[o + 2] | (bin[o + 3] << 8), c = bin[o + 4] | (bin[o + 5] << 8);
    final m = (b * ((seed + a) & 0xFFFF)) & 0xFFFF;
    final key = (c > 0 ? (m + seed % c) : (m + seed)) & 0xFFFF;
    return [key >> 8, key & 0xFF];
  }

  // ---------- connect + อ่าน ECM ----------
  Future<bool> _connect() async {
    if (await kl.init()) return true;
    kl.flush();
    if (await _cmd([0x7E, 0x06, 0x01, 0x01, 0x00, 0x7A]) && _rb[3] != 0x0F) return true;
    if (await _cmd([0x7C, 0x06, 0x02, 0x01, 0x00, 0x7B], sleepMs: 150) && _rb[3] != 0x0F) return true;
    return false;
  }

  Future<void> _readEcm() async {
    _ecmOk = false;
    if (await _cmd([0x72, 0x07, 0x72, 0x00, 0x00, 0x05, 0x10]) && _rb.length >= 11) {
      for (int i = 0; i < 5; i++) _ecm[i] = _rb[5 + i];
      _ecmOk = true;
    }
  }

  // ---------- Keihin: unlock + erase ----------
  Future<bool> _keihinPrepare() async {
    _st(flUnlock, 0);
    for (int a = 0;; a++) {
      if (await _cmd([0x7D, 0x08, 0x01, 0x02, 0x50, 0x47, 0x4D, 0x94])) {
        await _cmd([0x7D, 0x08, 0x01, 0x03, 0x2D, 0x46, 0x49, 0xBB]);
        break;
      }
      await _d(500);
      if (a >= 1) break;
    }
    await _d(200);
    const status = [0x7E, 0x06, 0x01, 0x01, 0x00, 0x7A];
    await _cmd(status);
    for (int i = 0; i < 10; i++) { _st(flUnlock, (i + 1) * 3); await _d(1000); }
    await _d(500);
    _st(flErase, 0);
    await _cmd([0x7E, 0x05, 0x01, 0x02, 0x7A], sleepMs: 250);
    await _cmd([0x7E, 0x07, 0x01, 0x03, 0x00, 0x00, 0x77]);
    await _cmd(status);
    await _cmd([0x7E, 0x0B, 0x01, 0x0B, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x6E]);
    await _cmd(status);
    await _cmd([0x7E, 0x07, 0x01, 0x0E, 0x01, 0x90, 0xDB]);
    if (!(await _cmd([0x7E, 0x06, 0x01, 0x04, 0xFF, 0x78]) && _rb[3] == 0x00)) return false;
    await _d(2000);
    if (await _cmd([0x7E, 0x05, 0x01, 0x05, 0x77], sleepMs: 250) && _rb[3] == 0x00) { await _cmd(status); return true; }
    return false;
  }

  // ---------- Shindengen: unlock + seed/key + erase ----------
  Future<bool> _shinPrepare(bool recovery) async {
    const sm = 150;
    _st(flUnlock, 0);
    await _cmd([0x7B, 0x08, 0x02, 0x02, 0x50, 0x19, 0x76, 0x9A], sleepMs: sm);
    await _cmd([0x7B, 0x08, 0x02, 0x03, 0x25, 0x37, 0x86, 0x96], sleepMs: sm);
    for (int i = 0; i < 10; i++) { _st(flUnlock, (i + 1) * 3); await _d(1000); }
    await _d(500);
    if (!(await _cmd([0x7B, 0x05, 0x02, 0x04, 0x7A], sleepMs: sm) && _rb[1] == 7 && _rb[3] == 0x00)) return false;
    final s0 = _rb[4], s1 = _rb[5];
    final k = _shinKey(s0, s1, recovery);
    if (k == null) return false;
    final key = [0x7B, 0x07, 0x02, 0x05, k[0], k[1], 0];
    key[6] = _csHonda(key, 0, 6);
    if (!(await _cmd(key, sleepMs: sm) && _rb[1] == 5 && _rb[3] == 0x00)) return false;
    _st(flErase, 0);
    await _cmd([0x7C, 0x06, 0x02, 0x01, 0x00, 0x7B], sleepMs: sm);
    await _cmd([0x7C, 0x0B, 0x02, 0x0B, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x6F], sleepMs: sm);
    await _cmd([0x7C, 0x07, 0x02, 0x0E, 0x01, 0x00, 0x6C], sleepMs: sm);
    if (!(await _cmd([0x7C, 0x06, 0x02, 0x04, 0xFF, 0x79], sleepMs: sm) && _rb[3] == 0x00)) return false;
    await _d(2000);
    if (await _cmd([0x7C, 0x05, 0x02, 0x05, 0x78], sleepMs: sm) && _rb[3] == 0x00) return true;
    return false;
  }

  bool _blockAllFF(int off, int n) {
    if (off + n > bin.length) return false;
    for (int i = 0; i < n; i++) if (bin[off + i] != 0xFF) return false;
    return true;
  }

  // ---------- เขียนทีละบล็อก ----------
  Future<bool> _writeFlash() async {
    int hdr, sub, block = 128, incr = 8;
    bool skip;
    switch (_ecuType) {
      case _keihinH8C: hdr = 0x7E; sub = 0x01; block = 64; incr = 4; skip = false; break;
      case _keihinM32R: hdr = 0x7E; sub = 0x01; skip = false; break;
      case _shinV850: hdr = 0x7C; sub = 0x02; skip = true; break;
      case _shinRH850:
      case _shinRH850B: hdr = 0x7C; sub = 0x02; skip = false; break;
      default: hdr = 0x7E; sub = 0x01; skip = true; break;
    }
    final sm = _isShin ? 150 : 0;
    final len = block + 11;
    final blocks = fsize ~/ block;
    int addr = _startOffset ~/ 16;
    int bi = _isShin ? (_startOffset ~/ block) : 0;
    int errRetry = 0;
    final fr = List<int>.filled(160, 0);
    _st(flWrite, 0);
    while (bi < blocks) {
      fr[0] = hdr; fr[1] = len; fr[2] = sub; fr[3] = 0x06;
      fr[4] = (addr >> 8) & 0xFF; fr[5] = addr & 0xFF;
      final src = bi * block;
      for (int i = 0; i < block; i++) fr[6 + i] = bin[src + i];
      int endAddr;
      if (skip) {
        endAddr = addr + incr;
        for (int j = 1; j < blocks - bi; j++) {
          if (!_blockAllFF((bi + j) * block, block)) { endAddr = addr + j * incr; bi += j - 1; break; }
          if (bi + j + 1 == blocks) bi += j;
        }
      } else {
        endAddr = addr + incr;
      }
      if (bi + 1 == blocks) endAddr = 0;
      fr[6 + block] = (endAddr >> 8) & 0xFF;
      fr[6 + block + 1] = endAddr & 0xFF;
      fr[6 + block + 2] = _csBit(fr, 4, block + 4);
      fr[6 + block + 3] = _csHonda(fr, 4, block + 4);
      fr[6 + block + 4] = _csHonda(fr, 0, len - 1);
      final frame = fr.sublist(0, len);
      int comm = 0;
      for (;;) {
        final r = await kl.flCmd(frame, sleepMs: sm);
        if (r == null) { if (++comm > 60) return false; await _d(20); continue; }
        _rb = r;
        if (r[1] == 7) {
          if (r[4] == 0 && r[5] == 0 && errRetry < 2) { errRetry++; continue; }
          if (comm > 0) break;
          return false;
        }
        if (r[1] != 5) return false;
        break;
      }
      if (block == 64 && (bi + 1) % 2 == 0) { await _cmd([0x7E, 0x05, 0x01, 0x07, 0x75]); await _d(100); }
      addr = endAddr;
      bi++;
      _st(flWrite, (bi * 100 ~/ blocks));
    }
    return true;
  }

  // ---------- finish ----------
  Future<bool> _cmdF(List<int> c, int sm) async {
    for (int a = 0; a < 3; a++) {
      if (await _cmd(c, sleepMs: sm)) { _noReply = false; return _rb[3] == 0x0F; }
      await _d(200);
    }
    _noReply = true;
    return false;
  }

  bool _noReply = false;

  Future<bool> _ecuBooted() async {
    for (int a = 0; a < 3; a++) { await _d(1000); if (await kl.init()) return true; }
    return false;
  }

  Future<bool> _finishKeihin(int block) async {
    const status = [0x7E, 0x06, 0x01, 0x01, 0x00, 0x7A];
    _st(flVerify, 0);
    if (block == 64) { await _cmd([0x7E, 0x05, 0x01, 0x07, 0x75]); await _d(100); }
    await _cmd([0x7E, 0x05, 0x01, 0x08, 0x74]); await _d(1000);
    await _cmd(status); await _cmd([0x7E, 0x05, 0x01, 0x09, 0x73]); await _d(1000);
    await _cmd(status); await _cmd([0x7E, 0x05, 0x01, 0x0A, 0x72]); await _d(1000);
    await _cmd(status); await _cmd([0x7E, 0x05, 0x01, 0x0C, 0x70]); await _d(1000);
    bool ok = await _cmdF(status, 0);
    if (ok) ok = await _cmdF([0x7E, 0x05, 0x01, 0x0D, 0x6F], 0);
    if (!ok && _noReply) ok = await _ecuBooted();
    return ok;
  }

  Future<bool> _finishShin() async {
    const sm = 150;
    _st(flVerify, 0);
    await _cmd([0x7C, 0x05, 0x02, 0x08, 0x75], sleepMs: sm); await _d(1000);
    await _cmd([0x7C, 0x05, 0x02, 0x09, 0x74], sleepMs: sm); await _d(1000);
    await _cmd([0x7C, 0x05, 0x02, 0x0A, 0x73], sleepMs: sm); await _d(1000);
    await _cmd([0x7C, 0x05, 0x02, 0x0C, 0x71], sleepMs: sm); await _d(3000);
    bool ok = await _cmdF([0x7C, 0x05, 0x02, 0x0D, 0x70], sm);
    if (!ok && _noReply) ok = await _ecuBooted();
    return ok;
  }

  Future<void> _d(int ms) => Future.delayed(Duration(milliseconds: ms));

  // ===================== ลำดับทั้งหมด =====================
  Future<FlashResult> run({int vendorReq = 0}) async {
    _st(flInit, 0);
    if (fsize < 1024) { _st(flFail, 0); return FlashResult(false, 1); }
    _log('เชื่อมต่อกล่อง…');
    if (!await _connect()) { _st(flFail, 0); return FlashResult(false, 2); }
    await _readEcm();
    _log(_ecmOk ? 'ECM ID: ${_ecm.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ')}' : 'อ่าน ECM ID ไม่ได้ (โหมดกู้คืน)');

    bool recovery = !_ecmOk || (_ecm[3] == 0 && _ecm[4] == 0);
    String? part;
    _startOffset = 0; _cksumOffset = 0;
    bool known = false;
    if (!recovery) {
      final r = ecuFlashDbFind(_ecm);
      if (r != null) { known = true; part = r.part; _startOffset = r.start ?? 0; _cksumOffset = r.cksum ?? 0; }
    }
    if (!known) _offsetsFromBinType();

    // ชนิดจากไฟล์
    _ecuType = _getEcuType(); // ตั้ง _startOffset สำหรับ Shindengen ด้วย
    _isShin = _ecuType == _shinV850 || _ecuType == _shinRH850 || _ecuType == _shinRH850B;
    final vendorDet = _isShin ? 2 : 1;
    _log(_isShin ? 'ชนิด: Shindengen' : 'ชนิด: Keihin');
    if ((vendorReq == 1 && _isShin) || (vendorReq == 2 && !_isShin)) { _st(flFail, 0); return FlashResult(false, 7, vendorDet: vendorDet); }

    if (!_isShin && _cksumOffset >= fsize) { _st(flFail, 0); return FlashResult(false, 8, vendorDet: vendorDet); }
    _log('แก้ checksum ในไฟล์…');
    if (_isShin) _shinChecksum(); else _keihinChecksum(_cksumOffset);

    bool ok = false;
    int fail = 0;
    if (_isShin) {
      if (!await _shinPrepare(recovery)) { fail = 5; }
      else if (!await _writeFlash()) { fail = 6; }
      else ok = await _finishShin();
    } else {
      if (!await _keihinPrepare()) { fail = 5; }
      else if (!await _writeFlash()) { fail = 6; }
      else ok = await _finishKeihin(_ecuType == _keihinH8C ? 64 : 128);
    }
    _st(ok ? flOk : flFail, ok ? 100 : 0);
    return FlashResult(ok, ok ? 0 : (fail == 0 ? 6 : fail), part: part, vendorDet: vendorDet, ecm: _ecmOk ? List.of(_ecm) : null);
  }
}
