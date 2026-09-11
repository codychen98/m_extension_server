import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'm_extension_server_platform_interface.dart';

/// An implementation of [MExtensionServerPlatform] that uses method channels.
class MethodChannelMExtensionServer extends MExtensionServerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('m_extension_server');

  @override
  Future<String?> startServer(
    int port, {
    String? jvmPath,
    String? serverJarPath,
    List<String>? jvmArgs,
  }) async {
    final result = await methodChannel.invokeMethod<String>('startServer', {
      'port': port,
      if (jvmPath != null) 'jvmPath': jvmPath,
      if (serverJarPath != null) 'serverJarPath': serverJarPath,
      if (jvmArgs != null && jvmArgs.isNotEmpty) 'jvmArgs': jvmArgs,
    });
    return result;
  }

  @override
  Future<String?> stopServer() async {
    final result = await methodChannel.invokeMethod<String>('stopServer');
    return result;
  }

  @override
  Future<List<String>> drainServerLogs() async {
    try {
      final result =
          await methodChannel.invokeMethod<List<dynamic>>('drainServerLogs');
      if (result == null) {
        return const <String>[];
      }
      return result.map((e) => e.toString()).toList(growable: false);
    } on MissingPluginException {
      return const <String>[];
    } on PlatformException catch (e) {
      if (e.code == 'notImplemented' || e.code == 'UnimplementedError') {
        return const <String>[];
      }
      rethrow;
    }
  }
}
