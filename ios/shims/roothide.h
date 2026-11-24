/* Minimal roothide.h shim.
 *
 * YTLite imports <roothide.h> unconditionally and calls jbroot(). The real
 * header only exists when building with THEOS_PACKAGE_SCHEME=roothide. In a
 * jailed (injected) build there is no rootfs prefix, so the identity mapping
 * below is the correct behaviour.
 */
#ifndef YTB_ROOTHIDE_SHIM_H
#define YTB_ROOTHIDE_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

static inline char *jbroot(const char *path) { return (char *)path; }
static inline char *rootfs(const char *path) { return (char *)path; }
static inline const char *jbrootPath(const char *path) { return path; }

#ifdef __cplusplus
}
#endif

#endif /* YTB_ROOTHIDE_SHIM_H */
