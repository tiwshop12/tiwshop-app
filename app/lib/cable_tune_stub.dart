// จูนผ่านสาย — สตับสำหรับเว็บ (เบราว์เซอร์ต่อสาย USB เข้า ECU ไม่ได้)
import 'dart:typed_data';
import 'package:flutter/material.dart';

const bool cableSupported = false;

abstract class CableSession {
  Future<bool> connect();
  Future<bool> reconnect();
  String? get ecmIdHex;
  int? get flashCount;
  Future<Map<String, double?>?> readLive();
  Future<bool> flash(Uint8List bin, int vendorReq, void Function(int state, int pct) onProgress, void Function(String msg) onLog);
  Future<void> dispose();
}

CableSession? makeCableSession() => null;

Future<bool> runCableFlash(BuildContext context, Uint8List bin, String fileName, int vendorReq) async {
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('อัดผ่านสาย USB ใช้ได้เฉพาะแอป Android')));
  return false;
}

class CableTunePage extends StatelessWidget {
  const CableTunePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('จูนผ่านสาย')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'จูนผ่านสาย USB เข้า ECU ใช้ได้เฉพาะแอป Android\nเว็บไม่รองรับการต่อสาย',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}
