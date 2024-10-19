# ZCSV (Zig CSV)

> Supported Zig versions: 0.13.0, 0.14.0-dev

ZCSV is a CSV parser and writer library. The goal is to provide both writers and parsers which are allocation free while also having a parser which does use memory allocations for a more developer-friendly interface.

Note: All parsers do operate line-by-line for all operations, including validation. This means that partial reads may happen when the first several rows of a file are valid but there is an error in the middle.

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
var parser = zcsv.map_sk.init(allocator, stdin);
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
```

## Installation

1. Add zcsv as a dependency in your `build.zig.zon`:
```bash
zig fetch --save git+https://github.com/matthewtolman/zig_csv#main
```

2. In your `build.zig`, add the `httpz` module as a dependency to your program:
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

There are several patterns for reading CSV files provided. There are several zero allocation methodologies (raw, field streaming) and a few allocating strategies (map, column parser). In general, most develoeprs will want to use the allocating parser strategy.

> Note: None of the parsers trim whitespace from any fields at any point.

### Map Parser
The map parsers will perform memory allocations as they are creating dynamically allocated hash maps with all of the fields. The map parsers also assume that the first row is a header row. If that assumption is not the case, then it is recommended to use the column parser.

Each row owns it's own memory with the possible exception of the map keys. The `map_sk` parser will share the map keys across all the rows and the parser itself. When the `map_sk` parser is deinitialized, then the map key memory will be freed all at once. If rows need to own their own keys, then use the `map_ck` which will copy the key memory for every row.

The slices returned by the map have their underlying memory owned by the row. Once the row memory is freed then the field memory is freed as well. If this is undesireable, there are ways to clone the field memory (`clone`, `cloneAlloc`) or "move" the memory (`detachMemory`). For more information, see the section "Memory Lifetimes".

Additionally, map parsers will try to parse the header row immediately as part of their initialization. This means that their init function may fail (e.g. allocation error, reader error, invalid header, etc). It also means that if the underlying reader can block then the initialization method may block as well. Do keep this in mind as a potential side effect. Map parsers are the only provided parsers which eagerly parse, so if the side effect is undesireable you may use any of the other parsers (e.g. column parser).

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

// Make a parser
// If we want to copy headers, simply change map_sk to map_ck
// We need a try since we will try to parse the headers immediately, which may fail
var parser = try zcsv.map_sk.init(allocator, stdin);
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
        .name = try name.clone(),
        .age = age.asInt(u16, 10) catch return error.InvalidAge,
    });
}
```

### Column Parser

The column parser will perform memory allocations. The memory allocations have a memory lifetime tied to the returned row (i.e. calling `row.deinit()` will deallocate all associated memory). Additionally, the parser will unescape quoted strings (i.e. "Johnny ""John"" Doe" will become `Johnny "John" Doe`).

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
var parser = zcsv.column.init(allocator, stdin);

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

#### Memory Lifetimes

Slices returned by fields have their underlying memory tied to the lifetime of the row's memory. This means the following will result in a use-after-free:

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

If you need to have the field memory last past the row lifetime, then use the `clone` or `cloneAlloc` method. `clone` will use the same allocator that the field was allocated with, which does make it undesireable when an `ArenaAllocator` was originally used for the parsing. In those cases, `cloneAlloc` is provided which allows the copy to use a distinct allocator from the original. Below is an example:

```zig
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
        firstField = row.fields()[0].clone();

        // alternatively, we could do the following
        // firstField = row.fields()[0].cloneAlloc(allocator);
        break;
    }
}

// Oh no! Use after free!
std.debug.print("{s}", .{firstField});
```

This does incur a full memory copy for every field though. For most use cases, the memory and CPU penalty is probably insignificant compared to other bottlenecks.

However, if the full copy is undesireable then there is an alternative method called `detachMemory`. What `detachMemory` does is it "moves" the field memory from the row to the caller. This allows us to extend the lifetime of the field memory while clearing the row memory. Do note that we will be using the original field memory, which means we will be holding memory in the original allocator. This detail can be significant if we are using an arena allocator.

One important note is that detachMemory does require that the row be mutable, and that we use the `fieldsMut` method is used rather than `fields` or `iter` methods.

Below is a detach memory example.

```zig
// Detach memory example

var firstField: ?std.ArrayList(u8) = null;

// Make sure we free our memory
defer {
    if (firstField) |f| {
        f.deinit();
    }
}

// The while(...) |...| pattern gives consts, but for detaching memory
// we need to make sure we are using mutable memory
// There may be a better pattern for this, but I'm not familiar with it yet
var row: Row = undefined;
while(true) {
    row = parser.next() orelse break;

    // Free row memory
    defer row.deinit();

    if (row.fields().len > 0) {
        // Memory is no longer tied to the row
        firstField = row.fieldsMut()[0].detachMemory();

        // At this point, row.field()[0].data() will be "" regardless of the
        // original value...
        break;
    }
}

// Oh no! Use after free!
std.debug.print("{s}", .{firstField.items});
```

### Raw Parser

The raw parser is a zero-allocation column. Unlike the allocating parser pattern, this parser does not unescape quoted strings or converts values into other types. Instead, it identifies the boundaries of each field start and end and returns slices to those boundaries. This means if you have the CSV row `"Jack ""Jim"" Smith",12` you will end up with the fields `"Jack ""Jim"" Smith"` and `12`. (Note that the surrounding quotes are part of the resulting output).

Addtionally, the raw parser does not work with readers. Instead, it requires the entire CSV file to be loaded into memory. This is because it returns slices into the CSV memory rather than return newly allocated memory.

Below is an example of how to use the raw column.

```zig
const zcsv = @import("zcsv");

/// ...

const csv =
    \\userid,name,age
    \\1,"Johny ""John"" Doe",23
    \\2,Jack,32
;

// No allocator needed
var parser = zcsv.raw.init(csv);

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
    }
}

// Detect parse errors
if (column.err) |err| {
    return err;
}
```

### Field Streamer

The field streamer will write each filed into a writer. It does not try to indicate the end of a row to the writer. Instead, it exposes state in the form of the `atRowEnd` method. 

There are two sub-approaches depending on validation. The first is partial fields (through `FieldStreamPartial`) and the next is fully-valid fields only (through `FieldStream`).

> Note: the Parser uses the `FieldStream` behind the scenes

With the partial fields each byte is written as it is processed without buffering. This means that if there is an invalid field (e.g. `John"Doe"`), then some of the data will be written to the writer before the parse error is detected. However, this also means there is no internal buffer limiting field size or taking up stack memory. A "no infinite loop" limit is imposed of 2^32 bytes per field. This may be adjusted if desired (for whatever reason).

In contrast, the fully-valid field only model will buffer fields internally and ensure they are valid before writing them to the stream. When it does write to the writer, it will write the entire field at once. This also has the advantage that writers which require memory allocations will perform fewer allocations on average.

However, because `FixedStream` needs an in-memory buffer we do need to keep that buffer in the stack. The buffer used is 1,024 bytes. This means that any fields larger than 1,024 bytes will cause a read error.

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
while (try parser.next(stdout)) {
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
).init(stdin); // No second parameter here

std.debug.print("\nRow: ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
//
// next does throw if it has an error.
// next will return `false` when it hits the end of the input
while (try parser.next(stdout)) {
    // Do whatever you need to here for the field

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row, just that we're about to move
    if (column.atRowEnd()) {
        std.debug.print("\nRow: ", .{});
    }
}
```

