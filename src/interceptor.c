#include <dlfcn.h>
#include <stdio.h>

/// Normally, x86_32 Source builds do not create any platform-specific folders in bin/,
/// so we can check it first. This is much easier than nesting it
#if defined (__i386__)
const char relative_path[] = "tf/bin/server_srv.so";
#elif defined (__linux__)
const char relative_path[] = "tf/bin/linux64/server_srv.so";
#endif

typedef void *(create_interface_t)(const char *pName, int *pReturnCode);

/// @brief The fake CreateInterface, which SDK tries to call
/// @note Do not close the dll, or it will cause a segfault
void *CreateInterface(const char *pName, int *pReturnCode) {
  void *dll = dlopen(relative_path, RTLD_NOW);
  create_interface_t *func = (create_interface_t*)dlsym(dll, "CreateInterface");
  return func(pName, pReturnCode);
}

/// As we (or I) currently focus on TF2 branch, here's what SDK wants from CreateInterface:
/*
  ServerGameDLL012
  ServerGameEnts001
  ServerGameClients005
  HLTVDirector001
  ServerGameTags001
  PluginHelpersCheck001
  ServerReplay001
 */
