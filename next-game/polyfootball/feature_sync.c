// feature_sync — v1e: server-sync short-circuit (diagnostic-only pass).
//
// Concern: MultiplayerProfileSaveManager serialises local save data,
// POSTs it to a backend, and APPLIES the server-canonical response on
// return — which can overwrite flags we just toggled (e.g. UnlockPro).
// Before we try to short-circuit anything, we need to see what methods
// the manager actually exposes and whether live instances exist.
//
// v1e here is enumerate-and-log only: no invokes of manager methods.
// The next iteration will pick the right Apply/Deserialize method to
// hook once Steve has looked at the log.

#include "features.h"
#include <string.h>

static Il2CppClass *g_manager_class = NULL;
static Il2CppClass *g_envelope_class = NULL;
static Il2CppClass *g_savedata_class = NULL;
static Il2CppClass *g_httpresult_class = NULL;

static int init(void) {
    g_manager_class    = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "MultiplayerProfileSaveManager");
    g_envelope_class   = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "MultiplayerProfileEnvelope");
    g_savedata_class   = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "MultiplayerProfileSaveData");
    g_httpresult_class = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "HttpResult");

    if (!g_manager_class) {
        pfp_log("sync: MultiplayerProfileSaveManager not found — class name may have drifted");
        return -1;
    }
    int mc = pfp_il2cpp_count_methods(g_manager_class);
    pfp_log("sync: MultiplayerProfileSaveManager class=%p method_count=%d (catalog expects 26)",
            (void *)g_manager_class, mc);
    pfp_log("sync: MultiplayerProfileEnvelope class=%p", (void *)g_envelope_class);
    pfp_log("sync: MultiplayerProfileSaveData class=%p", (void *)g_savedata_class);
    pfp_log("sync: HttpResult class=%p", (void *)g_httpresult_class);

    // Enumerate manager methods matching the apply/serialise surface so the
    // v1e.1 implementation can pick the right one to short-circuit.
    static const char *substrs[] = {
        "Apply", "Save", "Load", "Post",
        "Upload", "Download", "Sync",
        "Serialize", "Deserialize",
    };
    pfp_diag_log_methods("sync", g_manager_class, substrs,
                         (int)(sizeof(substrs) / sizeof(substrs[0])));

    // Walk heap once for live instances across the three relevant classes.
    Il2CppClass *targets[3];
    int n = 0;
    if (g_manager_class)  targets[n++] = g_manager_class;
    if (g_envelope_class) targets[n++] = g_envelope_class;
    if (g_savedata_class) targets[n++] = g_savedata_class;
    if (n > 0) {
        pfp_diag_log_live_instances("sync", targets, n);
    }

    return 0;
}

static int tick(void) {
    // Diagnostic only: nothing per-tick until we pick the Apply method.
    return 0;
}

PfpFeature pfp_feature_sync = { "sync", init, tick, 0, 0, 0, 0 };
