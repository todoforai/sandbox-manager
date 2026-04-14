// Stubs for Julia 1.12 StaticCompiler missing symbols
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

// jl_small_typeof — Julia's type tag table. 
// In static binaries this is used for type checks in ccall error paths.
// We provide a dummy that's large enough (0x140 + 8 bytes accessed).
static uint8_t _fake_typeof_table[0x200] = {0};
void* jl_small_typeof = &_fake_typeof_table;

// ijl_type_error — called when a ccall argument has wrong type.
// In a static binary this should never be reached if types are correct.
void ijl_type_error(const char *fname, void *expected, void *got) {
    fprintf(stderr, "type error in %s\n", fname);
    exit(1);
}
