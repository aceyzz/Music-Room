import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/core/network/backend_address.dart';

/// The sign-in page's "Server" link: where the backend is, and a form to
/// change it ([showServerDialog]). One APK, or one phone, reaches any machine
/// on the network, not only the one it was built for.
class ServerButton extends StatelessWidget {
  const ServerButton({super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => showServerDialog(context),
        icon: const Icon(Icons.dns_outlined, size: 18),
        label: Text('Server: ${BackendAddress.current}'),
      );
}

/// Asks for the backend's host and ports, and saves them for the next start
/// (BackendAddress): the connections are built at start-up. On Linux, the
/// demo phone, the app quits and its container starts it again; elsewhere
/// the user reopens it.
Future<void> showServerDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (context) => const _ServerDialog());

/// How the app restarts once a new address is saved: it quits on Linux, the
/// demo phone, whose entrypoint brings it back; null where the user reopens
/// it by hand (a phone). Tests replace it: they run on Linux too.
@visibleForTesting
void Function()? restartApp = !kIsWeb && Platform.isLinux ? () => exit(0) : null;

class _ServerDialog extends StatefulWidget {
  const _ServerDialog();

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final _host = TextEditingController(text: BackendAddress.current.host);
  late final _port = TextEditingController(text: '${BackendAddress.current.port}');
  late final _httpPort = TextEditingController(text: '${BackendAddress.current.httpPort}');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _httpPort.dispose();
    super.dispose();
  }

  void _fill(BackendAddress address) {
    _host.text = address.host;
    _port.text = '${address.port}';
    _httpPort.text = '${address.httpPort}';
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) {
      return;
    }
    final address = BackendAddress(
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      httpPort: int.parse(_httpPort.text.trim()),
    );
    await BackendAddress.save(address);
    if (restartApp case final restart?) {
      restart();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Saved: close and reopen the app to connect to $address.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: const Text('Server'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("The machine running Music Room's backend: its address on your network.", style: hint),
            const SizedBox(height: 8),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(labelText: 'Host', hintText: '192.168.1.20'),
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: (value) =>
                  value == null || value.trim().isEmpty || value.trim().contains(RegExp(r'[\s/:]'))
                      ? 'A host name or an IP address, without http:// or a port.'
                      : null,
            ),
            TextFormField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'gRPC port'),
              keyboardType: TextInputType.number,
              validator: _portError,
            ),
            TextFormField(
              controller: _httpPort,
              decoration: const InputDecoration(labelText: 'HTTP port (images)'),
              keyboardType: TextInputType.number,
              validator: _portError,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _fill(BackendAddress.fromBuild),
          child: const Text('Default'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _save,
          child: Text(restartApp != null ? 'Save and restart' : 'Save'),
        ),
      ],
    );
  }
}

String? _portError(String? value) {
  final port = int.tryParse(value?.trim() ?? '');
  return port == null || port < 1 || port > 65535 ? 'A port, 1 to 65535.' : null;
}
