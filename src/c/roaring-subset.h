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

container_t *container_from_run_range(const run_container_t *run, uint32_t min,
                                      uint32_t max, uint8_t *typecode_after);

container_t *container_clone(const container_t *container, uint8_t typecode);

void container_printf(const container_t *container, uint8_t typecode);

void container_printf_as_uint32_array(const container_t *container,
                                      uint8_t typecode, uint32_t base);

bool container_internal_validate(const container_t *container, uint8_t typecode,
                                 const char **reason);

void container_free(container_t *container, uint8_t typecode);

bool container_contains(const container_t *c, uint16_t val, uint8_t typecode);

typedef struct roaring_container_iterator_s {
    // For bitset and array containers this is the index of the bit / entry.
    // For run containers this points at the run.
    int32_t index;
} roaring_container_iterator_t;

bool container_iterator_next(const container_t *c, uint8_t typecode,
                             roaring_container_iterator_t *it, uint16_t *value);

bool container_iterator_prev(const container_t *c, uint8_t typecode,
                             roaring_container_iterator_t *it, uint16_t *value);

roaring_container_iterator_t container_init_iterator(const container_t *c,
                                                     uint8_t typecode,
                                                     uint16_t *value);

roaring_container_iterator_t container_init_iterator_last(const container_t *c,
                                                          uint8_t typecode,
                                                          uint16_t *value);

bool container_iterator_lower_bound(const container_t *c, uint8_t typecode,
                                    roaring_container_iterator_t *it,
                                    uint16_t *value_out, uint16_t val);

bool container_iterator_read_into_uint32(const container_t *c, uint8_t typecode,
                                         roaring_container_iterator_t *it,
                                         uint32_t high16, uint32_t *buf,
                                         uint32_t count, uint32_t *consumed,
                                         uint16_t *value_out);

bool container_iterator_read_into_uint64(const container_t *c, uint8_t typecode,
                                         roaring_container_iterator_t *it,
                                         uint64_t high48, uint64_t *buf,
                                         uint32_t count, uint32_t *consumed,
                                         uint16_t *value_out);

bool container_iterator_skip(const container_t *c, uint8_t typecode,
                             roaring_container_iterator_t *it,
                             uint32_t skip_count, uint32_t *consumed_count,
                             uint16_t *value_out);

bool container_iterator_skip_backward(const container_t *c, uint8_t typecode,
                                      roaring_container_iterator_t *it,
                                      uint32_t skip_count,
                                      uint32_t *consumed_count,
                                      uint16_t *value_out);

#define ROARING_FLAG_COW UINT8_C(0x1)

typedef struct roaring_bulk_context_s {
    ROARING_CONTAINER_T *container;
    int idx;
    uint16_t key;
    uint8_t typecode;
} roaring_bulk_context_t;

typedef struct roaring_statistics_s {
    uint32_t n_containers;
    uint32_t n_array_containers;
    uint32_t n_run_containers;
    uint32_t n_bitset_containers;
    uint32_t n_values_array_containers;
    uint32_t n_values_run_containers;
    uint32_t n_values_bitset_containers;
    uint32_t n_bytes_array_containers;
    uint32_t n_bytes_run_containers;
    uint32_t n_bytes_bitset_containers;
    uint32_t max_value;
    uint32_t min_value;
    uint64_t sum_value;
    uint64_t cardinality;
} roaring_statistics_t;

struct bitset_s;
typedef struct bitset_s bitset_t;

bool roaring_bitmap_init_with_capacity(roaring_bitmap_t *r, uint32_t cap);

inline void roaring_bitmap_init_cleared(roaring_bitmap_t *r) {
    roaring_bitmap_init_with_capacity(r, 0);
}

bool roaring_bitmap_overwrite(roaring_bitmap_t *dest,
                              const roaring_bitmap_t *src);

roaring_bitmap_t *roaring_bitmap_copy(const roaring_bitmap_t *r);

roaring_bitmap_t *roaring_bitmap_from_range(uint64_t min, uint64_t max,
                                            uint32_t step);

roaring_bitmap_t *roaring_bitmap_of_ptr(size_t n_args, const uint32_t *vals);

roaring_bitmap_t *roaring_bitmap_add_offset(const roaring_bitmap_t *bm,
                                            int64_t offset);

void roaring_bitmap_add_bulk(roaring_bitmap_t *r,
                             roaring_bulk_context_t *context, uint32_t val);

bool roaring_bitmap_add_checked(roaring_bitmap_t *r, uint32_t x);

void roaring_bitmap_remove(roaring_bitmap_t *r, uint32_t x);

void roaring_bitmap_remove_range_closed(roaring_bitmap_t *r, uint32_t min,
                                        uint32_t max);

inline void roaring_bitmap_remove_range(roaring_bitmap_t *r, uint64_t min,
                                        uint64_t max) {
    if (max <= min || min > (uint64_t)UINT32_MAX + 1) {
        return;
    }
    roaring_bitmap_remove_range_closed(r, (uint32_t)min, (uint32_t)(max - 1));
}

void roaring_bitmap_remove_many(roaring_bitmap_t *r, size_t n_args,
                                const uint32_t *vals);

bool roaring_bitmap_contains_range_closed(const roaring_bitmap_t *r,
                                          uint32_t range_start,
                                          uint32_t range_end);

bool roaring_bitmap_contains_bulk(const roaring_bitmap_t *r,
                                  roaring_bulk_context_t *context,
                                  uint32_t val);

uint64_t roaring_bitmap_range_cardinality_closed(const roaring_bitmap_t *r,
                                                  uint32_t range_start,
                                                  uint32_t range_end);

bool roaring_bitmap_is_empty(const roaring_bitmap_t *r);

bool roaring_bitmap_intersect(const roaring_bitmap_t *r1,
                              const roaring_bitmap_t *r2);

bool roaring_bitmap_intersect_with_range(const roaring_bitmap_t *bm, uint64_t x,
                                         uint64_t y);

bool roaring_bitmap_is_strict_subset(const roaring_bitmap_t *r1,
                                     const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_or_many_heap(uint32_t number,
                                              const roaring_bitmap_t **rs);

void roaring_bitmap_xor_inplace(roaring_bitmap_t *r1,
                                const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_xor_many(size_t number,
                                          const roaring_bitmap_t **rs);

void roaring_bitmap_andnot_inplace(roaring_bitmap_t *r1,
                                   const roaring_bitmap_t *r2);

void roaring_bitmap_lazy_or_inplace(roaring_bitmap_t *r1,
                                    const roaring_bitmap_t *r2,
                                    const bool bitsetconversion);

roaring_bitmap_t *roaring_bitmap_lazy_xor(const roaring_bitmap_t *r1,
                                          const roaring_bitmap_t *r2);

void roaring_bitmap_lazy_xor_inplace(roaring_bitmap_t *r1,
                                     const roaring_bitmap_t *r2);

roaring_bitmap_t *roaring_bitmap_flip(const roaring_bitmap_t *r1,
                                      uint64_t range_start,
                                      uint64_t range_end);

roaring_bitmap_t *roaring_bitmap_flip_closed(const roaring_bitmap_t *x1,
                                              uint32_t range_start,
                                              uint32_t range_end);

void roaring_bitmap_flip_inplace(roaring_bitmap_t *r1, uint64_t range_start,
                                 uint64_t range_end);

void roaring_bitmap_flip_inplace_closed(roaring_bitmap_t *r1,
                                         uint32_t range_start,
                                         uint32_t range_end);

bool roaring_bitmap_remove_run_compression(roaring_bitmap_t *r);

size_t roaring_bitmap_serialize(const roaring_bitmap_t *r, char *buf);

roaring_bitmap_t *roaring_bitmap_deserialize(const void *buf);

roaring_bitmap_t *roaring_bitmap_deserialize_safe(const void *buf,
                                                   size_t maxbytes);

size_t roaring_bitmap_size_in_bytes(const roaring_bitmap_t *r);

roaring_bitmap_t *roaring_bitmap_portable_deserialize(const char *buf);

roaring_bitmap_t *roaring_bitmap_portable_deserialize_frozen(const char *buf);

size_t roaring_bitmap_portable_deserialize_size(const char *buf,
                                                size_t maxbytes);

const roaring_bitmap_t *roaring_bitmap_frozen_view(const char *buf,
                                                   size_t length);

void roaring_bitmap_printf(const roaring_bitmap_t *r);

void roaring_bitmap_printf_describe(const roaring_bitmap_t *r);

bool roaring_bitmap_range_uint32_array(const roaring_bitmap_t *r, size_t offset,
                                       size_t limit, uint32_t *ans);

bool roaring_bitmap_get_copy_on_write(const roaring_bitmap_t *r);

void roaring_bitmap_set_copy_on_write(roaring_bitmap_t *r, bool cow);

void roaring_bitmap_rank_many(const roaring_bitmap_t *r, const uint32_t *begin,
                              const uint32_t *end, uint64_t *ans);

int64_t roaring_bitmap_get_index(const roaring_bitmap_t *r, uint32_t x);

void roaring_bitmap_statistics(const roaring_bitmap_t *r,
                               roaring_statistics_t *stat);

bool roaring_bitmap_internal_validate(const roaring_bitmap_t *r,
                                      const char **reason);

bool roaring_bitmap_to_bitset(const roaring_bitmap_t *r, bitset_t *bitset);

roaring_array_t *ra_create(void);

bool ra_init_with_capacity(roaring_array_t *new_ra, uint32_t cap);

void ra_init(roaring_array_t *t);

bool ra_copy(const roaring_array_t *source, roaring_array_t *dest,
             bool copy_on_write);

int ra_shrink_to_fit(roaring_array_t *ra);

bool ra_overwrite(const roaring_array_t *source, roaring_array_t *dest,
                  bool copy_on_write);

void ra_clear(roaring_array_t *r);

void ra_clear_without_containers(roaring_array_t *r);

void ra_clear_containers(roaring_array_t *ra);

int32_t ra_get_index(const roaring_array_t *ra, uint16_t x);

inline container_t *ra_get_container_at_index(const roaring_array_t *ra,
                                              uint16_t i, uint8_t *typecode) {
    *typecode = ra->typecodes[i];
    return ra->containers[i];
}

inline uint16_t ra_get_key_at_index(const roaring_array_t *ra, uint16_t i) {
    return ra->keys[i];
}

container_t *ra_get_container(roaring_array_t *ra, uint16_t x,
                              uint8_t *typecode);

void ra_insert_new_key_value_at(roaring_array_t *ra, int32_t i, uint16_t key,
                                container_t *c, uint8_t typecode);

void ra_append(roaring_array_t *ra, uint16_t key, container_t *c,
               uint8_t typecode);

void ra_append_copy(roaring_array_t *ra, const roaring_array_t *sa,
                    uint16_t index, bool copy_on_write);

void ra_append_copy_range(roaring_array_t *ra, const roaring_array_t *sa,
                          int32_t start_index, int32_t end_index,
                          bool copy_on_write);

void ra_append_copies_until(roaring_array_t *ra, const roaring_array_t *sa,
                            uint16_t stopping_key, bool copy_on_write);

void ra_append_copies_after(roaring_array_t *ra, const roaring_array_t *sa,
                            uint16_t before_start, bool copy_on_write);

void ra_append_move_range(roaring_array_t *ra, roaring_array_t *sa,
                          int32_t start_index, int32_t end_index);

void ra_append_range(roaring_array_t *ra, roaring_array_t *sa,
                     int32_t start_index, int32_t end_index,
                     bool copy_on_write);

inline void ra_set_container_at_index(const roaring_array_t *ra, int32_t i,
                                      container_t *c, uint8_t typecode) {
    assert(i < ra->size);
    ra->containers[i] = c;
    ra->typecodes[i] = typecode;
}

inline int32_t ra_get_size(const roaring_array_t *ra) { return ra->size; }

int32_t ra_advance_until(const roaring_array_t *ra, uint16_t x, int32_t pos);

int32_t ra_advance_until_freeing(roaring_array_t *ra, uint16_t x, int32_t pos);

void ra_downsize(roaring_array_t *ra, int32_t new_length);

inline void ra_replace_key_and_container_at_index(roaring_array_t *ra,
                                                  int32_t i, uint16_t key,
                                                  container_t *c,
                                                  uint8_t typecode) {
    assert(i < ra->size);
    ra->keys[i] = key;
    ra->containers[i] = c;
    ra->typecodes[i] = typecode;
}

void ra_to_uint32_array(const roaring_array_t *ra, uint32_t *ans);

size_t ra_portable_serialize(const roaring_array_t *ra, char *buf);

bool ra_portable_deserialize(roaring_array_t *ra, const char *buf,
                             const size_t maxbytes, size_t *readbytes);

size_t ra_portable_deserialize_size(const char *buf, const size_t maxbytes);

size_t ra_portable_size_in_bytes(const roaring_array_t *ra);

bool ra_has_run_container(const roaring_array_t *ra);

void ra_unshare_container_at_index(roaring_array_t *ra, uint16_t i);

void ra_remove_at_index(roaring_array_t *ra, int32_t i);

void ra_reset(roaring_array_t *ra);

void ra_remove_at_index_and_free(roaring_array_t *ra, int32_t i);

void ra_copy_range(roaring_array_t *ra, uint32_t begin, uint32_t end,
                   uint32_t new_begin);

void ra_shift_tail(roaring_array_t *ra, int32_t count, int32_t distance);

typedef bool (*roaring_iterator)(uint32_t value, void *param);

typedef bool (*roaring_iterator64)(uint64_t value, void *param);

array_container_t *array_container_create(void);

array_container_t *array_container_create_given_capacity(int32_t size);

array_container_t *array_container_create_range(
    uint32_t min,
    uint32_t max);

int array_container_shrink_to_fit(array_container_t *src);

void array_container_free(array_container_t *array);

void array_container_copy(
    const array_container_t *src,
    array_container_t *dst);

void array_container_add_from_range(
    array_container_t *arr,
    uint32_t min,
    uint32_t max,
    uint16_t step);

void array_container_union(
    const array_container_t *src_1,
    const array_container_t *src_2,
    array_container_t *dst);

void array_container_xor(
    const array_container_t *array_1,
    const array_container_t *array_2,
    array_container_t *out);

void array_container_intersection(
    const array_container_t *src_1,
    const array_container_t *src_2,
    array_container_t *dst);

int array_container_intersection_cardinality(
    const array_container_t *src_1,
    const array_container_t *src_2);

void array_container_intersection_inplace(
    array_container_t *src_1,
    const array_container_t *src_2);

int32_t array_container_number_of_runs(const array_container_t *ac);

void array_container_printf(const array_container_t *v);

bool array_container_validate(
    const array_container_t *v,
    const char **reason);

void array_container_grow(
    array_container_t *container,
    int32_t min,
    bool preserve);

bool array_container_iterate(
    const array_container_t *cont,
    uint32_t base,
    roaring_iterator iterator,
    void *ptr);

int32_t array_container_write(
    const array_container_t *container,
    char *buf);

int32_t array_container_read(
    int32_t cardinality,
    array_container_t *container,
    const char *buf);

void array_container_andnot(
    const array_container_t *array_1,
    const array_container_t *array_2,
    array_container_t *out);

void array_container_offset(
    const array_container_t *c,
    container_t **loc,
    container_t **hic,
    uint16_t offset);

void array_container_negation(
    const array_container_t *src,
    bitset_container_t *dst);

bool array_container_negation_range(
    const array_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

bool array_container_negation_range_inplace(
    array_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

bool array_container_equal_bitset(
    const array_container_t *container1,
    const bitset_container_t *container2);

bool array_container_is_subset_bitset(
    const array_container_t *container1,
    const bitset_container_t *container2);

bool array_container_is_subset_run(
    const array_container_t *container1,
    const run_container_t *container2);

array_container_t *array_container_from_run(
    const run_container_t *arr);

array_container_t *array_container_from_bitset(
    const bitset_container_t *bits);

void array_container_clone(const array_container_t *src);

bitset_container_t *bitset_container_create(void);

void bitset_container_free(bitset_container_t *bitset);

void bitset_container_clear(bitset_container_t *bitset);

void bitset_container_copy(
    const bitset_container_t *source,
    bitset_container_t *dest);

void bitset_container_add_from_range(
    bitset_container_t *bitset,
    uint32_t min,
    uint32_t max,
    uint16_t step);

int bitset_container_or(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_or_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_union(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_union_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_union_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_or_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_and(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_and_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_intersection(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_intersection_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_intersection_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_and_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_xor(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_xor_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_xor_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_andnot(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

int bitset_container_andnot_justcard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

int bitset_container_andnot_nocard(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2,
    bitset_container_t *dst);

void bitset_container_offset(
    const bitset_container_t *c,
    container_t **loc,
    container_t **hic,
    uint16_t offset);

void bitset_container_printf(const bitset_container_t *v);

bool bitset_container_validate(
    const bitset_container_t *v,
    const char **reason);

int bitset_container_number_of_runs(bitset_container_t *bc);

bool bitset_container_iterate(
    const bitset_container_t *cont,
    uint32_t base,
    roaring_iterator iterator,
    void *ptr);

int32_t bitset_container_write(
    const bitset_container_t *container,
    char *buf);

int32_t bitset_container_read(
    int32_t cardinality,
    bitset_container_t *container,
    const char *buf);

bool bitset_container_negation(
    const bitset_container_t *src,
    container_t **dst);

bool bitset_container_negation_inplace(
    bitset_container_t *src,
    container_t **dst);

bool bitset_container_negation_range(
    const bitset_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

bool bitset_container_negation_range_inplace(
    bitset_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

bool bitset_container_is_subset_run(
    const bitset_container_t *container1,
    const run_container_t *container2);

bool bitset_container_intersect(
    const bitset_container_t *src_1,
    const bitset_container_t *src_2);

bool bitset_container_is_subset(
    const bitset_container_t *container1,
    const bitset_container_t *container2);

bool bitset_container_equals(
    const bitset_container_t *container1,
    const bitset_container_t *container2);

bool bitset_container_select(
    const bitset_container_t *container,
    uint32_t *start_rank,
    uint32_t rank,
    uint32_t *element);

uint16_t bitset_container_minimum(const bitset_container_t *container);

uint16_t bitset_container_maximum(const bitset_container_t *container);

int bitset_container_rank(
    const bitset_container_t *container,
    uint16_t x);

uint32_t bitset_container_rank_many(
    const bitset_container_t *container,
    uint64_t start_rank,
    const uint32_t *begin,
    const uint32_t *end,
    uint64_t *ans);

int bitset_container_get_index(
    const bitset_container_t *container,
    uint16_t x);

int bitset_container_index_equalorlarger(
    const bitset_container_t *container,
    uint16_t x);

bitset_container_t *bitset_container_from_array(
    const array_container_t *arr);

bitset_container_t *bitset_container_from_run(
    const run_container_t *arr);

bitset_container_t *bitset_container_clone(const bitset_container_t *src);

run_container_t *run_container_create(void);

run_container_t *run_container_create_given_capacity(int32_t size);

int run_container_shrink_to_fit(run_container_t *src);

void run_container_free(run_container_t *run);

void run_container_grow(run_container_t *run, int32_t min, bool copy);

bool run_container_add(run_container_t *run, uint16_t pos);

void run_container_copy(
    const run_container_t *src,
    run_container_t *dst);

void run_container_union(
    const run_container_t *src_1,
    const run_container_t *src_2,
    run_container_t *dst);

void run_container_union_inplace(
    run_container_t *src_1,
    const run_container_t *src_2);

void run_container_intersection(
    const run_container_t *src_1,
    const run_container_t *src_2,
    run_container_t *dst);

int run_container_intersection_cardinality(
    const run_container_t *src_1,
    const run_container_t *src_2);

void run_container_xor(
    const run_container_t *src_1,
    const run_container_t *src_2,
    run_container_t *dst);

void run_container_printf(const run_container_t *v);

bool run_container_validate(
    const run_container_t *run,
    const char **reason);

bool run_container_iterate(
    const run_container_t *cont,
    uint32_t base,
    roaring_iterator iterator,
    void *ptr);

int32_t run_container_write(
    const run_container_t *container,
    char *buf);

int32_t run_container_read(
    int32_t cardinality,
    run_container_t *container,
    const char *buf);

void run_container_smart_append_exclusive(
    run_container_t *src,
    const uint16_t start,
    const uint16_t length);

void run_container_andnot(
    const run_container_t *src_1,
    const run_container_t *src_2,
    run_container_t *dst);

void run_container_offset(
    const run_container_t *c,
    container_t **loc,
    container_t **hic,
    uint16_t offset);

bool run_container_intersect(
    const run_container_t *src_1,
    const run_container_t *src_2);

bool run_container_is_subset(
    const run_container_t *container1,
    const run_container_t *container2);

bool run_container_select(
    const run_container_t *container,
    uint32_t *start_rank,
    uint32_t rank,
    uint32_t *element);

int run_container_rank(const run_container_t *arr, uint16_t x);

uint32_t run_container_rank_many(
    const run_container_t *arr,
    uint64_t start_rank,
    const uint32_t *begin,
    const uint32_t *end,
    uint64_t *ans);

int run_container_get_index(const run_container_t *arr, uint16_t x);

int run_container_negation(
    const run_container_t *src,
    container_t **dst);

int run_container_negation_inplace(
    run_container_t *src,
    container_t **dst);

int run_container_negation_range(
    const run_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

int run_container_negation_range_inplace(
    run_container_t *src,
    const int range_start,
    const int range_end,
    container_t **dst);

bool run_container_equals_array(
    const run_container_t *container1,
    const array_container_t *container2);

bool run_container_equals_bitset(
    const run_container_t *container1,
    const bitset_container_t *container2);

bool run_container_is_subset_array(
    const run_container_t *container1,
    const array_container_t *container2);

bool run_container_is_subset_bitset(
    const run_container_t *container1,
    const bitset_container_t *container2);

run_container_t *run_container_from_array(const array_container_t *c);

run_container_t *run_container_clone(const run_container_t *src);

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
