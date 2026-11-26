import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:nabrila/dio.dart';
import 'package:nabrila/nabrila.dart';

// Run with:
//   flutter run --dart-define=NABRILA_ENABLED=true --dart-define=NABRILA_KEY=nbr_...
// Without NABRILA_ENABLED the SDK is off: no button, no recording, no uploads.
const _enabled = bool.fromEnvironment('NABRILA_ENABLED');
const _appKey = String.fromEnvironment('NABRILA_KEY');

void main() {
  Nabrila.run(
    appKey: _appKey,
    enabled: _enabled,
    // endpoint: 'https://nabrila.com', // optional override
    app: () => runApp(const NabrilaScope(child: ExampleApp())),
  );
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nabrila example',
      // Records route changes into the ring buffer.
      navigatorObservers: [Nabrila.navigatorObserver],
      routes: {
        '/': (_) => const HomePage(),
        '/details': (_) => const Scaffold(body: Center(child: Text('Details'))),
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // package:http needs the wrapper: it has no interceptors.
  final _http = NabrilaHttpClient(http.Client());

  // Dio takes the interceptor. captureBodies stays false unless you opt in.
  final _dio = Dio()..interceptors.add(NabrilaDioInterceptor());

  Future<void> _callHttp() async {
    await _http.get(Uri.parse('https://example.com/?token=secret'));
  }

  Future<void> _callDio() async {
    try {
      await _dio.get<dynamic>('https://example.com/missing');
    } on DioException {
      // The failed call is still in the report.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nabrila example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton(
            onPressed: () => Navigator.of(context).pushNamed('/details'),
            child: const Text('Open details'),
          ),
          FilledButton(
            onPressed: () => debugPrint('Checkout failed: gateway timeout'),
            child: const Text('Log an error'),
          ),
          FilledButton(
            onPressed: _callHttp,
            child: const Text('Call with http'),
          ),
          FilledButton(onPressed: _callDio, child: const Text('Call with Dio')),
          const SizedBox(height: 16),
          // Anything inside NabrilaMask is exported as a solid block, and taps
          // on it never get a label.
          const NabrilaMask(
            child: Card(
              child: ListTile(
                title: Text('Visa 4242 4242 4242 4242'),
                subtitle: Text('Ana Perez'),
              ),
            ),
          ),
          // The value of a text field is never recorded.
          const TextField(decoration: InputDecoration(labelText: 'Email')),
        ],
      ),
    );
  }
}
