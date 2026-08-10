#include "wireguard_flutter_plugin.h"

// This must be included before many other Windows headers.
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/event_stream_handler_functions.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <windows.h>

#include <flutter/encodable_value.h>
#include <libbase64.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <memory>
#include <sstream>
#include <vector>

#include "config_writer.h"
#include "service_control.h"
#include "utils.h"

using namespace flutter;
using namespace std;

namespace wireguard_flutter
{

  namespace {
    bool ContainsCaseInsensitive(const std::string &haystack, const std::string &needle)
    {
      auto it = std::search(
          haystack.begin(), haystack.end(),
          needle.begin(), needle.end(),
          [](char ch1, char ch2)
          {
            return std::tolower(static_cast<unsigned char>(ch1)) ==
                   std::tolower(static_cast<unsigned char>(ch2));
          });
      return it != haystack.end();
    }

    std::string Trim(const std::string &s)
    {
      const char *whitespace = " \t\r\n";
      const auto begin = s.find_first_not_of(whitespace);
      if (begin == std::string::npos)
      {
        return "";
      }
      const auto end = s.find_last_not_of(whitespace);
      return s.substr(begin, end - begin + 1);
    }

    bool IsAmneziaConfig(const std::string &config)
    {
      static const char *kAmneziaKeys[] = {
          "\njc=", "\njmin=", "\njmax=", "\ns1=", "\ns2=", "\ns3=", "\ns4=",
          "\nh1=", "\nh2=", "\nh3=", "\nh4=", "\ni1=", "\ni2=", "\ni3=", "\ni4=", "\ni5="};

      std::string normalized = "\n" + config;
      for (const auto *key : kAmneziaKeys)
      {
        if (ContainsCaseInsensitive(normalized, key))
        {
          return true;
        }
      }
      return false;
    }

    bool FileExists(const std::wstring &path)
    {
      const DWORD attrs = GetFileAttributesW(path.c_str());
      return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
    }

    std::string NormalizeConfigForWindows(const std::string &raw_config)
    {
      std::istringstream input(raw_config);
      std::ostringstream out;
      std::string line;

      while (std::getline(input, line))
      {
        if (!line.empty() && line.back() == '\r')
        {
          line.pop_back();
        }

        const std::string trimmed = Trim(line);
        if (trimmed.empty())
        {
          out << "\r\n";
          continue;
        }

        if (trimmed[0] == '[' || trimmed[0] == '#' || trimmed[0] == ';')
        {
          out << trimmed << "\r\n";
          continue;
        }

        const auto eq = trimmed.find('=');
        if (eq == std::string::npos)
        {
          out << trimmed << "\r\n";
          continue;
        }

        const std::string key = Trim(trimmed.substr(0, eq));
        const std::string value = Trim(trimmed.substr(eq + 1));
        out << key << " = " << value << "\r\n";
      }

      return out.str();
    }

    std::string ExtractEndpointHost(const std::string &wg_config)
    {
      std::istringstream input(wg_config);
      std::string line;
      while (std::getline(input, line))
      {
        if (!line.empty() && line.back() == '\r')
        {
          line.pop_back();
        }

        const std::string trimmed = Trim(line);
        if (!ContainsCaseInsensitive(trimmed, "endpoint"))
        {
          continue;
        }

        const auto eq = trimmed.find('=');
        if (eq == std::string::npos)
        {
          continue;
        }

        std::string value = Trim(trimmed.substr(eq + 1));
        if (value.empty())
        {
          continue;
        }

        const auto hash = value.find('#');
        if (hash != std::string::npos)
        {
          value = Trim(value.substr(0, hash));
        }

        if (!value.empty() && value.front() == '[')
        {
          const auto close = value.find(']');
          if (close != std::string::npos)
          {
            return value.substr(1, close - 1);
          }
        }

        const auto colon = value.rfind(':');
        if (colon != std::string::npos)
        {
          return value.substr(0, colon);
        }

        return value;
      }

      return "";
    }

    bool ResolveIpv4Host(const std::string &host, std::string &out_ip)
    {
      addrinfo hints{};
      hints.ai_family = AF_INET;
      hints.ai_socktype = SOCK_DGRAM;
      hints.ai_protocol = IPPROTO_UDP;

      addrinfo *result = nullptr;
      if (getaddrinfo(host.c_str(), nullptr, &hints, &result) != 0 || result == nullptr)
      {
        return false;
      }

      auto *addr = reinterpret_cast<sockaddr_in *>(result->ai_addr);
      char ip_buf[INET_ADDRSTRLEN] = {};
      const char *ok = inet_ntop(AF_INET, &addr->sin_addr, ip_buf, INET_ADDRSTRLEN);
      freeaddrinfo(result);

      if (!ok)
      {
        return false;
      }

      out_ip = ip_buf;
      return true;
    }

    void EnsureEndpointBypassRoute(const std::string &endpoint_host)
    {
      if (endpoint_host.empty())
      {
        return;
      }

      std::string endpoint_ip;
      if (!ResolveIpv4Host(endpoint_host, endpoint_ip))
      {
        return;
      }

      in_addr dst_addr{};
      if (inet_pton(AF_INET, endpoint_ip.c_str(), &dst_addr) != 1)
      {
        return;
      }

      MIB_IPFORWARDROW best_route{};
      if (GetBestRoute(dst_addr.S_un.S_addr, 0, &best_route) != NO_ERROR)
      {
        return;
      }

      if (best_route.dwForwardNextHop == 0)
      {
        return;
      }

      in_addr gw_addr{};
      gw_addr.S_un.S_addr = best_route.dwForwardNextHop;
      char gw_buf[INET_ADDRSTRLEN] = {};
      if (inet_ntop(AF_INET, &gw_addr, gw_buf, INET_ADDRSTRLEN) == nullptr)
      {
        return;
      }

      std::ostringstream cmd;
      cmd << "cmd /C route DELETE " << endpoint_ip << " >NUL 2>&1 & "
          << "route ADD " << endpoint_ip << " MASK 255.255.255.255 " << gw_buf << " METRIC 1 >NUL 2>&1";
      std::system(cmd.str().c_str());
    }

    std::string ToUtf8Safe(const std::string &input)
    {
      auto continuation = [](unsigned char ch) {
        return (ch & 0xC0) == 0x80;
      };

      bool all_valid_utf8 = true;
      std::string out;
      out.reserve(input.size());

      for (size_t i = 0; i < input.size();)
      {
        const unsigned char c0 = static_cast<unsigned char>(input[i]);

        if (c0 <= 0x7F)
        {
          out.push_back(static_cast<char>(c0));
          ++i;
          continue;
        }

        if (c0 >= 0xC2 && c0 <= 0xDF)
        {
          if (i + 1 < input.size())
          {
            const unsigned char c1 = static_cast<unsigned char>(input[i + 1]);
            if (continuation(c1))
            {
              out.push_back(static_cast<char>(c0));
              out.push_back(static_cast<char>(c1));
              i += 2;
              continue;
            }
          }
          all_valid_utf8 = false;
          ++i;
          continue;
        }

        if (c0 >= 0xE0 && c0 <= 0xEF)
        {
          if (i + 2 < input.size())
          {
            const unsigned char c1 = static_cast<unsigned char>(input[i + 1]);
            const unsigned char c2 = static_cast<unsigned char>(input[i + 2]);
            const bool valid = continuation(c1) && continuation(c2) &&
                               !(c0 == 0xE0 && c1 < 0xA0) &&
                               !(c0 == 0xED && c1 >= 0xA0);
            if (valid)
            {
              out.push_back(static_cast<char>(c0));
              out.push_back(static_cast<char>(c1));
              out.push_back(static_cast<char>(c2));
              i += 3;
              continue;
            }
          }
          all_valid_utf8 = false;
          ++i;
          continue;
        }

        if (c0 >= 0xF0 && c0 <= 0xF4)
        {
          if (i + 3 < input.size())
          {
            const unsigned char c1 = static_cast<unsigned char>(input[i + 1]);
            const unsigned char c2 = static_cast<unsigned char>(input[i + 2]);
            const unsigned char c3 = static_cast<unsigned char>(input[i + 3]);
            const bool valid = continuation(c1) && continuation(c2) && continuation(c3) &&
                               !(c0 == 0xF0 && c1 < 0x90) &&
                               !(c0 == 0xF4 && c1 > 0x8F);
            if (valid)
            {
              out.push_back(static_cast<char>(c0));
              out.push_back(static_cast<char>(c1));
              out.push_back(static_cast<char>(c2));
              out.push_back(static_cast<char>(c3));
              i += 4;
              continue;
            }
          }
          all_valid_utf8 = false;
          ++i;
          continue;
        }

        all_valid_utf8 = false;
        ++i;
      }

      if (all_valid_utf8)
      {
        return input;
      }

      // Some Windows APIs/third-party code may still produce CP_ACP bytes.
      // Convert those bytes to UTF-8 so MethodChannel strings are readable in Dart.
      return WideToUtf8(AnsiToWide(input));
    }

  }

  // static
  void WireguardFlutterPlugin::RegisterWithRegistrar(PluginRegistrarWindows *registrar)
  {
    auto channel = make_unique<MethodChannel<EncodableValue>>(
        registrar->messenger(), "orban.group.wireguard_flutter_plus/wgcontrol", &StandardMethodCodec::GetInstance());
    auto eventChannel = make_unique<EventChannel<EncodableValue>>(
        registrar->messenger(), "orban.group.wireguard_flutter_plus/wgstage", &StandardMethodCodec::GetInstance());

    auto plugin = make_unique<WireguardFlutterPlugin>();

    channel->SetMethodCallHandler([plugin_pointer = plugin.get()](const auto &call, auto result)
                                  { plugin_pointer->HandleMethodCall(call, move(result)); });

    auto eventsHandler = make_unique<StreamHandlerFunctions<EncodableValue>>(
        [plugin_pointer = plugin.get()](
            const EncodableValue *arguments,
            unique_ptr<EventSink<EncodableValue>> &&events)
            -> unique_ptr<StreamHandlerError<EncodableValue>>
        {
          return plugin_pointer->OnListen(arguments, move(events));
        },
        [plugin_pointer = plugin.get()](const EncodableValue *arguments)
            -> unique_ptr<StreamHandlerError<EncodableValue>>
        {
          return plugin_pointer->OnCancel(arguments);
        });

    eventChannel->SetStreamHandler(move(eventsHandler));

    auto trafficEventChannel = make_unique<EventChannel<EncodableValue>>(
        registrar->messenger(), "orban.group.wireguard_flutter_plus/traffic", &StandardMethodCodec::GetInstance());

    auto trafficEventsHandler = make_unique<StreamHandlerFunctions<EncodableValue>>(
        [plugin_pointer = plugin.get()](
            const EncodableValue *arguments,
            unique_ptr<EventSink<EncodableValue>> &&events)
            -> unique_ptr<StreamHandlerError<EncodableValue>>
        {
          return plugin_pointer->OnTrafficListen(arguments, move(events));
        },
        [plugin_pointer = plugin.get()](const EncodableValue *arguments)
            -> unique_ptr<StreamHandlerError<EncodableValue>>
        {
          return plugin_pointer->OnTrafficCancel(arguments);
        });

    trafficEventChannel->SetStreamHandler(move(trafficEventsHandler));

    registrar->AddPlugin(move(plugin));
  }

  static WireguardFlutterPlugin* g_plugin_instance = nullptr;

  WireguardFlutterPlugin::WireguardFlutterPlugin() {
    g_plugin_instance = this;
  }

  WireguardFlutterPlugin::~WireguardFlutterPlugin() {
    if (g_plugin_instance == this) {
      g_plugin_instance = nullptr;
    }
  }

  void CALLBACK WireguardFlutterPlugin::TimerProc(HWND hwnd, UINT uMsg, UINT_PTR idEvent, DWORD dwTime) {
      if (g_plugin_instance) {
          g_plugin_instance->ProcessTrafficStats();
      }
  }

  void WireguardFlutterPlugin::ProcessTrafficStats() {
      if (!traffic_events_) {
          // std::cout << "Traffic events sink is null" << std::endl;
          return;
      }

      auto tunnel_service = this->tunnel_service_.get();
      if (!tunnel_service) {
         // std::cout << "Tunnel service is null" << std::endl;
         return;
      }

      std::wstring service_name_wide = tunnel_service->service_name_;
      
      NET_LUID luid;
      if (ConvertInterfaceAliasToLuid(service_name_wide.c_str(), &luid) != NO_ERROR) {
          // Fallback: Try WireGuardTunnel$NAME
          std::wstring fallback_name = L"WireGuardTunnel$" + service_name_wide;
          if (ConvertInterfaceAliasToLuid(fallback_name.c_str(), &luid) != NO_ERROR) {
          //   std::cout << "Failed to convert alias to LUID for service: " << WideToUtf8(service_name_wide) << " or " << WideToUtf8(fallback_name) << std::endl;
            
          //   // List all interfaces to debug (only once every 10 seconds to avoid spam)
          //   static DWORD last_print = 0;
          //   if (GetTickCount() - last_print > 10000) {
          //       last_print = GetTickCount();
          //       PMIB_IF_TABLE2 pIfTable;
          //       if (GetIfTable2(&pIfTable) == NO_ERROR) {
          //           std::cout << "Available Interfaces:" << std::endl;
          //           for (ULONG i = 0; i < pIfTable->NumEntries; i++) {
          //               std::cout << " - " << WideToUtf8(pIfTable->Table[i].Alias) << std::endl;
          //           }
          //           FreeMibTable(pIfTable);
          //       } else {
          //           std::cout << "Failed to list interfaces" << std::endl;
          //       }
          //   }
            return;
          } else {
             // std::cout << "Found LUID using fallback name: " << WideToUtf8(fallback_name) << std::endl;
          }
      }

      MIB_IF_ROW2 row;
      SecureZeroMemory(&row, sizeof(MIB_IF_ROW2));
      row.InterfaceLuid = luid;
      
      if (GetIfEntry2(&row) != NO_ERROR) {
          // std::cout << "Failed to get interface entry for LUID" << std::endl;
          return;
      }

      unsigned long long current_rx = row.InOctets;
      unsigned long long current_tx = row.OutOctets;

      unsigned long long download_speed = (current_rx >= last_rx_) ? (current_rx - last_rx_) : 0;
      unsigned long long upload_speed = (current_tx >= last_tx_) ? (current_tx - last_tx_) : 0;

      // Filter out huge spikes (e.g., initial read)
      if (last_rx_ == 0 && last_tx_ == 0) {
          download_speed = 0;
          upload_speed = 0;
      }

      // std::cout << "Traffic Stats - DL: " << download_speed << ", UL: " << upload_speed 
      //           << ", TotalDL: " << current_rx << ", TotalUL: " << current_tx << std::endl;

      last_rx_ = current_rx;
      last_tx_ = current_tx;

      unsigned long long duration_seconds = 0;
      if (start_time_ > 0) {
          unsigned long long now = GetTickCount64();
          if (now >= start_time_) {
              duration_seconds = (now - start_time_) / 1000;
          }
      }

      // Format duration HH:MM:SS
      char duration_str[32];
      sprintf_s(duration_str, "%02llu:%02llu:%02llu", 
          duration_seconds / 3600, 
          (duration_seconds % 3600) / 60, 
          duration_seconds % 60);

      flutter::EncodableMap map;
      map[flutter::EncodableValue("downloadSpeed")] = flutter::EncodableValue((int64_t)download_speed);
      map[flutter::EncodableValue("uploadSpeed")] = flutter::EncodableValue((int64_t)upload_speed);
      map[flutter::EncodableValue("totalDownload")] = flutter::EncodableValue((int64_t)current_rx);
      map[flutter::EncodableValue("totalUpload")] = flutter::EncodableValue((int64_t)current_tx);
      map[flutter::EncodableValue("duration")] = flutter::EncodableValue(std::string(duration_str));

      traffic_events_->Success(flutter::EncodableValue(map));
  }

  void WireguardFlutterPlugin::HandleMethodCall(const MethodCall<EncodableValue> &call,
                                                unique_ptr<MethodResult<EncodableValue>> result)
  {
    const auto *args = get_if<EncodableMap>(call.arguments());

    // std::cout << "HandleMethodCall: " << call.method_name() << std::endl;

    if (call.method_name() == "initialize")
    {
      const auto *arg_service_name = get_if<string>(ValueOrNull(*args, "win32ServiceName"));
      if (arg_service_name == NULL)
      {
        result->Error("Argument 'win32ServiceName' is required");
        return;
      }
      if (this->tunnel_service_ != nullptr)
      {
        this->tunnel_service_->service_name_ = Utf8ToWide(*arg_service_name);
      }
      else
      {
        this->tunnel_service_ = make_unique<ServiceControl>(Utf8ToWide(*arg_service_name));
        this->tunnel_service_->RegisterListener(move(events_));
      }

      result->Success();
      return;
    }
    else if (call.method_name() == "start")
    {
      // std::cout << "Method 'start' called" << std::endl;
      auto tunnel_service = this->tunnel_service_.get();
      if (tunnel_service == nullptr)
      {
        result->Error("Invalid state: call 'initialize' first");
        return;
      }
      const auto *wgQuickConfig = get_if<string>(ValueOrNull(*args, "wgQuickConfig"));
      if (wgQuickConfig == NULL)
      {
        result->Error("Argument 'wgQuickConfig' is required");
        return;
      }

      wchar_t module_filename[MAX_PATH];
      GetModuleFileName(NULL, module_filename, MAX_PATH);
      auto current_exec_dir = wstring(module_filename);
      current_exec_dir = current_exec_dir.substr(0, current_exec_dir.find_last_of(L"\\/"));

      const bool is_amnezia = IsAmneziaConfig(*wgQuickConfig);

      this->tunnel_service_->EmitState("prepare");

      wstring wg_config_filename;
      try
      {
        const std::string endpoint_host = ExtractEndpointHost(*wgQuickConfig);
        EnsureEndpointBypassRoute(endpoint_host);

        const std::string normalized_config = NormalizeConfigForWindows(*wgQuickConfig);
        wg_config_filename = WriteConfigToTempFile(normalized_config, WideToUtf8(tunnel_service->service_name_));
      }
      catch (exception &e)
      {
        this->tunnel_service_->EmitState("no_connection");
        result->Error("WRITE_CONFIG_FAILED", string("Could not write wireguard config: ").append(ToUtf8Safe(e.what())));
        return;
      }

      std::vector<std::wstring> service_exec_candidates;

      auto add_legacy_service_candidate = [&](const std::wstring &exe_name)
      {
        const std::wstring base = current_exec_dir + L"\\" + exe_name;
        if (FileExists(base))
        {
          service_exec_candidates.push_back(base + L" -service -config-file=\"" + wg_config_filename + L"\"");
        }
      };

      if (is_amnezia)
      {
        const std::wstring amneziawg = current_exec_dir + L"\\amneziawg.exe";
        if (FileExists(amneziawg))
        {
          // amneziawg.exe supports Windows service mode via /tunnelservice CONFIG_PATH.
          service_exec_candidates.push_back(amneziawg + L" /tunnelservice \"" + wg_config_filename + L"\"");
        }
      }

      add_legacy_service_candidate(L"wireguard_svc.exe");

      std::string last_start_error;
      try
      {
        bool started = false;
        for (const auto &service_exec : service_exec_candidates)
        {
          try
          {
            CreateArgs csa;
            csa.description = tunnel_service->service_name_ + L" WireGuard tunnel";
            csa.executable_and_args = service_exec;
            csa.dependencies = L"Nsi\0TcpIp\0";

            tunnel_service->CreateAndStart(csa);
            started = true;
            break;
          }
          catch (exception &e)
          {
            last_start_error = ToUtf8Safe(e.what());
          }
        }

        if (!started)
        {
          throw runtime_error(last_start_error.empty() ? "Failed to start tunnel service" : last_start_error);
        }
        
        // Timer logic: Reset start time and traffic counters on successful start
        start_time_ = GetTickCount64();
        last_rx_ = 0;
        last_tx_ = 0;
      }
      catch (exception &e)
      {
        // std::cout << "Failed to start service: " << e.what() << std::endl;
        result->Error("SERVICE_START_FAILED", ToUtf8Safe(e.what()));
        return;
      }

      result->Success();
      return;
    }
    else if (call.method_name() == "stop")
    {
      auto tunnel_service = this->tunnel_service_.get();
      if (tunnel_service == nullptr)
      {
        result->Error("Invalid state: call 'initialize' first");
        return;
      }

      try
      {
        tunnel_service->Stop();
        
        // Timer logic: Reset start time on stop
        start_time_ = 0;
        last_rx_ = 0;
        last_tx_ = 0;
      }
      catch (exception &e)
      {
        result->Error("SERVICE_STOP_FAILED", ToUtf8Safe(e.what()));
      }

      result->Success();
      return;
    }
    else if (call.method_name() == "stage")
    {
      auto tunnel_service = this->tunnel_service_.get();
      if (tunnel_service == nullptr)
      {
        result->Success(EncodableValue("disconnected"));
        return;
      }

      result->Success(EncodableValue(tunnel_service->GetStatus()));
      return;
    }

    result->NotImplemented();
  }

  unique_ptr<StreamHandlerError<EncodableValue>> WireguardFlutterPlugin::OnListen(
      const EncodableValue *arguments,
      unique_ptr<EventSink<EncodableValue>> &&events)
  {
    events_ = move(events);
    auto tunnel_service = this->tunnel_service_.get();
    if (tunnel_service != nullptr)
    {
      tunnel_service->RegisterListener(move(events_));
      return nullptr;
    }

    return nullptr;
  }

  unique_ptr<StreamHandlerError<EncodableValue>> WireguardFlutterPlugin::OnCancel(
      const EncodableValue *arguments)
  {
    events_ = nullptr;
    auto tunnel_service = this->tunnel_service_.get();
    if (tunnel_service != nullptr)
    {
      tunnel_service->UnregisterListener();
      return nullptr;
    }

    return nullptr;
  }

  unique_ptr<StreamHandlerError<EncodableValue>> WireguardFlutterPlugin::OnTrafficListen(
      const EncodableValue *arguments,
      unique_ptr<EventSink<EncodableValue>> &&events)
  {
    traffic_events_ = move(events);
    last_rx_ = 0;
    last_tx_ = 0;
    
    // Check if valid start time can be retrieved
    if (this->tunnel_service_) {
       int64_t service_start = this->tunnel_service_->GetServiceStartTime();
       if (service_start > 0) {
           start_time_ = service_start;
       } else {
           // If service is not running or can't get time, ensure start_time is 0
           // But if we just started via 'start' method, start_time_ might be set already?
           // Actually OnTrafficListen is traffic snapshot subscription.
           // If we are already connected, we want to restore start_time_.
           if (start_time_ == 0) start_time_ = 0; 
       }
    }

    // Start timer with 1000ms interval
    timer_id_ = SetTimer(NULL, 0, 1000, &WireguardFlutterPlugin::TimerProc);
    
    return nullptr;
  }

  unique_ptr<StreamHandlerError<EncodableValue>> WireguardFlutterPlugin::OnTrafficCancel(
      const EncodableValue *arguments)
  {
    if (timer_id_) {
        KillTimer(NULL, timer_id_);
        timer_id_ = 0;
    }
    traffic_events_ = nullptr;
    return nullptr;
  }


} // namespace wireguard_flutter
