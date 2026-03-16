#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
// #include <x86intrin.h>  // on some recent GCC, this will declare posix_memalign
// #include <bmiintrin.h>   // for _blsr_u64
// #include <lzcntintrin.h> // for  __lzcnt64
// #include <immintrin.h>   // for most things (AVX2, AVX512, _popcnt64)
// #include <smmintrin.h>
// #include <tmmintrin.h>
// #include <avxintrin.h>
// #include <avx2intrin.h>
// #include <wmmintrin.h>
// #include <avx512fintrin.h>
// #include <avx512dqintrin.h>
// #include <avx512cdintrin.h>
// #include <avx512bwintrin.h>
// #include <avx512vlintrin.h>
// #include <avx512vbmiintrin.h>
// #include <avx512vbmi2intrin.h>
// #include <avx512vpopcntdqintrin.h>
#define roaring_unreachable __builtin_unreachable()
#define ROARING_CONTAINER_T void
typedef ROARING_CONTAINER_T container_t;
#define BITSET_CONTAINER_TYPE 1
#define ARRAY_CONTAINER_TYPE 2
#define RUN_CONTAINER_TYPE 3
#define SHARED_CONTAINER_TYPE 4
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
/**
 * Dynamically allocates a new bitmap (initially empty).
 * Returns NULL if the allocation fails.
 * Capacity is a performance hint for how many "containers" the data will need.
 * Client is responsible for calling `roaring_bitmap_free()`.
 */
roaring_bitmap_t *roaring_bitmap_create_with_capacity(uint32_t cap);

/**
 * Dynamically allocates a new bitmap (initially empty).
 * Returns NULL if the allocation fails.
 * Client is responsible for calling `roaring_bitmap_free()`.
 */
inline roaring_bitmap_t *roaring_bitmap_create(void) {
    return roaring_bitmap_create_with_capacity(0);
}

/* struct array_container - sparse representation of a bitmap
 *
 * @cardinality: number of indices in `array` (and the bitmap)
 * @capacity:    allocated size of `array`
 * @array:       sorted list of integers
 */
struct array_container_s {
    int32_t cardinality;
    int32_t capacity;
    uint16_t *array;
};

typedef struct array_container_s array_container_t;

#define CAST_array(c) CAST(array_container_t *, c)  // safer downcast
#define const_CAST_array(c) CAST(const array_container_t *, c)
#define movable_CAST_array(c) movable_CAST(array_container_t **, c)

struct bitset_container_s {
    int32_t cardinality;
    uint64_t *words;
};
typedef struct bitset_container_s bitset_container_t;

// #define const_CAST_shared(c) CAST(const shared_container_t *, c)
#define CAST_bitset(c) CAST(bitset_container_t *, c)  // safer downcast
#define const_CAST_bitset(c) CAST(const bitset_container_t *, c)
#define movable_CAST_bitset(c) movable_CAST(bitset_container_t **, c)

typedef uint32_t croaring_refcount_t;

/**
 * A shared container is a wrapper around a container
 * with reference counting.
 */
struct shared_container_s {
    container_t *container;
    uint8_t typecode;
    croaring_refcount_t counter;  // to be managed atomically
};

typedef struct shared_container_s shared_container_t;

#define CAST(type, value) ((type)value)
#define movable_CAST(type, value) ((type)value)

#define CAST_shared(c) CAST(shared_container_t *, c)  // safer downcast
#define const_CAST_shared(c) CAST(const shared_container_t *, c)
#define movable_CAST_shared(c) movable_CAST(shared_container_t **, c)

struct rle16_s {
    uint16_t value;
    uint16_t length;
};

typedef struct rle16_s rle16_t;

/* struct run_container_s - run container bitmap
 *
 * @n_runs:   number of rle_t pairs in `runs`.
 * @capacity: capacity in rle_t pairs `runs` can hold.
 * @runs:     pairs of rle_t.
 */
struct run_container_s {
    int32_t n_runs;
    int32_t capacity;
    rle16_t *runs;
};

typedef struct run_container_s run_container_t;

#define CAST_run(c) CAST(run_container_t *, c)  // safer downcast
#define const_CAST_run(c) CAST(const run_container_t *, c)
#define movable_CAST_run(c) movable_CAST(run_container_t **, c)


/**
 * Add value x
 */
void roaring_bitmap_add(roaring_bitmap_t *r, uint32_t x);

/**
 * Convert array and bitmap containers to run containers when it is more
 * efficient; also convert from run containers when more space efficient.
 *
 * Returns true if the result has at least one run container.
 * Additional savings might be possible by calling `shrinkToFit()`.
 */
bool roaring_bitmap_run_optimize(roaring_bitmap_t *r);

/**
 * Size of the header when serializing (meant to be compatible
 * with Java and Go versions)
 */
uint32_t ra_portable_header_size(const roaring_array_t *ra);

/**
 * TODO: consider implementing:
 *
 * "Compute the xor of 'number' bitmaps using a heap. This can sometimes be
 *  faster than roaring_bitmap_xor_many which uses a naive algorithm. Caller is
 *  responsible for freeing the result.""
 *
 * roaring_bitmap_t *roaring_bitmap_xor_many_heap(uint32_t number,
 *                                                const roaring_bitmap_t **rs);
 */

/**
 * Frees the memory.
 */
void roaring_bitmap_free(const roaring_bitmap_t *r);



/**
 * How many bytes are required to serialize this bitmap.
 *
 * This is meant to be compatible with the Java and Go versions:
 * https://github.com/RoaringBitmap/RoaringFormatSpec
 */
size_t roaring_bitmap_portable_size_in_bytes(const roaring_bitmap_t *r);


/**
 * read a bitmap from a serialized version. This is meant to be compatible
 * with the Java and Go versions.
 * maxbytes  indicates how many bytes available from buf.
 * When the function returns true, roaring_array_t is populated with the data
 * and *readbytes indicates how many bytes were read. In all cases, if the
 * function returns true, then maxbytes >= *readbytes.
 */
bool ra_portable_deserialize(roaring_array_t *ra, const char *buf,
                             const size_t maxbytes, size_t *readbytes);


/**
 * Write a bitmap to a char buffer.  The output buffer should refer to at least
 * `roaring_bitmap_portable_size_in_bytes(r)` bytes of allocated memory.
 *
 * Returns how many bytes were written which should match
 * `roaring_bitmap_portable_size_in_bytes(r)`.
 *
 * This is meant to be compatible with the Java and Go versions:
 * https://github.com/RoaringBitmap/RoaringFormatSpec
 *
 * This function is endian-sensitive. If you have a big-endian system (e.g., a
 * mainframe IBM s390x), the data format is going to be big-endian and not
 * compatible with little-endian systems.
 *
 * When serializing data to a file, we recommend that you also use
 * checksums so that, at deserialization, you can be confident
 * that you are recovering the correct data.
 */
size_t roaring_bitmap_portable_serialize(const roaring_bitmap_t *r, char *buf);


roaring_bitmap_t *roaring_bitmap_portable_deserialize_safe(const char *buf,
                                                           size_t maxbytes);


/**
 * Get the cardinality of the bitmap (number of elements).
 */
uint64_t roaring_bitmap_get_cardinality(const roaring_bitmap_t *r);

/*
 *  Good old binary search.
 *  Assumes that array is sorted, has logarithmic complexity.
 *  if the result is x, then:
 *     if ( x>0 )  you have array[x] = ikey
 *     if ( x<0 ) then inserting ikey at position -x-1 in array (insuring that
 * array[-x-1]=ikey) keys the array sorted.
 */
inline int32_t binarySearch(const uint16_t *array, int32_t lenarray,
                            uint16_t ikey) {
    int32_t low = 0;
    int32_t high = lenarray - 1;
    while (low <= high) {
        int32_t middleIndex = (low + high) >> 1;
        uint16_t middleValue = array[middleIndex];
        if (middleValue < ikey) {
            low = middleIndex + 1;
        } else if (middleValue > ikey) {
            high = middleIndex - 1;
        } else {
            return middleIndex;
        }
    }
    return -(low + 1);
}


/**
 * Get the index corresponding to a 16-bit key
 */
inline int32_t ra_get_index(const roaring_array_t *ra, uint16_t x) {
    if ((ra->size == 0) || ra->keys[ra->size - 1] == x) return ra->size - 1;
    return binarySearch(ra->keys, (int32_t)ra->size, x);
}

/**
 * Retrieves the container at index i, filling in the typecode
 */
inline container_t *ra_get_container_at_index(const roaring_array_t *ra,
                                              uint16_t i, uint8_t *typecode) {
    *typecode = ra->typecodes[i];
    return ra->containers[i];
}

// TODO remove these atomics.  they're here because translate-c chokes on stdatomic.h.
static inline void croaring_refcount_inc(croaring_refcount_t *val) {
    *val += 1;
}

static inline bool croaring_refcount_dec(croaring_refcount_t *val) {
    assert(*val > 0);
    *val -= 1;
    return val == 0;
}

static inline uint32_t croaring_refcount_get(const croaring_refcount_t *val) {
    return *val;
}

// #include <stdatomic.h>
// typedef _Atomic(uint32_t) croaring_refcount_t;

// static inline void croaring_refcount_inc(croaring_refcount_t *val) {
//     // Increasing the reference counter can always be done with
//     // memory_order_relaxed: New references to an object can only be formed from
//     // an existing reference, and passing an existing reference from one thread
//     // to another must already provide any required synchronization.
//     atomic_fetch_add_explicit(val, 1, memory_order_relaxed);
// }

// static inline bool croaring_refcount_dec(croaring_refcount_t *val) {
//     // It is important to enforce any possible access to the object in one
//     // thread (through an existing reference) to happen before deleting the
//     // object in a different thread. This is achieved by a "release" operation
//     // after dropping a reference (any access to the object through this
//     // reference must obviously happened before), and an "acquire" operation
//     // before deleting the object.
//     bool is_zero = atomic_fetch_sub_explicit(val, 1, memory_order_release) == 1;
//     if (is_zero) {
//         atomic_thread_fence(memory_order_acquire);
//     }
//     return is_zero;
// }

// static inline uint32_t croaring_refcount_get(const croaring_refcount_t *val) {
//     return atomic_load_explicit(val, memory_order_relaxed);
// }


/* access to container underneath */
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

/* Get the value of the ith bit.  */
inline bool bitset_container_get(const bitset_container_t *bitset,
                                 uint16_t pos) {
    const uint64_t word = bitset->words[pos >> 6];
    return (word >> (pos & 63)) & 1;
}


/* Check whether x is present.  */
inline bool array_container_contains(const array_container_t *arr,
                                     uint16_t pos) {
    //    return binarySearch(arr->array, arr->cardinality, pos) >= 0;
    // binary search with fallback to linear search for short ranges
    int32_t low = 0;
    const uint16_t *carr = (const uint16_t *)arr->array;
    int32_t high = arr->cardinality - 1;
    //    while (high - low >= 0) {
    while (high >= low + 16) {
        int32_t middleIndex = (low + high) >> 1;
        uint16_t middleValue = carr[middleIndex];
        if (middleValue < pos) {
            low = middleIndex + 1;
        } else if (middleValue > pos) {
            high = middleIndex - 1;
        } else {
            return true;
        }
    }

    for (int i = low; i <= high; i++) {
        uint16_t v = carr[i];
        if (v == pos) {
            return true;
        }
        if (v > pos) return false;
    }
    return false;
}

/**
 * Good old binary search through rle data
 */
inline int32_t interleavedBinarySearch(const rle16_t *array, int32_t lenarray,
                                       uint16_t ikey) {
    int32_t low = 0;
    int32_t high = lenarray - 1;
    while (low <= high) {
        int32_t middleIndex = (low + high) >> 1;
        uint16_t middleValue = array[middleIndex].value;
        if (middleValue < ikey) {
            low = middleIndex + 1;
        } else if (middleValue > ikey) {
            high = middleIndex - 1;
        } else {
            return middleIndex;
        }
    }
    return -(low + 1);
}

/* Check whether `pos' is present in `run'.  */
inline bool run_container_contains(const run_container_t *run, uint16_t pos) {
    int32_t index = interleavedBinarySearch(run->runs, run->n_runs, pos);
    if (index >= 0) return true;
    index = -index - 2;  // points to preceding value, possibly -1
    if (index != -1) {   // possible match
        int32_t offset = pos - run->runs[index].value;
        int32_t le = run->runs[index].length;
        if (offset <= le) return true;
    }
    return false;
}

/**
 * Check whether a value is in a container, requires a typecode
 */
inline bool container_contains(
    const container_t *c, uint16_t val,
    uint8_t typecode  // !!! should be second argument?
) {
    c = container_unwrap_shared(c, &typecode);
    switch (typecode) {
        case BITSET_CONTAINER_TYPE:
            return bitset_container_get(const_CAST_bitset(c), val);
        case ARRAY_CONTAINER_TYPE:
            return array_container_contains(const_CAST_array(c), val);
        case RUN_CONTAINER_TYPE:
            return run_container_contains(const_CAST_run(c), val);
        default:
            assert(false);
            roaring_unreachable;
            return false;
    }
}


/**
 * Check if value is present
 */
inline bool roaring_bitmap_contains(const roaring_bitmap_t *r, uint32_t val) {
    // For performance reasons, this function is inline and uses internal
    // functions directly.
    const uint16_t hb = val >> 16;
    /*
     * the next function call involves a binary search and lots of branching.
     */
    int32_t i = ra_get_index(&r->high_low_container, hb);
    if (i < 0) return false;

    uint8_t typecode;
    // next call ought to be cheap
    container_t *container = ra_get_container_at_index(&r->high_low_container,
                                                       (uint16_t)i, &typecode);
    // rest might be a tad expensive, possibly involving another round of binary
    // search
    return container_contains(container, val & 0xFFFF, typecode);
}
