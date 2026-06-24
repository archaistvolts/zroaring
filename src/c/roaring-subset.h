/*
 * A subset of roaring.h.
 * 
 * Only exists because 0.16 translate-c fails with roaring.h.
 * TODO remove this file, use translate-c with roaring.h
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>

#define ROARING_CONTAINER_T void
#define container_t ROARING_CONTAINER_T
#define BITSET_CONTAINER_TYPE 1
#define ARRAY_CONTAINER_TYPE 2
#define RUN_CONTAINER_TYPE 3
#define SHARED_CONTAINER_TYPE 4

#define CAST(type, value) ((type)value)
#define movable_CAST(type, value) ((type)value)
#define CAST_shared(c) CAST(shared_container_t *, c)  // safer downcast
#define const_CAST_shared(c) CAST(const shared_container_t *, c)

#define CAST_bitset(c) CAST(bitset_container_t *, c)  // safer downcast
#define const_CAST_bitset(c) CAST(const bitset_container_t *, c)
#define movable_CAST_bitset(c) movable_CAST(bitset_container_t **, c)

#define STRUCT_CONTAINER(name) struct name /* { ... } */
typedef uint32_t croaring_refcount_t;

STRUCT_CONTAINER(shared_container_s) {
    container_t *container;
    uint8_t typecode;
    croaring_refcount_t counter;  // to be managed atomically
};

typedef struct shared_container_s shared_container_t;

STRUCT_CONTAINER(bitset_container_s) {
    int32_t cardinality;
    uint64_t *words;
};

typedef struct bitset_container_s bitset_container_t;

#define CAST_bitset(c) CAST(bitset_container_t *, c)  // safer downcast
#define const_CAST_bitset(c) CAST(const bitset_container_t *, c)
#define movable_CAST_bitset(c) movable_CAST(bitset_container_t **, c)

STRUCT_CONTAINER(array_container_s) {
    int32_t cardinality;
    int32_t capacity;
    uint16_t *array;
};

typedef struct array_container_s array_container_t;

#define CAST_array(c) CAST(array_container_t *, c)  // safer downcast
#define const_CAST_array(c) CAST(const array_container_t *, c)
#define movable_CAST_array(c) movable_CAST(array_container_t **, c)

struct rle16_s {
    uint16_t value;
    uint16_t length;
};

typedef struct rle16_s rle16_t;
STRUCT_CONTAINER(run_container_s) {
    int32_t n_runs;
    int32_t capacity;
    rle16_t *runs;
};

typedef struct run_container_s run_container_t;

#define CAST_run(c) CAST(run_container_t *, c)  // safer downcast
#define const_CAST_run(c) CAST(const run_container_t *, c)
#define movable_CAST_run(c) movable_CAST(run_container_t **, c)

#define roaring_unreachable __builtin_unreachable()

typedef struct roaring_array_s {
    int32_t size;
    int32_t allocation_size;
    ROARING_CONTAINER_T **containers;  // Use container_t in non-API files!
    uint16_t *keys;
    uint8_t *typecodes;
    uint8_t flags;
} roaring_array_t;

typedef struct roaring_bitmap_s {
    roaring_array_t high_low_container;
} roaring_bitmap_t;

roaring_bitmap_t *roaring_bitmap_create_with_capacity(uint32_t cap);

inline roaring_bitmap_t *roaring_bitmap_create(void) {
    return roaring_bitmap_create_with_capacity(0);
}

void roaring_bitmap_free(const roaring_bitmap_t *r);

bool roaring_bitmap_remove_checked(roaring_bitmap_t *r, uint32_t x);

bool roaring_bitmap_equals(const roaring_bitmap_t *r1,
                           const roaring_bitmap_t *r2);

void roaring_bitmap_add_many(roaring_bitmap_t *r, size_t n_args,
                             const uint32_t *vals);

void roaring_bitmap_add_range_closed(roaring_bitmap_t *r, uint32_t min,
                                     uint32_t max);

roaring_bitmap_t *roaring_bitmap_and(const roaring_bitmap_t *r1,
                                     const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_or(const roaring_bitmap_t *r1,
                                    const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_lazy_or(const roaring_bitmap_t *r1,
                                         const roaring_bitmap_t *r2,
                                         const bool bitsetconversion);

void roaring_bitmap_repair_after_lazy(roaring_bitmap_t *r1);

roaring_bitmap_t *roaring_bitmap_or_many(size_t number,
                                         const roaring_bitmap_t **rs);

bool roaring_bitmap_select(const roaring_bitmap_t *r, uint32_t rank,
                           uint32_t *element);

uint64_t roaring_bitmap_rank(const roaring_bitmap_t *r, uint32_t x);

void roaring_bitmap_clear(roaring_bitmap_t *r);

void roaring_bitmap_add(roaring_bitmap_t *r, uint32_t x);

size_t roaring_bitmap_portable_serialize(const roaring_bitmap_t *r, char *buf);

inline bool roaring_bitmap_contains(const roaring_bitmap_t *r, uint32_t val);

roaring_bitmap_t *roaring_bitmap_xor(const roaring_bitmap_t *r1,
                                     const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_andnot(const roaring_bitmap_t *r1,
                                        const roaring_bitmap_t *r2);

bool roaring_bitmap_is_subset(const roaring_bitmap_t *r1,
                              const roaring_bitmap_t *r2);

uint64_t roaring_bitmap_and_cardinality(const roaring_bitmap_t *r1,
                                        const roaring_bitmap_t *r2);

uint64_t roaring_bitmap_or_cardinality(const roaring_bitmap_t *r1,
                                       const roaring_bitmap_t *r2);

uint64_t roaring_bitmap_xor_cardinality(const roaring_bitmap_t *r1,
                                        const roaring_bitmap_t *r2);

uint64_t roaring_bitmap_andnot_cardinality(const roaring_bitmap_t *r1,
                                           const roaring_bitmap_t *r2);

double roaring_bitmap_jaccard_index(const roaring_bitmap_t *r1,
                                    const roaring_bitmap_t *r2);

void roaring_bitmap_or_inplace(roaring_bitmap_t *r1,
                               const roaring_bitmap_t *r2);

void roaring_bitmap_and_inplace(roaring_bitmap_t *r1,
                               const roaring_bitmap_t *r2);

bool roaring_bitmap_run_optimize(roaring_bitmap_t *r);

size_t roaring_bitmap_shrink_to_fit(roaring_bitmap_t *r);

uint64_t roaring_bitmap_range_cardinality(const roaring_bitmap_t *r,
                                          uint64_t range_start,
                                          uint64_t range_end);

bool roaring_bitmap_contains_range(const roaring_bitmap_t *r,
                                   uint64_t range_start, uint64_t range_end);

uint32_t roaring_bitmap_minimum(const roaring_bitmap_t *r);

uint32_t roaring_bitmap_maximum(const roaring_bitmap_t *r);

uint32_t ra_portable_header_size(const roaring_array_t *ra);

size_t roaring_bitmap_portable_size_in_bytes(const roaring_bitmap_t *r);

roaring_bitmap_t *roaring_bitmap_portable_deserialize_safe(const char *buf,
                                                           size_t maxbytes);

uint64_t roaring_bitmap_get_cardinality(const roaring_bitmap_t *r);

void roaring_bitmap_to_uint32_array(const roaring_bitmap_t *r, uint32_t *ans);

inline void roaring_bitmap_add_range(roaring_bitmap_t *r, uint64_t min,
                                     uint64_t max) {
    if (max <= min || min > (uint64_t)UINT32_MAX + 1) {
        return;
    }
    roaring_bitmap_add_range_closed(r, (uint32_t)min, (uint32_t)(max - 1));
}

size_t roaring_bitmap_frozen_size_in_bytes(const roaring_bitmap_t *r);

void roaring_bitmap_frozen_serialize(const roaring_bitmap_t *r, char *buf);

static inline const container_t *container_unwrap_shared(
    const container_t *candidate_shared_container, uint8_t *type) {
    if (*type == SHARED_CONTAINER_TYPE) {
        *type = const_CAST_shared(candidate_shared_container)->typecode;
        assert(*type != SHARED_CONTAINER_TYPE);
        return const_CAST_shared(candidate_shared_container)->container;
    } else {
        return candidate_shared_container;
    }
}

static inline int bitset_container_cardinality(
    const bitset_container_t *bitset) {
    return bitset->cardinality;
}

static inline int array_container_cardinality(const array_container_t *array) {
    return array->cardinality;
}

int run_container_cardinality(const run_container_t *run);

static inline int container_get_cardinality(const container_t *c,
                                            uint8_t typecode) {
    c = container_unwrap_shared(c, &typecode);
    switch (typecode) {
        case BITSET_CONTAINER_TYPE:
            return bitset_container_cardinality(const_CAST_bitset(c));
        case ARRAY_CONTAINER_TYPE:
            return array_container_cardinality(const_CAST_array(c));
        case RUN_CONTAINER_TYPE:
            return run_container_cardinality(const_CAST_run(c));
    }
    assert(false);
    roaring_unreachable;
    return 0;  // unreached
}

typedef struct roaring_container_iterator_s {
    // For bitset and array containers this is the index of the bit / entry.
    // For run containers this points at the run.
    int32_t index;
} roaring_container_iterator_t;

typedef struct roaring_uint32_iterator_s {
    const roaring_bitmap_t *parent;        // Owner
    const ROARING_CONTAINER_T *container;  // Current container
    uint8_t typecode;                      // Typecode of current container
    int32_t container_index;               // Current container index
    uint32_t highbits;                     // High 16 bits of the current value
    roaring_container_iterator_t container_it;

    uint32_t current_value;
    bool has_value;
} roaring_uint32_iterator_t;

roaring_uint32_iterator_t *roaring_iterator_create(const roaring_bitmap_t *r);

void roaring_uint32_iterator_free(roaring_uint32_iterator_t *it);

uint32_t roaring_uint32_iterator_read(roaring_uint32_iterator_t *it,
                                      uint32_t *buf, uint32_t count);
