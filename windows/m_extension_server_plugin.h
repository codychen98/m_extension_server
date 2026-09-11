#ifndef FLUTTER_PLUGIN_m_extension_server_PLUGIN_H_
#define FLUTTER_PLUGIN_m_extension_server_PLUGIN_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace m_extension_server {

class MExtensionServerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  MExtensionServerPlugin();
  ~MExtensionServerPlugin() override;

  MExtensionServerPlugin(const MExtensionServerPlugin&) = delete;
  MExtensionServerPlugin& operator=(const MExtensionServerPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  static constexpr size_t kMaxLogLines = 2000;

  HANDLE java_process_ = INVALID_HANDLE_VALUE;
  HANDLE stdout_read_ = INVALID_HANDLE_VALUE;
  std::thread log_reader_;
  std::mutex log_mutex_;
  std::deque<std::string> log_lines_;
  size_t dropped_lines_ = 0;

  void StopRunningProcess();
  void AppendLogLine(std::string line);
  void LogReaderLoop();
  void DrainServerLogs(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartServer(
      int port,
      const std::string& jvm_path,
      const std::string& server_jar_path,
      const std::vector<std::string>& jvm_args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StopServer(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace m_extension_server

#endif  // FLUTTER_PLUGIN_m_extension_server_PLUGIN_H_
