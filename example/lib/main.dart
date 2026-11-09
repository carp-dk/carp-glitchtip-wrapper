import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// The app's state, like the BLoC of a CARP app: it knows which study the
/// participant is in and notifies its listeners when that changes.
class StudyState extends ChangeNotifier {
  StudyMetadata? _study;

  /// The study the participant is in, if any.
  StudyMetadata? get study => _study;

  void join() {
    _study = const StudyMetadata(
      studyId: 'b7c3e0d2-8f5a-4e2b-9c1d-3a6f0e9b2c4d',
      studyDeploymentId: '1f2e3d4c-5b6a-4978-8a9b-0c1d2e3f4a5b',
      deviceRoleName: 'Primary phone',
    );
    notifyListeners();
  }

  void leave() {
    _study = null;
    notifyListeners();
  }
}

final state = StudyState();

/// The whole body of `main()` runs inside [CarpGlitchTip.runZoned], so every
/// `http.Client()` of the app and its packages records its requests.
Future<void> main() => CarpGlitchTip.runZoned(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CarpGlitchTip.init(
    CarpGlitchTipOptions(
      ignoreErrors: [IgnoreRule.message('expected in this example')],
    ),
  );
  CarpGlitchTip.bindStudy(state, () => state.study);
  await CarpGlitchTip.trace('example.startup', () async {
    // e.g. the app's bloc.initialize()
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  runApp(const ExampleApp());
});

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CARP GlitchTip',
    navigatorObservers: [CarpGlitchTip.navigatorObserver()],
    home: const HomePage(),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _request(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // created inside the zone, so this request is recorded
      final response = await http.get(Uri.parse(url));
      messenger.showSnackBar(
        SnackBar(content: Text('HTTP ${response.statusCode}')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('CARP GlitchTip')),
    body: ListenableBuilder(
      listenable: state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${CarpGlitchTip.status}'),
          const SizedBox(height: 16),
          Text('Study: ${state.study?.studyDeploymentId ?? 'none'}'),
          FilledButton(
            onPressed: state.study == null ? state.join : state.leave,
            child: Text(state.study == null ? 'Join study' : 'Leave study'),
          ),
          const Divider(height: 32),
          OutlinedButton(
            onPressed: () => _request(
              context,
              'https://jsonplaceholder.typicode.com/posts/1?token=secret',
            ),
            child: const Text('Request (recorded, query not sent)'),
          ),
          OutlinedButton(
            onPressed: () =>
                _request(context, 'https://does-not-exist.invalid/api/data'),
            child: const Text('Request to an invalid domain (ignored)'),
          ),
          OutlinedButton(
            onPressed: () => throw StateError('expected in this example'),
            child: const Text('Throw an ignored error'),
          ),
          OutlinedButton(
            onPressed: () => throw StateError('Something went wrong'),
            child: const Text('Throw an unhandled error'),
          ),
          OutlinedButton(
            onPressed: () => CarpGlitchTip.captureException(
              FormatException('A caught error'),
              stackTrace: StackTrace.current,
            ),
            child: const Text('Report a caught error'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(
                  name: '/details',
                  arguments: {'participant': 'never recorded'},
                ),
                builder: (_) => const DetailsPage(),
              ),
            ),
            child: const Text('Open a page (navigation breadcrumb)'),
          ),
        ],
      ),
    ),
  );
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Details')),
    body: const Center(child: Text('Go back to record a pop.')),
  );
}
