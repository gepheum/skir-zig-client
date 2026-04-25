const std = @import("std");

/// A slice of `Spec.Value` items with lazy key-based lookup.
///
/// The key index is built on first lookup and cached for subsequent calls.
///
/// `Spec` must declare:
/// - `Value`: the element type,
/// - `Key`: the key type (must be hashable by `std.AutoHashMap`),
/// - `fn getGet(Value) Key`: extracts the key from an element,
/// - `fn defaultValue() *Value`: returns a pointer to a sentinel value used
///   by `findByKeyOrDefault` when no match is found.
pub fn KeyedArray(comptime Spec: type) type {
    const T = Spec.Value;
    const K = Spec.Key;

    return struct {
        const Self = @This();

        pub const Value = T;
        pub const Key = K;

        /// Full slice of values. Callers may read this directly for
        /// sequential access without paying the indexing cost.
        values: []T,
        allocator: std.mem.Allocator,

        key_index: ?std.AutoHashMap(K, *T) = null,
        mutex: std.Thread.Mutex = .{},

        /// Creates a `KeyedArray` that wraps the given slice.
        ///
        /// Ownership of `values` remains with the caller; the `KeyedArray`
        /// only borrows it.
        pub fn init(allocator: std.mem.Allocator, values: []T) Self {
            return .{
                .values = values,
                .allocator = allocator,
            };
        }

        /// Returns an empty `KeyedArray` with no elements.
        pub fn empty() Self {
            return .{
                .values = @constCast(&[_]T{}),
                .allocator = std.heap.page_allocator,
            };
        }

        /// Frees the internal key index if it has been built.
        ///
        /// Does **not** free `values`; the caller retains that responsibility.
        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.key_index) |*map| {
                map.deinit();
                self.key_index = null;
            }
        }

        fn ensureIndexed(self: *Self) !void {
            if (self.key_index != null) return;

            var map = std.AutoHashMap(K, *T).init(self.allocator);
            errdefer map.deinit();

            for (self.values) |*value| {
                try map.put(Spec.getGet(value.*), value);
            }

            self.key_index = map;
        }

        /// Returns a pointer to the element whose key equals `key`, or `null`
        /// if no such element exists.
        ///
        /// The key index is built on the first call and reused on subsequent
        /// ones. Thread-safe.
        pub fn findByKey(self: *Self, key: K) !?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.ensureIndexed();
            return self.key_index.?.get(key);
        }

        /// Returns a pointer to the element whose key equals `key`, or the
        /// sentinel value from `Spec.defaultValue()` if no match is found.
        pub fn findByKeyOrDefault(self: *Self, key: K) !*T {
            if (try self.findByKey(key)) |value| return value;
            return Spec.defaultValue();
        }
    };
}

test "KeyedArray indexes lazily and returns defaults" {
    const Entry = struct {
        id: i32,
        value: i32,
    };

    const EntrySpec = struct {
        pub const Value = Entry;
        pub const Key = i32;

        pub fn getGet(entry: Entry) i32 {
            return entry.id;
        }

        var fallback: Entry = .{ .id = -1, .value = 0 };

        pub fn defaultValue() *Entry {
            return &fallback;
        }
    };

    var values = [_]Entry{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
    };

    var keyed = KeyedArray(EntrySpec).init(std.testing.allocator, values[0..]);
    defer keyed.deinit();

    const found = (try keyed.findByKey(2)).?;
    try std.testing.expectEqual(@as(i32, 20), found.value);

    const missing = try keyed.findByKey(99);
    try std.testing.expect(missing == null);

    const fallback = try keyed.findByKeyOrDefault(42);
    try std.testing.expectEqual(@as(i32, -1), fallback.id);
    try std.testing.expectEqual(@as(i32, 0), fallback.value);
}

test "KeyedArray empty creates an empty container" {
    const Entry = struct {
        id: i32,
    };

    const EntrySpec = struct {
        pub const Value = Entry;
        pub const Key = i32;

        pub fn getGet(entry: Entry) i32 {
            return entry.id;
        }

        var fallback: Entry = .{ .id = -1 };

        pub fn defaultValue() *Entry {
            return &fallback;
        }
    };

    const keyed = KeyedArray(EntrySpec).empty();
    try std.testing.expectEqual(@as(usize, 0), keyed.values.len);
}
