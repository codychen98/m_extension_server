#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "include/m_extension_server/m_extension_server_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// POSIX process management
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstring>
#include <deque>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "m_extension_server_plugin_private.h"

#define m_extension_server_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), m_extension_server_plugin_get_type(), \
                              MExtensionServerPlugin))

static constexpr size_t kMaxLogLines = 2000;

struct _MExtensionServerPlugin {
  GObject parent_instance;
  pid_t java_pid;
  int stdout_fd;
  std::thread* log_reader;
  std::mutex* log_mutex;
  std::deque<std::string>* log_lines;
  size_t dropped_lines;
};

G_DEFINE_TYPE(MExtensionServerPlugin, m_extension_server_plugin,
              g_object_get_type())

static FlMethodResponse* start_server(MExtensionServerPlugin* self,
                                      FlValue* args);
static FlMethodResponse* stop_server(MExtensionServerPlugin* self);
static FlMethodResponse* drain_server_logs(MExtensionServerPlugin* self);
static void stop_running_process(MExtensionServerPlugin* self);
static void append_log_line(MExtensionServerPlugin* self, std::string line);
static void log_reader_loop(MExtensionServerPlugin* self);

static const gchar* get_string_arg(FlValue* args, const gchar* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(v);
}

static int get_int_arg(FlValue* args, const gchar* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return -1;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_INT) return -1;
  return static_cast<int>(fl_value_get_int(v));
}

static std::vector<std::string> get_string_list_arg(FlValue* args,
                                                    const gchar* key) {
  std::vector<std::string> out;
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return out;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_LIST) return out;
  const size_t len = fl_value_get_length(v);
  out.reserve(len);
  for (size_t i = 0; i < len; ++i) {
    FlValue* item = fl_value_get_list_value(v, i);
    if (item && fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      out.emplace_back(fl_value_get_string(item));
    }
  }
  return out;
}

static void m_extension_server_plugin_handle_method_call(
    MExtensionServerPlugin* self,
    FlMethodCall* method_call) {

  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "startServer") == 0) {
    response = start_server(self, args);
  } else if (strcmp(method, "stopServer") == 0) {
    response = stop_server(self);
  } else if (strcmp(method, "drainServerLogs") == 0) {
    response = drain_server_logs(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void append_log_line(MExtensionServerPlugin* self, std::string line) {
  std::lock_guard<std::mutex> lock(*self->log_mutex);
  while (self->log_lines->size() >= kMaxLogLines) {
    self->log_lines->pop_front();
    ++self->dropped_lines;
  }
  self->log_lines->push_back(std::move(line));
}

static void log_reader_loop(MExtensionServerPlugin* self) {
  char buf[4096];
  std::string pending;

  for (;;) {
    const int fd = self->stdout_fd;
    if (fd < 0) {
      break;
    }
    const ssize_t n = read(fd, buf, sizeof(buf));
    if (n <= 0) {
      break;
    }
    for (ssize_t i = 0; i < n; ++i) {
      const char c = buf[i];
      if (c == '\n') {
        if (!pending.empty() && pending.back() == '\r') {
          pending.pop_back();
        }
        append_log_line(self, std::move(pending));
        pending.clear();
      } else {
        pending.push_back(c);
      }
    }
  }

  if (!pending.empty()) {
    if (pending.back() == '\r') {
      pending.pop_back();
    }
    append_log_line(self, std::move(pending));
  }
}

static FlMethodResponse* drain_server_logs(MExtensionServerPlugin* self) {
  std::deque<std::string> drained;
  size_t dropped = 0;
  {
    std::lock_guard<std::mutex> lock(*self->log_mutex);
    drained.swap(*self->log_lines);
    dropped = self->dropped_lines;
    self->dropped_lines = 0;
  }

  g_autoptr(FlValue) list = fl_value_new_list();
  if (dropped > 0) {
    g_autofree gchar* msg =
        g_strdup_printf("[m_extension_server] dropped %zu lines", dropped);
    fl_value_append_take(list, fl_value_new_string(msg));
  }
  for (const auto& line : drained) {
    fl_value_append_take(list, fl_value_new_string(line.c_str()));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
}

static void stop_running_process(MExtensionServerPlugin* self) {
  if (self->java_pid > 0) {
    kill(self->java_pid, SIGTERM);

    for (int i = 0; i < 50; ++i) {
      int status = 0;
      const pid_t ret = waitpid(self->java_pid, &status, WNOHANG);
      if (ret == self->java_pid) {
        break;
      }
      g_usleep(100000);  // 100 ms
    }

    if (waitpid(self->java_pid, nullptr, WNOHANG) == 0) {
      kill(self->java_pid, SIGKILL);
      waitpid(self->java_pid, nullptr, 0);
    }

    self->java_pid = 0;
  }

  if (self->stdout_fd >= 0) {
    close(self->stdout_fd);
    self->stdout_fd = -1;
  }

  if (self->log_reader != nullptr) {
    if (self->log_reader->joinable()) {
      self->log_reader->join();
    }
    delete self->log_reader;
    self->log_reader = nullptr;
  }
}

static FlMethodResponse* start_server(MExtensionServerPlugin* self,
                                      FlValue* args) {
  const gchar* jvm_path_arg = get_string_arg(args, "jvmPath");
  const gchar* jar_path_arg = get_string_arg(args, "serverJarPath");
  const int port = get_int_arg(args, "port");
  const std::vector<std::string> jvm_args =
      get_string_list_arg(args, "jvmArgs");

  if (port <= 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing or invalid 'port' argument", nullptr));
  }
  if (!jar_path_arg || strlen(jar_path_arg) == 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS",
        "Missing 'serverJarPath' argument – required on Linux", nullptr));
  }

  stop_running_process(self);

  const std::string java_exe =
      (jvm_path_arg && strlen(jvm_path_arg) > 0)
          ? std::string(jvm_path_arg)
          : std::string("java");

  const std::string jar_path(jar_path_arg);
  const std::string port_str = std::to_string(port);

  std::vector<std::string> argv_storage;
  argv_storage.reserve(3 + jvm_args.size());
  argv_storage.push_back(java_exe);
  for (const auto& arg : jvm_args) {
    argv_storage.push_back(arg);
  }
  argv_storage.push_back("-jar");
  argv_storage.push_back(jar_path);
  argv_storage.push_back(port_str);

  std::vector<char*> argv;
  argv.reserve(argv_storage.size() + 1);
  for (auto& s : argv_storage) {
    argv.push_back(s.data());
  }
  argv.push_back(nullptr);

  int fds[2] = {-1, -1};
  if (pipe2(fds, O_CLOEXEC) < 0) {
    g_autofree gchar* msg =
        g_strdup_printf("pipe2() failed: %s", strerror(errno));
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("START_ERROR", msg, nullptr));
  }

  const pid_t pid = fork();
  if (pid < 0) {
    close(fds[0]);
    close(fds[1]);
    g_autofree gchar* msg =
        g_strdup_printf("fork() failed: %s", strerror(errno));
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("START_ERROR", msg, nullptr));
  }

  if (pid == 0) {
    close(fds[0]);
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    close(fds[1]);
    execvp(java_exe.c_str(), argv.data());
    _exit(127);
  }

  close(fds[1]);
  self->java_pid = pid;
  self->stdout_fd = fds[0];
  self->log_reader = new std::thread(log_reader_loop, self);

  g_autofree gchar* ok_msg =
      g_strdup_printf("Server started on port %d", port);
  g_autoptr(FlValue) result = fl_value_new_string(ok_msg);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* stop_server(MExtensionServerPlugin* self) {
  if (self->java_pid <= 0) {
    g_autoptr(FlValue) result =
        fl_value_new_string("Server was not running");
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  stop_running_process(self);

  g_autoptr(FlValue) result = fl_value_new_string("Server stopped");
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void m_extension_server_plugin_dispose(GObject* object) {
  MExtensionServerPlugin* self = m_extension_server_PLUGIN(object);
  stop_running_process(self);
  delete self->log_mutex;
  self->log_mutex = nullptr;
  delete self->log_lines;
  self->log_lines = nullptr;
  G_OBJECT_CLASS(m_extension_server_plugin_parent_class)->dispose(object);
}

static void m_extension_server_plugin_class_init(
    MExtensionServerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = m_extension_server_plugin_dispose;
}

static void m_extension_server_plugin_init(MExtensionServerPlugin* self) {
  self->java_pid = 0;
  self->stdout_fd = -1;
  self->log_reader = nullptr;
  self->log_mutex = new std::mutex();
  self->log_lines = new std::deque<std::string>();
  self->dropped_lines = 0;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  MExtensionServerPlugin* plugin = m_extension_server_PLUGIN(user_data);
  m_extension_server_plugin_handle_method_call(plugin, method_call);
}

void m_extension_server_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  MExtensionServerPlugin* plugin = m_extension_server_PLUGIN(
      g_object_new(m_extension_server_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "m_extension_server",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
