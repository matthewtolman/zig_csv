# ZCSV (Zig CSV)

> Supported Zig versions: 0.13.0, 0.14.0-dev.1951+857383689

ZCSV is a CSV parser and writer library. The goal is to provide both writers and parsers which are allocation free while also having a parser which does use memory allocations for a more developer-friendly interface.

This parser does allow for CRLF and LF characters to be inside quoted fields. It also interprets both unquoted CRLF and unquoted LF characters as newlines. CR characters without a following LF character is considered an invalid line ending.

Note: All parsers do operate either line-by-line or field-by-field for all operations, including validation. This means that partial reads may happen when the first several rows of a file are valid but there is an error in the middle.

```zig
// Basic usage writing

const zcsv = @import("zcsv");
const std = @import("std");

// ....

// Get a writer
const stdout = std.io.getStdOut().writer();

// Write headers
zcsv.writer.row(stdout, .{"field1", "field2", "field3", "field4"});

// Write a row
for (rowData) |elem| {
    zcsv.writer.row(stdout, .{elem.f1, elem.f2, elem.f3, elem.f4});
}

// Basic usage reading

// Get an allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Get a reader
const stdin = std.io.getStdIn().reader();

// Make a parser
var parser = zcsv.map_sk.init(allocator, stdin, .{});
defer parser.deinit();

// Iterate over rows
while (parser.next()) |row| {
    // Free row memory
    defer row.deinit();

    const id_field = row.data().get("id") orelse return error.MissingIdColumn;
    const id = id_field.asInt(i64, 10) catch {
        return error.InvalidIdValue;
    } orelse return error.MissingIdValue;

    std.debug.print("ID: {}\n", id);
}

// Zero-allocation parsing of an in-memory data structure
const csv =
    \\productid,productname,productsales
    \\1238943,"""Juice"" Box",9238
    \\3892392,"I can't believe it's not chicken!",480
    \\5934810,"Win The Fish",-
;

var parser = zcsv.slice.rows.init(csv, .{});

while (parser.next()) |row| {
    // iterate over fields
    var iter = row.iter();

    while (iter.next()) |field| {
        // we need to manually decode fields
        // we can opt out of decoding work for ignored fields
        var decode_bytes: [256]u8 = undefined;
        var decode_buff = std.io.fixedBufferStream(&decode_bytes);
        try field.decode(decode_buff.writer());

        const decoded = decode_buff.getWritten();
        // use decoded here
    }
}
// check for errors
if (parser.err) |err| {
    return err;
}
```

## Installation

1. Add zcsv as a dependency in your `build.zig.zon`:
```bash
zig fetch --save git+https://github.com/matthewtolman/zig_csv#main
```

2. In your `build.zig`, add the `zcsv` module as a dependency to your program:
```zig
const zcsv = b.dependency("zcsv", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zcsv", zcsv.module("zcsv"));
```

## Examples

The `examples/` folder holds a list of various examples. All of those examples are ran as part of the `zig build test` command. Each example also has it's own command to run just that example (e.g. `zig build example_1`).

Examples will use the `test.csv` file by default (assuming they read a file from disk). This file is provided to demonstrate different parsing scenarios.

## Writing CSV

Writing CSV files is done line-by-line to a writer. The writing is done without a dynamic memory allocation. Writing is done by using the `writer.row()` method.

```zig
// Basic usage

const zcsv = @import("zcsv");
const std = @import("std");

// ....

// Get a writer
const stdout = std.io.getStdOut().writer();

// Write headers
zcsv.writer.row(stdout, .{"field1", "field2", "field3", "field4"});

// Write a row
for (rowData) |elem| {
    zcsv.writer.row(stdout, .{elem.f1, elem.f2, elem.f3, elem.f4});
}
```

## Reading a CSV

There are several patterns for reading CSV files provided, including allocating and non-allocating parsers. In general, non-allocating parsers will be faster (especially the `slice` and `stream_fast` parsers), but the speed comes at the cost of flexibility and ease-of-use. For instance, the array parser must have the entire CSV file stored in memory, whereas the column and map parsers may operator on a reader directly. Additionally, the non-allocating parsers do not automatically unescape CSV values whereeas allocating parsers do.

> Note: None of the parsers trim whitespace from any fields at any point.

We'll discuss parsers from the most feature rich but slowest to the most restrictive but fastest.

### Map Parser
The map parsers will perform memory allocations as they are creating dynamically allocated hash maps with all of the fields. The map parsers also assume that the first row is a header row. If that assumption is not the case, then it is recommended to use the column parser.

Each row owns it's own memory with the possible exception of the map keys. The `map_sk` parser will share the map keys across all the rows and the parser itself. When the `map_sk` parser is deinitialized, then the map key memory will be freed all at once. If rows need to own their own keys, then use the `map_ck` which will copy the key memory for every row.

The slices returned by the map have their underlying memory owned by the row. Once the row memory is freed then the field memory is freed as well. If this is undesireable, there are ways to clone the field memory (`clone`, `cloneAlloc`) or "move" the memory (`detachMemory`). For more information, see the section "Memory Lifetimes".

Additionally, map parsers will try to parse the header row immediately as part of their initialization. This means that their init function may fail (e.g. allocation error, reader error, invalid header, etc). It also means that if the underlying reader can block then the initialization method may block as well. Do keep this in mind as a potential side effect. Map parsers are the only provided parsers which eagerly parse, so if the side effect is undesireable you may use any of the other parsers (e.g. column parser).

Quoted strings will be unescaped automatically.

Below is an example of using a map parser:

```zig
// Basic usage

const zcsv = @import("zcsv");
const std = @import("std");

// ...

// Get an allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Get a reader
const stdin = std.io.getStdIn().reader();

// Make a parse
// If we want to copy headers, simply change map_sk to map_ck
// We need a try since we will try to parse the headers immediately, which may fail
var parser = try zcsv.map_sk.init(allocator, stdin, .{});
// Note: map parsers must be deinitialized!
// They are the only parsers (currently) which need to be deinitialized
defer parser.deinit();

// We're building a list of user structs
var res = std.ArrayList(User).init(alloc);
errdefer res.deinit();

// Iterate over rows
while (parser.next) |row| {
    defer row.deinit();

    // Validate we have our columns
    const id = row.data().get("userid") orelse return error.MissingUserId;
    const name = row.data().get("name") orelse return error.MissingName;
    const age = row.data().get("age") orelse return error.MissingAge;

    // Validate and parse our user
    try res.append(User{
        .id = id.asInt(i64, 10) catch {
            return error.InvalidUserId;
        } orelse return error.MissingUserId,
        .name = try name.clone(allocator),
        .age = age.asInt(u16, 10) catch return error.InvalidAge,
    });
}
```

### Column Parser

The column parser will parse a CSV file and make fields accessible by index. The memory for a row and its fields are held by the row (i.e. calling `row.deinit()` will deallocate all associated memory). Additionally, the parser will unescape quoted strings automatically (i.e. "Johnny ""John"" Doe" will become `Johnny "John" Doe`).

Lines are parsed one-by-one allowing for streaming CSV files. It also allows early termination of CSV parsing. Below is an example of parsing CSVs with the parser:

```zig
// Basic usage

const zcsv = @import("zcsv");
const std = @import("std");

// ...

// Get an allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Get a reader
const stdin = std.io.getStdIn().reader();

// Make a parser
var parser = zcsv.column.init(allocator, stdin, .{});

// Iterate over rows
while (parser.next()) |row| {
    // Free row memory
    defer row.deinit();

    std.debug.print("\nROW: ", .{});

    var fieldIter = row.iter();
    // Can also do for(row.fields()) |field|
    while (fieldIter) |field| {
        // No need to free field memory since that is handled by row.deinit()

        // .data() will get the slice for the data
        std.debug.print("\t{s}", .{field.data()});
        
        // We can also convert a field to ints, floats, and bools
        // These conversions will be nullable
        // The strings "" and "-" will be interpreted as null
        if (field.asInt(i64, 10) catch null) |i| {
            std.debug.print("(int:{d})", .{i});
        }

        // asInt is used for signed and unsigned ints
        if (field.asInt(u64, 10) catch null) |u| {
            std.debug.print("(uint:{d})", .{u});
        }

        // asFloat is used for floats
        if (field.asFloat(f64) catch null) |f| {
            std.debug.print("(float:{d})", .{f});
        }

        // asBool handles the strings
        // "y", "yes", "true", "1", "0", "false", "no", "no"
        if (field.asBool() catch null) |b| {
            std.debug.print("(bool:{})", .{b});
        }

        // asSlice will be a nullable string
        // If the underlying value is "" or "-" then asSlice will return null
        if (field.asSlice() catch null) |s| {
            std.debug.print("(slice:{s})", .{s});
        }
    }
}

// Check for a parsing error
if (column.err) |err| {
    return err;
}

```

### Slower Streaming Parser (zero-allocation)

The field streamer will write each filed into a writer. It does not try to indicate the end of a row to the writer. Instead, it exposes state in the form of the `atRowEnd` method.

There are two sub-approaches depending on validation. The first is partial fields (through `FieldStreamPartial`) and the next is fully-valid fields only (through `FieldStream`).

> Note: the Parser uses the `FieldStream` behind the scenes

With the partial fields each byte is written as it is processed without buffering. This means that if there is an invalid field (e.g. `John"Doe"`), then some of the data will be written to the writer before the parse error is detected. However, this also means there is no internal buffer limiting field size or taking up stack memory. A "no infinite loop" limit is imposed of 2^32 bytes per field. This may be adjusted if desired (for whatever reason).

In contrast, the fully-valid field only model will buffer fields internally and ensure they are valid before writing them to the stream. When it does write to the writer, it will write the entire field at once. This also has the advantage that writers which require memory allocations will perform fewer allocations on average.

However, because `FixedStream` needs an in-memory buffer we do need to keep that buffer in the stack. The size of the buffer must be provided at compile time.

Both field streamers also provide a row count with the `row` property.

Field streamers are primarily meant to be used inside a more complex parser. As such, their usage and interface is less user-friendly, and they can offer more detail than is necessary. When possible, use one of the other provided parsers.

Below is example usage of the partial field stream:

```zig
const zcsv = @import("zcsv");
const std = @import("std");

/// ...

// Get reader and writer
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

// no allocator needed
var parser = zcsv.stream.FieldStreamPartial(
    @TypeOf(stdin),
    @TypeOf(stdout),
).init(stdin, .{});

std.debug.print("\nRow: ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
//
// next does throw if it has an error.
// next will return `false` when it hits the end of the input
while (!parser.done()) {
    try parser.next(stdout);
    // Do whatever you need to here for the field

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row, just that we're about to move
    if (column.atRowEnd()) {
        std.debug.print("\nRow: ", .{});
    }
}
```

Below is example usage of the full field stream. You'll notice that there is barely any difference. This is intetional since we want to be able to switch between them quickly.

```zig
const zcsv = @import("zcsv");
const std = @import("std");

/// ...

// Get reader and writer
const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdOut().writer();

var parser = zcsv.stream.FieldStream(
    @TypeOf(stdin),
    @TypeOf(stdout),
    1_024, // Internal buffer size
).init(stdin); // No second parameter here

std.debug.print("\nRow: ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
//
// next does throw if it has an error.
// next will return `false` when it hits the end of the input
while (!parser.done()) {
    try parser.next(stdout);
    // Do whatever you need to here for the field

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row, just that we're about to move
    if (column.atRowEnd()) {
        std.debug.print("\nRow: ", .{});
    }
}
```

This parser operates at a reasonable speed, able to parse around 12MB in 150ms on my 2019 MacBook Pro. This parser forms the basis of all the allocating parsers. I don't use any of the faster parsers since the volume of memory allocations done by the column and map parsers outweighs the performance benefits in my testing, and the other parsers are ether more inflexible (e.g. raw parser) or way harder to verify correctness (e.g. fast streaming).

### Raw Parser (zero-allocation)

The raw parser is a zero-allocation parser. Unlike the allocating parsers, this parser does not unescape quoted strings automatically. Additionally, this parser must have the CSV data loaded into an array or slice of memory.

This parser operates by identifying the boundaries of each field start and end and returns slices to those boundaries. This means if you have the CSV row `"Jack ""Jim"" Smith",12` you will end up with the fields `"Jack ""Jim"" Smith"` and `12`. (Note that the surrounding quotes are part of the resulting output).

It does provide methods for optional decoding (e.g. asInt, decode, etc).

Below is an example of how to use the array column.

```zig
const zcsv = @import("zcsv");

/// ...

const csv =
    \\userid,name,age
    \\1,"Johny ""John"" Doe",23
    \\2,Jack,32
;

// No allocator needed
var parser = zcsv.slice.init(csv);

// Will print:
// Row: Field: userid Field: name Field: age 
// Row: Field: 1 Field: "Johny ""John"" Doe" Field: 23 
// Row: Field: 2 Field: Jack Field: 32 
//
// Notice that the quotes are included in the output
while (parser.next()) |row| {
    // No memory deallocation needed!

    std.io.debug("\nRow: ");

    // Get an iterator for the fields in a row
    var iter = row.iter();

    // Iterate over the fields
    while (iter.next()) |f| {
        std.io.debug("Field: {s} ", f);

        // Unescape the string
        var buff: u8[512] = undefined;
        var fbuff = std.io.fixedBufferStream(&buff);
        f.decode(fbuff.writer());
        std.io.debug("Decoded: {s} ", f.getWritten());
    }
}

// Detect parse errors
if (column.err) |err| {
    return err;
}
```

This parser is faster than the slow streaming parser. It can parse 12MB in about 45ms on my MacBook.

### Slice Row Parser (zero-allocation, fast)

The slice row parser is similar to the raw parser in terms of capabilities and limitations. It iterates over rows, and it requires the CSV to be in-memory. The biggest difference is that it uses SIMD techniques (though it doesn't use explicit SIMD vectorization commands). This allows it to be faster. It can parse 12MB in about 34ms on my MacBook. This is not the fastest parser, but it is one of the fastest.

Example usage:

```zig
const csv =
    \\productid,productname,productsales
    \\1238943,"""Juice"" Box",9238
    \\3892392,"I can't believe it's not chicken!",480
    \\5934810,"Win The Fish",-
;
const stderr = std.io.getStdErr().writer();

var parser = zcsv.slice.rows.init(csv, .{});
std.log.info("Enter CSV to parse", .{});

try stderr.print("> ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
while (parser.next()) |row| {
    // iterate over fields
    var iter = row.iter();

    while (iter.next()) |field| {
        // we need to manually decode fields
        try field.decode(stderr);
    }
    try stderr.print("\n> ", .{});
}
// check for errors
if (parser.err) |err| {
    return err;
}
```

### Fast Streaming Parser (zero-allocation, fast)

The fast streaming parser uses SIMD techniques (though it does not use explicit SIMD vectorization). It can acheive speeds faster than the parsers discussed above (though it's not the fastest in the library).

However, I have found that excessive memory allocations (such as with the allocating parsers) can wipe out those speed gains with the general purpose allocator, even when using the release fast compilation mode. Additionally, this parser has been the trickiest for me to write, and I'm not 100% confident in its correctness yet. As such, I've opted to use the slower streaming parser as the basis for my allocating parsers since it's easier to verify correctness, and it performs about the same.

If you wish to use the fast streaming parser directly, you can. Below is an example on how to use it:

```zig
const reader = std.io.getStdIn().reader();

var tmp_bytes: [1024]u8 = undefined;
var tmp_buff = std.io.fixedBufferStream(&tmp_bytes);
var parser = zcsv.stream_fast.init(reader, @TypeOf(tmp_buff).Writer, .{});
std.log.info("Enter CSV to parse", .{});

try stderr.print("> ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
while (!parser.done()) {
    // We have to manually decode the field
    try parser.next(tmp_buff.writer());
    try zcsv.core.decode(tmp_buff.getWritten(), stderr);
    // Do whatever you need to here for the field

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row, just that we're about to move
    if (parser.atRowEnd()) {
        if (!parser.done()) {
            try stderr.print("\n> ", .{});
        } else {
            try stderr.print("\nClosing...\n", .{});
        }
    } else {
        try stderr.print("\t", .{});
    }
}

```

The speed of this parser is pretty good, with 12MB parsing in about 22ms.

### Slice Field Parser (zero-allocation, fast)

Like the slice row parser, this parser also uses SIMD and requires the CSV to be in memory. However, this parser only iterates over fields rather than rows. It relies on a value indicating whether a field is at the end of a row to indicate that we've reached the end. This optimization means that it only has to examine a set of bytes once, whereas the slice row parser examines rows twice (once to iterate over rows, once to iterate over fields). This performance improvement makes it the fastst parser in this library. I was able to parse 12MB in about 17ms on my MacBook.

As for the SIMD-based parsers, this is the best tested and most correct of the parsers. If you want a fast parser, this is probably it. The next best one would be the slice row parser since that uses this parser under the hood.

Usage example:

```zig
// Get reader and writer
const csv =
    \\productid,productname,productsales
    \\1238943,"""Juice"" Box",9238
    \\3892392,"I can't believe it's not chicken!",480
    \\5934810,"Win The Fish",-
;
const stderr = std.io.getStdErr().writer();

var parser = zcsv.slice.fields.init(csv, .{});
std.log.info("Enter CSV to parse", .{});

try stderr.print("> ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
while (parser.next()) |f| {
    // Do whatever you need to here for the field
    try f.decode(stderr);

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row, just that we're about to move
    if (f.row_end) {
        if (!parser.done()) {
            try stderr.print("\n> ", .{});
        } else {
            try stderr.print("\nClosing...\n", .{});
        }
    } else {
        try stderr.print("\t", .{});
    }
}

// check for errors
if (parser.err) |err| {
    return err;
}
```

## Parser Limit Options

All of the parsers have some sort of "infinite loop protection" built in. Generally, this is a limit to 65,536 maximum loop iteration (unless there's an internal stack buffer, then the internal stack buffer will dictate the limit). This limit can be changed by adjusting the options passed into the parser. This is also why all parsers take options (either comptime or runtime options).

## Memory Lifetimes

Slices returned by allocated fields have their underlying memory tied to the lifetime of the row's memory. This means the following will result in a use-after-free:

```zig
// Use after free example, Don't do this!

var firstField: []const u8 = undefined;

outer: while (parser.next()) |row| {
    // Free row memory
    defer row.deinit();

    var fieldIter = row.iter();
    while (fieldIter) |field| {
        firstField = field.data();
        break :outer;
    }
}

// Oh no! Use after free!
std.debug.print("{s}", .{firstField});
```

If you need to have the field memory last past the row lifetime, then use the `clone` method. `clone` takes in an allocator to use for cloning the memory to. Below is an example:

```zig
// get allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Copy the memory

var firstField: ?std.ArrayList(u8) = undefined;
defer {
    if (firstField) |f| {
        f.deinit();
    }
}

while (parser.next()) |row| {
    // Free row memory
    defer row.deinit();

    if (row.fields().len > 0) {
        // Memory is no longer tied to the row
        firstField = row.fields()[0].clone(allocator);

        // alternatively, we could do the following
        // firstField = row.fields()[0].cloneAlloc(allocator);
        break;
    }
}

// Oh no! Use after free!
std.debug.print("{s}", .{firstField});
```

> Note: the `detachMemory` method was removed in version 0.4.0. `detachMemory` required that every field get a separate memory allocation which was rather slow. In version 0.4.0 the field memory was merged with the row memory which resulted in a significant speed up, but it also meant that simply detaching field memory was no longer possible.

## Recommended Parser Selection

If you're app doesn't need to parse massive CSV files quickly, and you're okay with memory allocations per field, then I'd recommend using one of the allocating parsers since they are more ergonomic for usage. My recommendation is to use the map parsers whenever you have a header, and use the column parser when you don't.

For the map parsers, I would generally recommend using `map_sk` unless you have a need for the map to outlive the row. Most of the time though, a common pattern is to use the map just long enough to populate a struct and then to use the struct instead of a map. This means that the map doesn't need to outlive the row since the struct replaces the keys.

If you have restrictions which makes the allocating parsers infeasible, then I'd recommend using either one of the slice parsers (slice array or slice field), or one of the streaming parsers. I'd use the slice parsers if you can fit the CSV into memory. If loading into memory isn't an option, then I'd use one of the field streaming parsers.

## License

This code is licensed under the MIT license.

