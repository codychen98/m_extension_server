import 'package:flutter/services.dart';

import 'm_extension_server_platform_interface.dart';

class MExtensionServer {
  /// Starts the HTTP extension server on [port].
  ///
  /// See [MExtensionServerPlatform.startServer] for full per-platform
  /// documentation of every parameter.
  ///
  /// Quick reference:
  /// * **Android** — no extra parameters needed.
  /// * **Windows / Linux / macOS** — provide [serverJarPath] (and optionally
  ///   [jvmPath] / [jvmArgs]).
  Future<String?> startServer(
    int port, {
    String? jvmPath, // desktop only
    String? serverJarPath, // desktop only
    List<String>? jvmArgs, // desktop only
  }) {
    return MExtensionServerPlatform.instance.startServer(
      port,
      jvmPath: jvmPath,
      serverJarPath: serverJarPath,
      jvmArgs: jvmArgs,
    );
  }

  Future<String?> stopServer() {
    return MExtensionServerPlatform.instance.stopServer();
  }

  /// Drains buffered JVM stdout/stderr lines from the desktop launcher.
  ///
  /// See [MExtensionServerPlatform.drainServerLogs]. Treats
  /// [MissingPluginException] / unimplemented hosts as an empty list.
  Future<List<String>> drainServerLogs() async {
    try {
      return await MExtensionServerPlatform.instance.drainServerLogs();
    } on MissingPluginException {
      return const <String>[];
    } on UnimplementedError {
      return const <String>[];
    } on PlatformException catch (e) {
      if (e.code == 'notImplemented' || e.code == 'UnimplementedError') {
        return const <String>[];
      }
      rethrow;
    }
  }
}
