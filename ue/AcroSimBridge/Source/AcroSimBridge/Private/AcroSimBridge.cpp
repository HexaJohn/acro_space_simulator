#include "Modules/ModuleManager.h"

// Module entry point. AcroSimBridge has no custom startup/shutdown logic — the
// default implementation just registers the module so UE can initialize it.
// (Without an IMPLEMENT_MODULE the .dll links but fails to load at runtime with
// "module could not be initialized successfully after it was loaded".)
IMPLEMENT_MODULE(FDefaultModuleImpl, AcroSimBridge);
