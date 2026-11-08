import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:app/core/device/device_info.dart';

/// A plugin that cannot answer, like any platform the OS refuses to describe.
class _FailingPlatform extends DeviceInfoPlatform with MockPlatformInterfaceMixin {
  @override
  Future<BaseDeviceInfo> deviceInfo() async => throw Exception('no device info');
}

void main() {
  test('load falls back to no model instead of throwing', () async {
    final original = DeviceInfoPlatform.instance;
    DeviceInfoPlatform.instance = _FailingPlatform();
    addTearDown(() => DeviceInfoPlatform.instance = original);

    final device = await DeviceInfo.load();

    expect(device.model, isEmpty);
    expect(device.platform, isNotEmpty);
    expect(device.appVersion, isNotEmpty);
  });

  group('nameOf: the name the system gives the device', () {
    test('a phone goes by its model', () {
      expect(
        DeviceInfo.nameOf(platform: 'android', model: 'Google Pixel 7', hostname: 'localhost', fallback: 'Android device'),
        'Google Pixel 7',
      );
      expect(
        DeviceInfo.nameOf(platform: 'ios', model: 'iPhone 15 Pro', hostname: '', fallback: 'iOS device'),
        'iPhone 15 Pro',
      );
    });

    test('a computer goes by its name, the demo phones too', () {
      expect(
        DeviceInfo.nameOf(platform: 'desktop', model: 'Ubuntu 24.04 LTS', hostname: 'phone-1', fallback: 'Linux device'),
        'phone-1',
      );
    });

    test('a computer with no name: its OS; nothing at all: the generic name', () {
      expect(
        DeviceInfo.nameOf(platform: 'desktop', model: 'Ubuntu 24.04 LTS', hostname: '', fallback: 'Linux device'),
        'Ubuntu 24.04 LTS',
      );
      expect(
        DeviceInfo.nameOf(platform: 'android', model: ' ', hostname: '', fallback: 'Android device'),
        'Android device',
      );
    });
  });

  test('Linux has no hardware model: the OS stands in (the demo phone)', () {
    final linux = LinuxDeviceInfo(
      name: 'Ubuntu',
      id: 'ubuntu',
      prettyName: 'Ubuntu 24.04.1 LTS',
      machineId: 'abc',
    );

    expect(DeviceInfo.modelOf(linux), 'Ubuntu 24.04.1 LTS');
  });

  group('iOS', () {
    IosDeviceInfo iphone({required String modelName}) => IosDeviceInfo.setMockInitialValues(
          name: 'iPhone',
          systemName: 'iOS',
          systemVersion: '18.0',
          model: 'iPhone',
          modelName: modelName,
          localizedModel: 'iPhone',
          freeDiskSize: 0,
          totalDiskSize: 0,
          isPhysicalDevice: true,
          isiOSAppOnMac: false,
          isiOSAppOnVision: false,
          physicalRamSize: 0,
          availableRamSize: 0,
          utsname: IosUtsname.setMockInitialValues(
            sysname: 'Darwin',
            nodename: 'iPhone',
            release: '24.0.0',
            version: 'Darwin Kernel',
            machine: 'iPhone15,3',
          ),
        );

    test('the marketing name, like the subject\'s "iPhone 6G"', () {
      expect(DeviceInfo.modelOf(iphone(modelName: 'iPhone 14 Pro Max')), 'iPhone 14 Pro Max');
    });

    test('the hardware id when the plugin does not know the name yet', () {
      expect(DeviceInfo.modelOf(iphone(modelName: '')), 'iPhone15,3');
    });
  });
}
