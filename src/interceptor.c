#include <dlfcn.h>
#include <stdio.h>

typedef void *(create_interface_t)(const char *pName, int *pReturnCode);

void *CreateInterface(const char *pName, int *pReturnCode) {
  void *dll = dlopen("tf/bin/server_srv.so", RTLD_NOW);
  printf("ok");
  create_interface_t *func = (create_interface_t*)dlsym(dll, "CreateInterface");
  return func(pName, pReturnCode);
}
