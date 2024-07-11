# Zig Mimalloc Interface

This repository contains idiomatic Zig bindings to the [Mimalloc C Allocator library](https://github.com/microsoft/mimalloc).

The package exposes the bindings in a module named `mimalloc`.

The current mimalloc version used is: 2.1.7.

> [!NOTE]
> The repository contains a copy of the `mimalloc` source code in the `mimalloc` folder
> as a Git subtree.
>
> No changes were made to the source, and this is done to allow building mimalloc using
> the Zig build system without having to download the source during the build.

## Building

The module takes care of compiling and linking the library, translating `zig build` arguments
to the correct C `#define`s. Thus, there is no need to additionally build the mimalloc library.

The following arguments are supported:

* `secure`: Enable security mitigations, see mimalloc source for details. Defaults to `false`,
    the same default used by upstream.
* `debug-full`: Enable full internal heap invariant checking inside mimalloc. This is very
    expensive and is only considered when building with `Debug`.
* `no-debug`: Disable all internal heap invariant checking, defaults to `false` in all modes
    other than `ReleaseFast`.
* `padding`: Enable padding to detect heap block overflows. Defaults to the same value as `secure`.
* `valgrind`: Enable mimalloc Valgrind integration. Defaults to `false`. Requires `valgrind` system
    library to be available.

## Usage

The package provides two allocators: 1) the default allocator, which uses the current thread default
heap to allocate memory; and 2) the [`Heap`] type, representing an individual mimalloc heap, which can
only be used in a single thread.

The default allocator is exposed as [`default_allocator`]:

```zig
var list = std.ArrayList(u64).init(mimalloc.default_allocator);
defer list.deinit();

for (0..(10 * 1024)) |i| {
    try list.append(i);
}
```

[`Heap`] can only allocate memory in the thread they are created, but they can free any pointer allocated
by any other mimalloc's heap (including the default allocator).

```zig
var heap = try mimalloc.Heap.init();
defer heap.deinit();

var list = std.ArrayList(u64).init(heap.allocator());
defer list.deinit();

for (0..(10 * 1024)) |i| {
    try list.append(i);
}
```

Similarly to `std.heap.ArenaAllocator`, [`Heap`] can be used to free a huge number of memory blocks at once
and reused using [`Heap.reset`].

In addition, the module also provides an API to interface with mimalloc's arenas, via the [`Arena`] type. This
API can be used to pre-allocate huge amounts of memory at once. [`Heap`] can be created from arenas using
[`Heap.initIn`] or [`Arena.newHeap`]. Arenas can be both large pages (2/4 MiB) or huge pages (1 GiB) using,
respectively, [`Arena.init`] or [`Arena.initHuge`].

Finally, the module also provides an API to control runtime mimalloc options using [`Option`].

[`Arena.initHuge`]: src/root.zig#L234
[`Arena.init`]: src/root.zig#L225
[`Arena.newHeap`]: src/root.zig#L248
[`Arena`]: src/root.zig#L209
[`Heap.initIn`]: src/root.zig#L85
[`Heap.reset`]: src/root.zig#L160
[`Heap`]: src/root.zig#L70
[`default_allocator`]: src/root.zig#L25
[`Option`]: src/root.zig#L263
