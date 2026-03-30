#ifndef PROVISIONING_H
#define PROVISIONING_H

#include <Arduino.h>

#include "node_storage.h"

void provisioningSetup();
bool shouldForceProvisioning();
bool runProvisioningPortal(NodeStoredConfig* config);

#endif
