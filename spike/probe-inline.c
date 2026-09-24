#include <windows.h>

static kk_integer_t kk_win32_msgbox(kk_string_t s, kk_context_t* ctx) {
  kk_ssize_t len;
  const char* cs = kk_string_cbuf_borrow(s, &len, ctx);
  int r = MessageBoxA(NULL, cs, "koka probe", MB_OK);
  kk_string_drop(s, ctx);
  return kk_integer_from_int(r, ctx);
}
