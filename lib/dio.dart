/// Dio integration, kept in its own library so that apps without Dio never
/// import it: `import 'package:nabrila/dio.dart';`.
library;

export 'src/dio_interceptor.dart' show NabrilaDioInterceptor;
