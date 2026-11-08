import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/location/position_source.dart';

void main() {
  test('the demo file reads "latitude,longitude"', () {
    expect(FilePositionSource.parse('48.8566,2.3522'), (latitude: 48.8566, longitude: 2.3522));
    expect(FilePositionSource.parse(' 45.76 , 4.83 \n'), (latitude: 45.76, longitude: 4.83));
  });

  test('off, empty or garbled is no position', () {
    for (final text in ['off', '', '48.8', 'a,b', '1,2,3']) {
      expect(FilePositionSource.parse(text), isNull, reason: text);
    }
  });

  test('no file is no position', () async {
    final dir = await Directory.systemTemp.createTemp('position');
    addTearDown(() => dir.delete(recursive: true));

    expect(await FilePositionSource('${dir.path}/missing').current(), isNull);
    File('${dir.path}/position').writeAsStringSync('43.30,5.37');
    expect(await FilePositionSource('${dir.path}/position').current(),
        (latitude: 43.30, longitude: 5.37));
  });
}
