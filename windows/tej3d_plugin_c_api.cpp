#include "include/tej3d/tej3d_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tej3d_plugin.h"

void Tej3dPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tej3d::Tej3dPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
