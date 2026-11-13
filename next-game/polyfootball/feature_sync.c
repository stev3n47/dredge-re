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
    // Critic 3: HttpResult likely lives in a shared networking DLL, not
    // Assembly-CSharp. Search any image.
    g_httpresult_class = pfp_il2cpp_find_class(NULL, NULL, "HttpResult");

    // Critic 3: log every class pointer UNCONDITIONALLY — don't early-return
    // on manager miss. Missing one class is still useful diagnostic signal.
    pfp_log("sync: MultiplayerProfileSaveManager=%p MultiplayerProfileEnvelope=%p "
            "MultiplayerProfileSaveData=%p HttpResult=%p",
            (void *)g_manager_class, (void *)g_envelope_class,
            (void *)g_savedata_class, (void *)g_httpresult_class);
    if (g_manager_class) {
        int mc = pfp_il2cpp_count_methods(g_manager_class);
        pfp_log("sync: MultiplayerProfileSaveManager method_count=%d (catalog=26)", mc);
    }

    // Critic 3: dump apply-shaped methods on ALL THREE candidate classes,
    // not just the manager. Unity's envelope pattern often puts the
    // deserialise/apply logic on the envelope or on the savedata class.
    // Also add async-callback shapes — the real overwrite often fires from
    // a callback named `<Apply>b__12_0` or `OnReceived`.
    static const char *substrs[] = {
        "Apply", "Save", "Load", "Post",
        "Upload", "Download", "Sync",
        "Serialize", "Deserialize",
        "Callback", "OnResponse", "OnReceived", "Reply", "Response",
    };
    int nsub = (int)(sizeof(substrs) / sizeof(substrs[0]));
    if (g_manager_class)  pfp_diag_log_methods("sync", g_manager_class, substrs, nsub);
    if (g_envelope_class) pfp_diag_log_methods("sync", g_envelope_class, substrs, nsub);
    if (g_savedata_class) pfp_diag_log_methods("sync", g_savedata_class, substrs, nsub);

    // Walk heap once for live instances across the three relevant classes
    // (HttpResult is a short-lived call-wrapper; not worth walking).
    Il2CppClass *targets[3];
    int n = 0;
    if (g_manager_class)  targets[n++] = g_manager_class;
    if (g_envelope_class) targets[n++] = g_envelope_class;
    if (g_savedata_class) targets[n++] = g_savedata_class;
    if (n > 0) {
        pfp_diag_log_live_instances("sync", targets, n);
    }

    // v2.1: register for periodic rewalk — sync manager spawns at first
    // multiplayer login/sign-in, often minutes after boot.
    pfp_register_rewalk("sync", g_manager_class);
    pfp_register_rewalk("sync", g_envelope_class);
    pfp_register_rewalk("sync", g_savedata_class);
    return 0;  // diagnostic feature — missing class is not an init failure
}

static int tick(void) {
    // Diagnostic only: nothing per-tick until we pick the Apply method.
    return 0;
}

PfpFeature pfp_feature_sync = { "sync", init, tick, 0, 0, 0, 0 };
