import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gauge/tune.dart';

void main() {
  test('dump digest of every bundled XDF/BIN', () {
    final idx = jsonDecode(File('assets/tunelib/index.json').readAsStringSync()) as List;
    final out = StringBuffer();
    for (final e in idx) {
      final xdf = String.fromCharCodes(File('assets/tunelib/${e['xdf']}').readAsBytesSync());
      final doc = XdfDoc.parse(xdf);
      for (final b in (e['bins'] as List)) {
        final bin = File('assets/tunelib/${b['file']}').readAsBytesSync();
        for (final l in xdfDigest(doc, bin)) { out.writeln('${e['part']}|${b['file']}|$l'); }
      }
    }
    Directory('build').createSync(recursive: true);
    File('build/xdf_digest.txt').writeAsStringSync(out.toString());
    expect(out.isNotEmpty, true);
  });
}
