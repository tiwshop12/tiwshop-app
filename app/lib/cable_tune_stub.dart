// จูนผ่านสาย — สตับสำหรับเว็บ (เบราว์เซอร์ต่อสาย USB เข้า ECU ไม่ได้)
import 'package:flutter/material.dart';

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
