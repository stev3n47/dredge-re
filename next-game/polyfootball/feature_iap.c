// feature_iap.c — v1.5 IAP receipt-validator discovery.
//
// Purpose: when Pro is unlocked via UnlockPro (static invoke, v1a), the
// state flag flips in-game immediately. But Unity.Purchasing's
// CrossPlatformValidator / AppleAppReceipt re-validates the Apple receipt
// at cold-start; if it finds no matching StoreKit purchase for
// com.Miceli.Poly.pro it may undo our flag. To stop that we eventually
// want to hook `Validate` on the validator class so it returns success
// without actually checking the receipt.
//
// v1.5 scope here is PURE DISCOVERY: find the IAP-related images and
// classes that ship with this build and log everything about them. No
// managed invokes, no heap derefs. A later v1.5.1 picks the right method
// based on what we learn, and hooks it.

#include "features.h"

#include <string.h>

// --- discovery state ------------------------------------------------------

#define IAP_MAX_IMAGES   8
#define IAP_MAX_CLASSES  64

static int g_iap_images_seen = 0;
static int g_iap_classes_logged = 0;

static const char *k_image_substrs[] = {
    "Stores",       // UnityEngine.Purchasing.Stores
    "Purchasing",   // UnityEngine.Purchasing / Unity.Services.Purchasing
};
static const int k_image_substr_count = sizeof(k_image_substrs) / sizeof(k_image_substrs[0]);

// Class-name substrings to look for in Stores/Purchasing images AND in
// Assembly-CSharp.dll (some games wrap Unity's validator in a game-side
// facade class whose name contains "Receipt" or "Validator").
static const char *k_class_substrs[] = {
    "Validator",
    "Receipt",
    "CrossPlatform",
    "AppleValidator",      // Apple Store receipt validator
    "AppleReceipt",        // Apple receipt decoder
    "GoogleValidator",     // Google Play (rare on iOS but catalog may carry)
    "AppleAppReceipt",
    "IReceiptValidator",
};
static const int k_class_substr_count = sizeof(k_class_substrs) / sizeof(k_class_substrs[0]);

static int name_matches_any(const char *name, const char **substrs, int count) {
    if (!name) return 0;
    for (int i = 0; i < count; i++) {
        if (substrs[i] && strstr(name, substrs[i])) return 1;
    }
    return 0;
}

// Log every class in `img` whose name matches one of `k_class_substrs`.
// Caps per-feature output at IAP_MAX_CLASSES so a weird image doesn't
// swamp the log. Returns matches logged this call.
static int log_matching_classes(const Il2CppImage *img, const char *img_label) {
    if (!img) return 0;
    size_t nc = pfp_il2cpp_image_get_class_count(img);
    int logged = 0;
    for (size_t ci = 0; ci < nc; ci++) {
        Il2CppClass *k = pfp_il2cpp_image_get_class((Il2CppImage *)img, ci);
        if (!k) continue;
        const char *kn = pfp_il2cpp_class_get_name(k);
        if (!name_matches_any(kn, k_class_substrs, k_class_substr_count)) continue;
        const char *ns = pfp_il2cpp_class_get_namespace(k);
        int mc = pfp_il2cpp_count_methods(k);
        pfp_log("iap:   class %s.%s @ %p (methods=%d) in %s",
                (ns && *ns) ? ns : "<empty-ns>",
                kn ? kn : "?", (void *)k, mc, img_label);
        if (++g_iap_classes_logged >= IAP_MAX_CLASSES) {
            pfp_log("iap:   (classes truncated at %d)", IAP_MAX_CLASSES);
            return logged;
        }
        logged++;
    }
    return logged;
}

// --- init -----------------------------------------------------------------

static int init(void) {
    if (!pfp_il2cpp_ready()) {
        pfp_log("iap: init called before il2cpp ready — deferring");
        return -1;
    }

    Il2CppDomain *dom = pfp_il2cpp_domain_get();
    if (!dom) {
        pfp_log("iap: domain_get returned NULL — cannot enumerate images");
        return -2;
    }

    size_t na = 0;
    const Il2CppAssembly **asms = pfp_il2cpp_domain_get_assemblies(dom, &na);
    if (!asms || na == 0) {
        pfp_log("iap: no assemblies loaded (yet?) — nothing to scan");
        return 0;
    }

    pfp_log("iap: scanning %zu loaded assemblies for IAP validators", na);

    // Pass 1: find Stores / Purchasing images, enumerate their classes.
    int stores_images_found = 0;
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = pfp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        const char *in = pfp_il2cpp_image_get_name(img);
        if (!in) continue;
        if (!name_matches_any(in, k_image_substrs, k_image_substr_count)) continue;
        size_t nc = pfp_il2cpp_image_get_class_count(img);
        pfp_log("iap: image %s (classes=%zu)", in, nc);
        stores_images_found++;
        if (g_iap_images_seen < IAP_MAX_IMAGES) g_iap_images_seen++;
        log_matching_classes(img, in);
    }

    if (stores_images_found == 0) {
        pfp_log("iap: no Stores.dll — Unity.Purchasing likely stripped from this build");
    }

    // Pass 2: Assembly-CSharp side — game-side receipt/validator wrappers.
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = pfp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        const char *in = pfp_il2cpp_image_get_name(img);
        if (!in || strcmp(in, "Assembly-CSharp.dll") != 0) continue;
        pfp_log("iap: scanning Assembly-CSharp.dll for game-side receipt wrappers");
        log_matching_classes(img, "Assembly-CSharp.dll");
        break;
    }

    pfp_log("iap: discovery complete — images=%d classes=%d (v1.5.1 will hook based on this)",
            g_iap_images_seen, g_iap_classes_logged);

    // v2.2.1: deep dump on AppleReceiptParser specifically — the primary
    // hook target per the Nov 13 device log (12 methods in
    // Unity.Purchasing.Security.dll). We enumerate every method name +
    // argc + static-bit so v2.2.2 can pick the right one to swap.
    Il2CppClass *parser =
        pfp_il2cpp_find_class("Unity.Purchasing.Security.dll", NULL, "AppleReceiptParser");
    if (!parser) {
        parser = pfp_il2cpp_find_class(NULL, "UnityEngine.Purchasing.Security", "AppleReceiptParser");
    }
    if (parser) {
        int n = pfp_il2cpp_count_methods(parser);
        pfp_log("iap: AppleReceiptParser class=%p method_count=%d — full method dump below",
                (void *)parser, n);
        pfp_diag_log_methods("iap-parser", parser, NULL, 0);  // no filter, all methods
    } else {
        pfp_log("iap: AppleReceiptParser class lookup FAILED in both image variants");
    }
    return 0;
}

static int tick(void) {
    // v1.5 is discovery-only. v2.2.1 defers actual hook to v2.2.2
    // after the method inventory from the deep dump is reviewed.
    return 0;
}

PfpFeature pfp_feature_iap = { "iap", init, tick, 0, 0, 0, 0 };
