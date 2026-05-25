// entire file content ...

pub const Rle16 = extern struct { value: u16, length: u16 };

/// a bitset of u8 which can represent MAX_CONTAINERS. answers which containers are
/// run containers: `[MAX_CONTAINERS]u8`.
pub const RunFlags = [constants.MAX_CONTAINERS]u8;

// ... rest of the code ...
