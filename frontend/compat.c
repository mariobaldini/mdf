/* New glibc releases version some libm functions again. Keep the documented
   x86_64 glibc 2.38 minimum when renderer float operations are linked on Fedora. */
extern float mdf_legacy_acosf(float);
extern float mdf_legacy_atan2f(float, float);
__asm__(".symver mdf_legacy_acosf,acosf@GLIBC_2.2.5");
__asm__(".symver mdf_legacy_atan2f,atan2f@GLIBC_2.2.5");
float __wrap_acosf(float value) { return mdf_legacy_acosf(value); }
float __wrap_atan2f(float y, float x) { return mdf_legacy_atan2f(y, x); }
