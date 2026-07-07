#include <unistd.h>
#include <stdint.h>
#include <limits.h>
#include <stddef.h>

void zig_fuzz_init(void);
void zig_fuzz_test(const unsigned char*, size_t);

// Coverage guard section (from .fuzz=true compiled code)
extern uint32_t __start___sancov_guards;
extern uint32_t __stop___sancov_guards;
void __sanitizer_cov_trace_pc_guard_init(uint32_t*, uint32_t*);

// Missing symbols that afl-compiler-rt defines
__attribute__((visibility("default")))
__attribute__((tls_model("initial-exec")))
_Thread_local uintptr_t __sancov_lowest_stack;
void __sanitizer_cov_trace_pc_indir(void) {}
void __sanitizer_cov_8bit_counters_init(void) {}
void __sanitizer_cov_pcs_init(void) {}

// AFL shared memory (__AFL_FUZZ_INIT expansion)
int __afl_sharedmem_fuzzing = 1;
extern unsigned int *__afl_fuzz_len;
extern unsigned char *__afl_fuzz_ptr;
unsigned char __afl_fuzz_alt[1048576];
unsigned char *__afl_fuzz_alt_ptr = __afl_fuzz_alt;

int main(void) {
    __sanitizer_cov_trace_pc_guard_init(&__start___sancov_guards, &__stop___sancov_guards);

    // __AFL_INIT expansion
    static volatile const char *_A __attribute__((used,unused));
    _A = (const char*)"##SIG_AFL_DEFER_FORKSRV##";
    void _I(void) __asm__("__afl_manual_init");
    _I();

    zig_fuzz_init();

    // __AFL_LOOP(UINT_MAX) expansion
    while (({
        static volatile const char *_B __attribute__((used,unused));
        _B = (const char*)"##SIG_AFL_PERSISTENT##";
        extern int __afl_connected;
        int _L(unsigned int) __asm__("__afl_persistent_loop");
        _L(__afl_connected ? UINT_MAX : 1);
    })) {
        unsigned char *buf = __afl_fuzz_ptr ? __afl_fuzz_ptr : __afl_fuzz_alt_ptr;
        int len = __afl_fuzz_ptr
            ? *__afl_fuzz_len
            : (*__afl_fuzz_len = read(0, __afl_fuzz_alt_ptr, 1048576)) == 0xffffffff
                ? 0
                : *__afl_fuzz_len;
        zig_fuzz_test(buf, len);
    }

    return 0;
}

// #include <unistd.h>
// #include <stdint.h>
// #include <stddef.h>

// void zig_fuzz_init(void);
// void zig_fuzz_test(const unsigned char*, size_t);

// extern uint32_t __start___sancov_guards;
// extern uint32_t __stop___sancov_guards;
// void __sanitizer_cov_trace_pc_guard_init(uint32_t*, uint32_t*);

// // AFL fork-mode: single read per invocation (AFL++ forks for each input)
// int main() {
//     unsigned char buf[1 << 20];
//     ssize_t n;
//     __sanitizer_cov_trace_pc_guard_init(&__start___sancov_guards, &__stop___sancov_guards);
//     zig_fuzz_init();
//     n = read(STDIN_FILENO, buf, sizeof(buf));
//     if (n > 0) zig_fuzz_test(buf, (size_t)n);
//     return 0;
// }
