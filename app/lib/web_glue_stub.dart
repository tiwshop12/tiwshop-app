// ใช้บนแอพ (Android/iOS): ไม่มี Web Bluetooth
import 'dart:typed_data';

class WebGatt {
  static bool get supported => false;
  static Future<WebGatt?> request(String svc) async => null;
  String get name => '';
  Future<void> connect(String svc, List<String> chars) async {}
  bool has(String c) => false;
  Stream<void> get onDisconnected => const Stream.empty();
  Future<Stream<List<int>>> notify(String c) async => const Stream.empty();
  Future<void> write(String c, List<int> b, {bool resp = true}) async {}
  void disconnect() {}
}

void webDownload(String name, Uint8List bytes) {}
bool get webIsIOS => false;
bool get webPortrait => false;
