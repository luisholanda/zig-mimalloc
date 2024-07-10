const mimalloc = @import("mimalloc");

test {
    const ref = @import("std").testing.refAllDeclsRecursive;
    ref(mimalloc.Arena);
    ref(mimalloc.Heap);
    ref(mimalloc.Option);
    _ = mimalloc.default_allocator;
}
