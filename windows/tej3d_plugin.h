#ifndef FLUTTER_PLUGIN_TEJ3D_PLUGIN_H_
#define FLUTTER_PLUGIN_TEJ3D_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace tej3d {

class Tej3dPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  Tej3dPlugin();

  virtual ~Tej3dPlugin();

  // Disallow copy and assign.
  Tej3dPlugin(const Tej3dPlugin&) = delete;
  Tej3dPlugin& operator=(const Tej3dPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace tej3d

#endif  // FLUTTER_PLUGIN_TEJ3D_PLUGIN_H_
