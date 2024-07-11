const std = @import("std");
const testing = std.testing;
const mimalloc = @import("mimalloc");

test "default_allocator create" {
    const p = try mimalloc.default_allocator.create(u64);
    defer mimalloc.default_allocator.destroy(p);

    p.* = 128;

    try testing.expectEqual(@as(u64, 128), p.*);
}

test "default_allocator arraylist" {
    var list = std.ArrayList(u64).init(mimalloc.default_allocator);
    defer list.deinit();

    for (0..(10 * 1024)) |i| {
        try list.append(i);
    }
}

test "Heap create" {
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();

    const p = try heap.allocator().create(u64);
    defer heap.allocator().destroy(p);

    p.* = 128;

    try testing.expectEqual(@as(u64, 128), p.*);
}

test "Heap arraylist" {
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();

    var list = std.ArrayList(u64).init(heap.allocator());
    defer list.deinit();

    for (0..(10 * 1024)) |i| {
        try list.append(i);
    }
}

test "Heap reset" {
    var heap = try mimalloc.Heap.init();
    defer heap.deinit();

    const cap1 = b: {
        var list = std.ArrayList(u64).init(heap.allocator());
        defer list.deinit();

        for (0..(10 * 1024)) |i| {
            try list.append(i);
        }

        break :b heap.queryCapacity();
    };

    heap.reset();

    const cap2 = b: {
        var list = std.ArrayList(u64).init(heap.allocator());
        defer list.deinit();

        for (0..128) |i| {
            try list.append(i);
        }

        break :b heap.queryCapacity();
    };

    try testing.expect(cap1 > 0);
    try testing.expect(cap2 > 0);
    try testing.expect(cap1 >= cap2);
}

test "Arena init large" {
    const arena = try mimalloc.Arena.init(1024 * 1024, .{});
    var heap = try arena.newHeap();
    defer heap.deinit();

    var list = std.ArrayList(u64).init(heap.allocator());
    defer list.deinit();

    for (0..(10 * 1024)) |i| {
        try list.append(i);
    }
}
