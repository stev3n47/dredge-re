/* Minimal loadable arm64 dylib. Shipped in place of the removed iOSGods
   payloads (libcarx.dylib, iGameGod.framework/iGameGod) so the original
   load commands resolve to real files and no defunct weak images remain
   in the dependency graph. No init functions, no symbols — loads, does
   nothing. */
__attribute__((used)) void __cx_stub(void) {}
