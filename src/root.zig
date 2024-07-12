//! This module provides a idiomatic interface to the mimalloc allocator library.
//!
//! The easiest way to start is using `default_allocator`, which uses the default allocator instances
//! for each thread in the process. This is the same interface as in C or Rust.
//!
//! The module also provides the `Heap` type, which represents a mimalloc heap, allowing more control
//! on how the memory is allocated. This type can be used similarly to the `std`s GPA for more controlled
//! single-thread allocation, but it also can be used similarly to the `std`'s Arena allocator.
//!
//! In addition to these, we also expose the `Arena` API, allowing for more control over where `Heap`s
//! allocate memory.
const builtin = @import("builtin");
const std = @import("std");

/// The raw C mimalloc API.
pub const C = @import("c.zig");

const enable_asserts = builtin.mode == .Debug;

/// Allocator that automatically uses the default heap for the current thread for allocations.
///
/// This has the same behavior as global allocators in C or Rust.
pub const default_allocator: std.mem.Allocator = ga: {
    const VTable = struct {
        fn alloc(
            _: ?*anyopaque,
            len: usize,
            ptr_align: u8,
            _: usize,
        ) ?[*]u8 {
            const alignment = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(ptr_align));
            const ptr = C.mi_malloc_aligned(len, alignment) orelse return null;

            return @ptrCast(ptr);
        }

        fn resize(
            _: ?*anyopaque,
            buf: []u8,
            _: u8,
            new_len: usize,
            _: usize,
        ) bool {
            const ptr = C.mi_expand(buf.ptr, new_len);

            return ptr != null;
        }

        fn free(_: ?*anyopaque, buf: []u8, _: u8, _: usize) void {
            C.mi_free(buf.ptr);
        }
    };

    break :ga .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = VTable.alloc,
            .resize = VTable.resize,
            .free = VTable.free,
        },
    };
};

/// A mimalloc heap.
///
/// A heap can only be used for allocations from the same thread that created it. Blocks can be
/// freed from any thread though.
pub const Heap = struct {
    raw: *C.mi_heap_t,

    /// Initializes a new mimalloc heap.
    ///
    /// Allocations can be only be done in the same thread that created the heap, but
    /// deallocations can be done from any thread.
    pub fn init() std.mem.Allocator.Error!Heap {
        return fromRaw(C.mi_heap_new());
    }

    /// Initializes a new mimalloc heap in the given arena.
    ///
    /// Allocations can be only be done in the same thread that created the heap, but
    /// deallocations can be done from any thread.
    pub fn initIn(arena: Arena) std.mem.Allocator.Error!Heap {
        return fromRaw(C.mi_heap_new_in_arena(arena.id));
    }

    /// Get the default heap for the current thread.
    ///
    /// This is the same heap used for the global allocator and thus usually not necessary.
    pub fn defaultForCurrentThread() std.mem.Allocator.Error!Heap {
        return fromRaw(C.mi_heap_get_default());
    }

    inline fn fromRaw(heap: ?*C.mi_heap_t) std.mem.Allocator.Error!Heap {
        return .{
            .raw = heap orelse return error.OutOfMemory,
        };
    }

    /// Deinitializes the heap and frees all its memory.
    pub fn deinit(h: Heap) void {
        C.mi_heap_destroy(h.raw);
    }

    /// Safely deinitializes the heap, sending any outstanding allocations to the global heap.
    ///
    /// This is useful if the thread sends allocations to other threads and we can't be sure
    /// that they aren't needed anymore.
    pub fn safeDeinit(h: Heap) void {
        C.mi_heap_delete(h.raw);
    }

    /// The allocator for this heap.
    pub fn allocator(h: Heap) std.mem.Allocator {
        const VTable = struct {
            fn alloc(
                ctx: ?*anyopaque,
                len: usize,
                ptr_align: u8,
                _: usize,
            ) ?[*]u8 {
                if (enable_asserts) std.debug.assert(ctx != null);

                const heap: *C.mi_heap_t = @ptrCast(ctx.?);

                const alignment = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(ptr_align));
                const ptr = C.mi_heap_malloc_aligned(heap, len, alignment) orelse return null;

                return @ptrCast(ptr);
            }

            fn resize(
                _: ?*anyopaque,
                buf: []u8,
                _: u8,
                new_len: usize,
                _: usize,
            ) bool {
                return new_len <= C.mi_usable_size(buf.ptr);
            }

            fn free(_: ?*anyopaque, buf: []u8, _: u8, _: usize) void {
                C.mi_free(buf.ptr);
            }
        };

        return .{
            .ptr = h.raw,
            .vtable = &.{
                .alloc = VTable.alloc,
                .resize = VTable.resize,
                .free = VTable.free,
            },
        };
    }

    /// Frees all the blocks in the heap.
    pub fn reset(h: Heap) void {
        C.mi_heap_collect(h.raw, false);
    }

    /// Frees all the blocks in the heap, returning the memory to the OS.
    pub fn release(h: Heap) void {
        C.mi_heap_collect(h.raw, true);
    }

    /// Queries the current memory usage of the heap.
    ///
    /// This will not include internal bookkeeping usage.
    pub fn queryCapacity(h: Heap) usize {
        const S = struct {
            fn visitHeapArea(
                _: ?*const C.mi_heap_t,
                area: [*c]const C.mi_heap_area_t,
                _: ?*anyopaque,
                _: usize,
                arg: ?*anyopaque,
            ) callconv(.C) bool {
                if (enable_asserts) std.debug.assert(arg != null);

                const capacity: *usize = @alignCast(@ptrCast(arg.?));
                capacity.* += area.*.reserved;

                return true;
            }
        };

        var capacity: usize = 0;
        _ = C.mi_heap_visit_blocks(h.raw, false, S.visitHeapArea, &capacity);

        return capacity;
    }

    /// Set this heap as the default heap for the current thread.
    ///
    /// Returns the previous default heap if one was set.
    pub fn setDefault(h: Heap) ?Heap {
        return fromRaw(C.mi_heap_set_default(h.raw)) catch return null;
    }
};

/// Mimalloc uses large (virtual) memory areas, called "arena"s, from the OS to manage its memory.
///
/// This type represents one of these arenas.
///
/// By default, mimalloc uses the first arena with available space.
pub const Arena = struct {
    id: C.mi_arena_id_t,

    /// Options to `Arena.init`.`
    pub const InitOpts = struct {
        /// Allow the use of large OS pages.
        allow_large: bool = true,
        /// Should the memory be initially commited?
        commit: bool = false,
        /// If enabled only heaps associated with this arena can allocate on it.
        exclusive: bool = false,
    };

    /// Options to `Arena.initHuge`.
    pub const HugeOpts = struct {
        /// If enabled only heaps associated with this arena can allocate on it.
        exclusive: bool = false,
        /// The NUMA node where the memory will be reserved.
        numa_node: c_int = -1,
        /// Maximum time to wait for the memory to be reserved.
        timeout_msecs: usize = 0,
    };

    /// Initializes an arena with the given size.
    pub fn init(size: usize, opts: InitOpts) !Arena {
        var arena: C.mi_arena_id_t = undefined;

        const err = C.mi_reserve_os_memory_ex(size, opts.commit, opts.allow_large, opts.exclusive, &arena);

        return if (err == 0) .{ .id = arena } else error.OutOfMemory;
    }

    /// Initializes an arena with the given number of huge OS pages.
    pub fn initHuge(pages: usize, opts: HugeOpts) !Arena {
        var arena: C.mi_arena_id_t = undefined;

        const err = C.mi_reserve_huge_os_pages_at_ex(pages, opts.numa_node, opts.timeout_msecs, opts.exclusive, &arena);

        switch (err) {
            0 => return .{ .id = arena },
            @intFromEnum(std.posix.E.NOMEM) => return error.OutOfMemory,
            @intFromEnum(std.posix.E.TIMEDOUT) => return error.Timeout,
            else => unreachable,
        }
    }

    /// Creates a new heap in this arena.
    pub fn newHeap(arena: Arena) !Heap {
        return Heap.initIn(arena);
    }

    /// Get the current capacity of the arena.
    pub fn capacity(arena: Arena) usize {
        var size: usize = undefined;

        _ = C.mi_arena_area(arena.id, &size);

        return size;
    }
};

/// Mimalloc runtime options.
pub const Option = enum(u5) {
    /// Print error messages.
    show_errors = C.mi_option_show_errors,
    /// Print statistics on termination.
    show_stats = C.mi_option_show_stats,
    /// Print verbose messages.
    verbose = C.mi_option_verbose,
    /// Issue at most N error messages.
    max_errors = C.mi_option_max_errors,
    /// Issue at most N warning messages.
    max_warning = C.mi_option_max_warnings,
    /// Reserve N huge OS pages (1 GiB pages) at startup.
    reserve_huge_os_pages = C.mi_option_reserve_huge_os_pages,
    /// Reserve N huge OS pages at a specific NUMA node N.
    reserve_huge_os_pages_at = C.mi_option_reserve_huge_os_pages_at,
    /// Reserve specified amount of OS memory in an arena at startup (internally this value is in KiB; use `mi_option_get_size`).
    reserve_os_memory = C.mi_option_reserve_os_memory,
    /// ALlow large (2 or 4 MiB) OS pages, implies eager commit.
    ///
    /// If false, also disables THP for the process.
    allow_large_os_pages = C.mi_option_allow_large_os_pages,
    /// Should a memort puge decommit?
    ///
    /// Set to 0 to use memory reset on a purge, instead of decommit.
    purge_decommits = C.mi_option_purge_decommits,
    /// Initial memory size for arena reservation (= 1 GiB on 64-bit) (internally this value is in KiB; use `mi_option_get_size`).
    arena_reserve = C.mi_option_arena_reserve,
    /// Tag used for OS logging (macOS only for now).
    os_tag = C.mi_option_os_tag,
    /// Retry on out-of-memory for N milliseconds (=400), set to 0 to disable retries.
    retry_on_oom = C.mi_option_retry_on_oom,
    /// Eager commit segments after `eager_commit_delay` segments? (=1)
    eager_commit = C.mi_option_eager_commit,
    /// The first N segments per thread are not eagerly committed (but per page in the segment on demand).
    eager_commit_delay = C.mi_option_eager_commit_delay,
    /// Eager commit arena? (=2)
    ///
    /// use 2 to enable just on overcommit systems.
    arena_eager_commit = C.mi_option_arena_eager_commit,
    /// Immediately purge delayed purges on thread termination.
    abandoned_page_purge = C.mi_option_abandoned_page_purge,
    /// Memort purging is delayed by N milliseconds (=10).
    ///
    /// Use 0 for immediate purging or -1 for no purging at all.
    purge_delay = C.mi_option_purge_delay,
    /// 0 = use all available NUMA nodes, otherwise use at most N nodes.
    use_numa_nodes = C.mi_option_use_numa_nodes,
    /// 1 = do not use OS memory for allocation (but only programmatically reserved arenas).
    disallow_os_alloc = C.mi_option_disallow_os_alloc,
    /// Max. percenteage of the abandoned segments can be reclaimed per try. (=10%)
    max_segment_reclaim = C.mi_option_max_segment_reclaim,
    /// If set, release all memory on exit; sometimes used for dynamic unloading but can be unsafe.
    destroy_on_exit = C.mi_option_destroy_on_exit,
    /// Multipler for `purge_delay` for the purging delay for arenas. (=10)
    arena_purge_mult = C.mi_option_arena_purge_mult,
    /// Allow to reclaim an abandoned segment on a free? (=1)
    abandoned_reclaim_on_free = C.mi_option_abandoned_reclaim_on_free,
    /// Extend purge delay on each subsequent delay. (=1)
    purge_extend_delay = C.mi_option_purge_extend_delay,
    /// 1= do not use arena's for allocation (except if using specific arena id's).
    disallow_arena_alloc = C.mi_option_disallow_arena_alloc,

    pub fn disable(o: Option) void {
        C.mi_option_disable(@intFromEnum(o));
    }

    pub fn enable(o: Option) void {
        C.mi_option_enable(@intFromEnum(o));
    }

    pub fn get(o: Option) u32 {
        return @intCast(C.mi_option_get(@intFromEnum(o)));
    }

    pub fn getSize(o: Option) usize {
        return C.mi_option_get_size(@intFromEnum(o));
    }

    pub fn isEnabled(o: Option) bool {
        return C.mi_option_is_enabled(@intFromEnum(o));
    }

    pub fn set(o: Option, value: u32) void {
        C.mi_option_set(@intFromEnum(o), value);
    }

    pub fn setDefault(o: Option, value: u32) void {
        C.mi_option_set_default(@intFromEnum(o), value);
    }

    pub fn setEnabled(o: Option, enabled: bool) void {
        C.mi_option_set_enabled(@intFromEnum(o), enabled);
    }

    pub fn setEnabledDefault(o: Option, enabled: bool) void {
        C.mi_option_set_enabled_default(@intFromEnum(o), enabled);
    }
};
