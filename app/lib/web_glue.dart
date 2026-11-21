// เว็บไซต์ TIWSHOP: เชื่อมเกจผ่าน Web Bluetooth (Chrome บน Android / แอพ Bluefy บน iPhone) + ดาวน์โหลดไฟล์
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

JSObject? _nav() => globalContext.getProperty<JSObject?>('navigator'.toJS);

class WebGatt {
  final JSObject dev;
  JSObject? _svc;
  final Map<String, JSObject> _ch = {};
  final _disc = StreamController<void>.broadcast();
  Future<void> _q = Future.value(); // Web Bluetooth ทำได้ทีละคำสั่ง -> ต่อคิว
  WebGatt._(this.dev);

  static bool get supported {
    final n = _nav();
    return n != null && n.has('bluetooth');
  }

  String get name => dev.getProperty<JSString?>('name'.toJS)?.toDart ?? 'TIWSHOP';

  /// เปิดหน้าต่างเลือกอุปกรณ์ของเบราว์เซอร์ (ต้องเรียกจากการกดปุ่ม) ; null = ผู้ใช้กดยกเลิก
  static Future<WebGatt?> request(String svc) async {
    final bt = _nav()!.getProperty<JSObject>('bluetooth'.toJS);
    final opts = {
      'filters': [
        {'services': [svc]},
        {'namePrefix': 'TIWSHOP'},
      ],
      'optionalServices': [svc],
    }.jsify() as JSObject;
    try {
      final d = await bt.callMethod<JSPromise<JSObject>>('requestDevice'.toJS, opts).toDart;
      return WebGatt._(d);
    } catch (e) {
      if ('$e'.contains('NotFoundError') || '$e'.contains('cancel')) return null;
      rethrow;
    }
  }

  Future<void> connect(String svc, List<String> chars) async {
    final gatt = dev.getProperty<JSObject>('gatt'.toJS);
    final server = await gatt.callMethod<JSPromise<JSObject>>('connect'.toJS).toDart;
    _svc = await server.callMethod<JSPromise<JSObject>>('getPrimaryService'.toJS, svc.toJS).toDart;
    for (final c in chars) {
      try {
        _ch[c] = await _svc!.callMethod<JSPromise<JSObject>>('getCharacteristic'.toJS, c.toJS).toDart;
      } catch (_) {}
    }
    dev.callMethod<JSAny?>('addEventListener'.toJS, 'gattserverdisconnected'.toJS, ((JSObject _) {
      _disc.add(null);
    }).toJS);
  }

  bool has(String c) => _ch.containsKey(c);
  Stream<void> get onDisconnected => _disc.stream;

  Future<Stream<List<int>>> notify(String c) async {
    final ch = _ch[c];
    if (ch == null) throw StateError('ไม่พบช่องข้อมูล $c');
    final sc = StreamController<List<int>>.broadcast();
    ch.callMethod<JSAny?>('addEventListener'.toJS, 'characteristicvaluechanged'.toJS, ((JSObject ev) {
      final dv = ev.getProperty<JSObject>('target'.toJS).getProperty<JSObject>('value'.toJS);
      final buf = dv.getProperty<JSArrayBuffer>('buffer'.toJS).toDart;
      final off = dv.getProperty<JSNumber>('byteOffset'.toJS).toDartInt;
      final len = dv.getProperty<JSNumber>('byteLength'.toJS).toDartInt;
      sc.add(Uint8List.fromList(buf.asUint8List(off, len)));
    }).toJS);
    await ch.callMethod<JSPromise<JSAny?>>('startNotifications'.toJS).toDart;
    return sc.stream;
  }

  Future<void> write(String c, List<int> b, {bool resp = true}) {
    final r = _q.then((_) => _write(c, b, resp));
    _q = r.catchError((_) {});
    return r;
  }

  Future<void> _write(String c, List<int> b, bool resp) async {
    final ch = _ch[c];
    if (ch == null) throw StateError('ไม่พบช่องข้อมูล $c');
    final data = Uint8List.fromList(b).toJS;
    if (!resp) {
      try {
        await ch.callMethod<JSPromise<JSAny?>>('writeValueWithoutResponse'.toJS, data).toDart;
        return;
      } catch (_) {}
    }
    await ch.callMethod<JSPromise<JSAny?>>('writeValueWithResponse'.toJS, data).toDart;
  }

  void disconnect() {
    try {
      dev.getProperty<JSObject>('gatt'.toJS).callMethod<JSAny?>('disconnect'.toJS);
    } catch (_) {}
  }
}

/// ดาวน์โหลดไฟล์ลงเครื่อง (เว็บ)
void webDownload(String name, Uint8List bytes) {
  try {
    final blobCtor = globalContext.getProperty<JSFunction>('Blob'.toJS);
    final blob = blobCtor.callAsConstructor<JSObject>([bytes.toJS].toJS, {'type': 'application/octet-stream'}.jsify());
    final url = globalContext.getProperty<JSObject>('URL'.toJS).callMethod<JSString>('createObjectURL'.toJS, blob);
    final doc = globalContext.getProperty<JSObject>('document'.toJS);
    final a = doc.callMethod<JSObject>('createElement'.toJS, 'a'.toJS);
    a.setProperty('href'.toJS, url);
    a.setProperty('download'.toJS, name.toJS);
    doc.getProperty<JSObject>('body'.toJS).callMethod<JSAny?>('appendChild'.toJS, a);
    a.callMethod<JSAny?>('click'.toJS);
    a.callMethod<JSAny?>('remove'.toJS);
  } catch (_) {}
}

bool get webIsIOS {
  final ua = _nav()?.getProperty<JSString?>('userAgent'.toJS)?.toDart ?? '';
  return RegExp(r'iPhone|iPad|iPod').hasMatch(ua);
}

bool get webPortrait {
  final w = globalContext.getProperty<JSNumber?>('innerWidth'.toJS)?.toDartDouble ?? 1;
  final h = globalContext.getProperty<JSNumber?>('innerHeight'.toJS)?.toDartDouble ?? 0;
  return h > w;
}

/// เต็มจอ (เหมือนดูหนัง) + ล็อกจอแนวนอน — ฟังก์ชัน JS อยู่ใน web/index.html
void webFullscreenToggle() {
  try {
    globalContext.callMethod<JSAny?>('tiwFullscreenToggle'.toJS);
  } catch (_) {}
}

bool get webFullscreen {
  try {
    final d = globalContext.getProperty<JSObject>('document'.toJS);
    return d.getProperty<JSAny?>('fullscreenElement'.toJS) != null || d.getProperty<JSAny?>('webkitFullscreenElement'.toJS) != null;
  } catch (_) {
    return false;
  }
}
