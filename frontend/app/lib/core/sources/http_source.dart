import 'package:app/core/sources/source.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/gen/openapi_client/lib/api.dart';
import 'package:app/core/commands/command_executor.dart';

/// Abstract base class for standard HTTP REST data sources.
abstract class HttpSource<T, ClientType> extends DataSource<T>
    with CommandExecutor<List<T>, ClientType> {

  final ClientType apiClient;

  HttpSource(this.apiClient);

  // ---------------------------- Factory ---------------------------------------------------

  /// Instantiates an [HttpSource] subtype using the OpenAPI [ApiClient] from [AppNetwork].
  static S create<S extends HttpSource>(
    AppNetwork appNetwork,
    S Function(ApiClient apiClient) sourceFactory,
  ) =>
      sourceFactory(appNetwork.httpService.client);
}
