# ZCSV (Zig CSV)

<!-- mtoc-start -->

* [Summary](#summary)
* [Installation](#installation)
* [Examples](#examples)
* [Writing CSV](#writing-csv)
* [Reading a CSV](#reading-a-csv)
  * [Map Parser](#map-parser)
  * [Column Parser](#column-parser)
  * [Slice Parser (zero-allocation)](#slice-parser-zero-allocation)
  * [Stream Parser (zero-allocation)](#stream-parser-zero-allocation)
* [Parser Loop Limit Options](#parser-loop-limit-options)
* [Changing delimiters, quotes, and newlines](#changing-delimiters-quotes-and-newlines)
* [Parser Builder](#parser-builder)
* [Memory Lifetimes](#memory-lifetimes)
* [Utility Methods](#utility-methods)
  * [Field Methods](#field-methods)
  * [Slice Methods](#slice-methods)
* [License](#license)

<!-- mtoc-end -->

## Summary

> Supported Zig versions: 0.14.0,0.15.0-dev.769+4d7980645

> For Zig 0.13.0 use releases 0.7.x (e.g. 0.7.3)

ZCSV is a CSV parser and writer library.

The CSV writer can encode many (but not all) built-in Zig datatypes. Alternatively, the writer can work with simple slices as well.

There are several parsers available with different tradeoffs between speed, memory usage, and developer experience.

The parsers are split into two main categories: allocating parsers and zero-allocation parsers. Generally, allocating parsers are easier to work with, but are slower while zero-allocation parsers are harder to work with. both writers and parsers which are allocation free while also having a parser which does use memory allocations for a more developer-friendly interface.

This library does allow customization of field and row delimiters, as well as the quoted character. It generally follows the CSV RFC with one key difference. The CSV RFC requires all newlines to be CRLF. However, this library provides parsers which allow for either CRLF newlines or LF newlines. This allows the parsers to parse both RFC-compliant CSV files and a few non-compliant CSV files.

Additionally, several utilities are provided to make working with CSVs slightly easier. Several decoding utilities exist to transform string field data into Zig primitives (such as field to integer). These utilities are opinionated to my use case, and are provided under their own namespace under `zcsv`. They are optional to use and can be safely ignored.

Note: All parsers do operate either line-by-line or field-by-field for all operations, including validation. This means that partial reads may happen when the first several rows of a file are valid but there is an error in the middle.

```zig
// Basic usage writing

const zcsv = @import("zcsv");
const std = @import("std");

// ....

// Get a destination writer
const stdout = std.io.getStdOut().writer();

// Get a CSV writer
const csv_out = zcsv.writer.init(stdout, .{});

// Write headers
try csv_out.writeRow(.{"field1", "field2", "field3", "field4"});

// Write a row
for (rowData) |elem| {
    try csv_out.writeRow(.{elem.f1, elem.f2, elem.f3, elem.f4});
}

// Basic usage reading

// Get an allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Get a reader
const stdin = std.io.getStdIn().reader();

// Make a parser
var parser = zcsv.allocs.map.init(allocator, stdin, .{});
// Some allocating parsers need to be cleaned up
defer parser.deinit();

// Helper utility to convert CSV fields to ints
const fieldToInt = zcsv.decode.fieldToInt;

// Iterate over rows
while (parser.next()) |row| {
    // Free row memory
    defer row.deinit();

    const id_field = row.data().get("id") orelse return error.MissingIdColumn;
    const id = fieldToInt(i64, id_field, 10) catch {
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

var parser = zcsv.zero_allocs.slice.init(csv, .{});

// Helper utility to write field strings to a writer
// Note: For this use case we could use field.decode(...)
//       However, field.decode(...) only works with zero-allocation parsers,
//         whereas writeFieldStrTo works with allocating and zero-allocation
//         parsers
const writeFieldStrTo = zcsv.decode.writeFieldStrTo;

while (parser.next()) |row| {
    // iterate over fields
    var iter = row.iter();

    while (iter.next()) |field| {
        // we need to manually decode fields to remove quotes
        // we can opt out of decoding work for ignored fields
        var decode_bytes: [256]u8 = undefined;
        var decode_buff = std.io.fixedBufferStream(&decode_bytes);
        try writeFieldStrTo(field, decode_buff.writer());

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

Writing CSV files is done line-by-line to a writer. The writing is done without dynamic memory allocation. Writing can be done by creating a CSV writer with `zcsv.writer.init` and then calling the `writeRow` and `writeRowStr` methods, or by calling `zcsv.writer.row` and `zcsv.writer.rowStr`. The advantage of creating a writer is that the writer will track the underlying `std.io.Writer` and parser options, whereas those options must be passed to the function variants manually.

The `writeRow` and `row` methods take a tuple of values and will encode most (but not all) builtin Zig values. However, this does require that a developer knows how many columns are needed at compile time. Alternatively, the `writeRowStr` and `rowStr` methods take a slice of byte slices (i.e.  a slice of strings). This allows developers to pass in arbitrarily sized rows at runtime for encoding.

```zig
// Basic usage

const zcsv = @import("zcsv");
const std = @import("std");

// ....

// Get an output writer
const stdout = std.io.getStdOut().writer();

/// OPTION 1: CSV Writer

// Get a CSV writer
const csv_writer = zcsv.writer.init(stdout, .{});

// Write headers
try csv_writer.writeRow(.{"field1", "field2", "field3e", "field4"});

// Write rows
for (rowData) |elem| {
    try csv_writer.writeRow(.{elem.f1, elem.f2, elem.f3, elem.f4});
}

// Option 2: Writer methods

// Write headers
try zcsv.writer.row(stdout, .{"field1", "field2", "field3", "field4"}, .{});

// Write row;
for (rowData) |elem| {
    try zcsv.writer.row(stdout, .{elem.f1, elem.f2, elem.f3, elem.f4}, .{});
}
```

## Reading a CSV

There are several patterns for reading CSV files provided. In general, for most use cases you'll want to use one of the allocating parsers - especially when CSV files are very small.

The `map` parser is for CSV files where the first row is a header row (a list of column names). The `column` parser is for CSV files where the header row is missing. There is one additional niche parser called `map_temporary`.

The `map_temporary` parser is for situations where you can guarantee that the row data will never outlive the parser memory. It provides a small performance increase, but can lead to trickier memory-related bugs.

As for non-allocating parsers, there are only two: `slice` and `stream`. The `slice` parser is for when the CSV file is loaded into a slice of bytes. The `stream` parser is for reading directly from a reader.

We'll discuss each parser in more detail.

### Map Parser
The map parser will parse a CSV file into a series of hash maps. Each map will be returned one at a time by an iterator. Additionally, any quoted CSV fields will be unquoted automatically, so the resulting array will be the field data.

Each row owns it's own memory (unless you're using `map_temporary` in which case some memory is shared). Each row will need to be deinitialized when no longer needed (including with `map_temporary`). Additionally, map parsers will need to be deinitialized once no longer used.

Additionally, map parsers will parse the header row immediately as part of their initialization. This means that their init function may fail (e.g. allocation error, reader error, invalid header, etc). It also means that if the underlying reader blocks, then the initialization method will block as well. Do keep this in mind as a potential side effect and source of bugs. Map parsers are the only parsers which eagerly parse, so if blocking is an issue then switch to a different parser (e.g. column parser).

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
var parser = try zcsv.allocs.map.init(allocator, stdin, .{});
// Note: map parsers must be deinitialized!
// They are the only parsers (currently) which need to be deinitialized
defer parser.deinit();

// We're building a list of user structs
var res = std.ArrayList(User).init(alloc);
errdefer res.deinit();

// Iterate over rows
const fieldToInt = zcsv.decode.fieldToInt;
while (parser.next) |row| {
    defer row.deinit();

    // Validate we have our columns
    const id = row.data().get("userid") orelse return error.MissingUserId;
    const name = row.data().get("name") orelse return error.MissingName;
    const age = row.data().get("age") orelse return error.MissingAge;

    // Validate and parse our user
    try res.append(User{
        .id = fieldToInt(i64, id, 10) catch {
            return error.InvalidUserId;
        } orelse return error.MissingUserId,
        .name = try name.clone(allocator),
        .age = fieldToInt(u16, age, 10) catch return error.InvalidAge,
    });
}
```

### Column Parser

The column parser will parse a CSV file and make fields accessible by index. The memory for a row is held by the row (i.e. calling `row.deinit()` will deallocate all associated memory). Additionally, the parser will unescape quoted strings automatically (i.e. "Johnny ""John"" Doe" will become `Johnny "John" Doe`). Deinitializing a column parser is not needed.

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
var parser = zcsv.allocs.column.init(allocator, stdin, .{});

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
   }
}

// Check for a parsing error
if (column.err) |err| {
    return err;
}

```

### Slice Parser (zero-allocation)

The slice parser is designed for speed, but it does so with some usability costs. First, it cannot read from a reader, so it requires the CSV file to be loaded into memory first. Additionally, it does not automatically decode parsed fields, so any quoted CSV fields will remain quoted after being parsed.

On the flip side, the parser itself will do no heap allocations, so it may be used in allocation-free contexts.

Example usage:

```zig
const csv =
    \\productid,productname,productsales
    \\1238943,"""Juice"" Box",9238
    \\3892392,"I can't believe it's not chicken!",480
    \\5934810,"Win The Fish",-
;
const stderr = std.io.getStdErr().writer();

var parser = zcsv.zero_allocs.slice.init(csv, .{});
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

### Stream Parser (zero-allocation)

The zero-allocation stream parser does come with a very different set of limitations. It is able to read directly from a reader, but it does not return field objects. Instead, it will write the decoded CSV value to an output writer.

Each iteration requries providing a writer - this allows you to use a new writer for each field if needed. Only a single field is parsed at a time. Furthermore, querying the parser is needed to know when a field has reached the end of a row.

This is by far the most difficult parser to use correctly. However, it is fast, does not perform allocations, and does not require the CSV file to be used in memory. For use cases with limited resources, this can be a good choice.

Below is an example on how to use it:

```zig
const reader = std.io.getStdIn().reader();

var tmp_bytes: [1024]u8 = undefined;
var tmp_buff = std.io.fixedBufferStream(&tmp_bytes);
var parser = zcsv.zero_allocs.stream.init(reader, @TypeOf(tmp_buff).Writer, .{});
std.log.info("Enter CSV to parse", .{});

try stderr.print("> ", .{});
// The writer is passed to each call to next
// This allows us to use a different writer per field
while (!parser.done()) {
    // Error checks are handled by this try
    try parser.next(tmp_buff.writer());

    // Use tmp_buff.getWritten() as needed
    std.debug.print("Decode: {s}\n", .{tmp_buff.getWritten()});

    // This is how you can tell if you're about to move to the next row
    // Note that we aren't at the next row yet.
    // This function just indicates if the next field will be on a separate row
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

## Parser Loop Limit Options

All of the parsers have some sort of "infinite loop protection" built in. Generally, this is a limit to 65,536 maximum loop iteration (unless there's an internal stack buffer, then the internal stack buffer will dictate the limit). This limit can be changed by adjusting the options passed into the parser. This limit can be customized by changing the `max_iter` value of `CsvOpts`.

## Changing delimiters, quotes, and newlines

Each parser and writer will take a `CsvOpts` struct which has options for customizing what tokens will be used when parsing and/or writing. The options are as follows:

- `column_delim`
    - This indicates the column delimiter character. Defaults to comma `,`
- `column_quote`
    - This indicates the column quote character. Defaults to double-quote `"`
- `column_line_end`
    - This indicates the last line ending character for a line ending. Defaults to `\n`
- `column_line_end_prefix`
    - This indicates the first line ending character for a line ending. It can be set to `null` if line endings should always be one character. This character is always optional when parsing line endings. Defaults to `\r`

Do note that the parsers and writers do expect each of the above options to be unique, including the line ending and line ending prefix. This means that line endings which require repeating characters (e.g. `\n\n`) are not supported.

Using invalid options is undefined behavior. In safe builds this will usually result in a panic. In non-safe builds the behavior is undefined (e.g. unusual parse behavior, weird errors, infinite loops, etc). Each `CsvOpts` has a `valid()` method which will return whether or not the options are valid. It is recommended that this method be used to validate any user or untrusted input prior to sending it to a parser or a writer.

## Parser Builder

To help with in-code discovery of parsers, a parser builder is provided with `zcsv.ParserBuilder`. The builder provides options for choosing a parser and for setting CSV options (such as delimiter, quote, line ending, etc). Additionally, the builder will take an allocator whenever an allocating parser is chosen and won't take an allocator when a zero-allocation parser is chosen. The builder also distinguishes between reader and slice input types.

The builder also provides methods to cleanup parsers and rows. These methods will become no-ops if no work is needed. This helps minimize the amount of work needed to switch between parsers. Also, if the cleanup methods are consistently used it can help prevent memory leaks when switching between parser types (which can often happen when moving from a zero-allocation parser to an allocating parser).

Below is an example of how to use a parser builder:

```zig
// Get our allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const alloc = gpa.allocator();

// Get our reader
var fbs = std.io.fixedBufferStream(csv[0..]);
const reader = fbs.reader();

// Get our builder
const builder = zcsv.ParserBuilder
//  These calls determine which parser we will use
//  They are required
    .withReaderInput(@TypeOf(reader))
    .withHeaderRow(alloc)
//  These calls customize the CSV tokens used for parsing
//  These are optional and only shown for demonstration purposes
    .withQuote('"')
    .withDelimiter(',');

// Make our parser
var parser = try builder.build(reader);
// Ensures parser is cleaned up properly
// This works regardless of what type of parser is returned
// It will also continue to work if parser's cleanup gets changed
// in the future
defer builder.denitParser(parser);

std.debug.print("id\tname\tage\n-------------------\n", .{});
while (parser.next()) |row| {
    // Ensure our row is cleaned up
    defer builder.deinitRow(row);

    // Work with the row data
    std.debug.print("{s}\t{s}\t{s}\n", .{
        row.data().get("id").?.data(),
        row.data().get("name").?.data(),
        row.data().get("age").?.data(),
    });
}
```

## Memory Lifetimes

Fields returned by parsers have their underlying memory tied to the row's memory. This means deinitializing the row will automatically deinitialize the fields tied to that row.

It also means that the following will result in a use-after-free:

```zig
// Use after free example, Don't do this!
var firstField: []const u8 = undefined;

outer: while (parser.next()) |row| {
    // Free row (and field) memory
    defer row.deinit();

    var fieldIter = row.iter();
    while (fieldIter) |field| {
        // Set a pointer to the field's memory
        // that will persist outside of the loop
        firstField = field.data();
        break :outer;
    }
}

// Oh no! Use after free!
std.debug.print("{s}", .{firstField});
```

If you need to have the field memory last past the row lifetime, then use the `clone` method. `clone` takes in an allocator to use for cloning the memory to. It exists for both allocating and zero-allocating parser fields, and it will always copy the decoded value (with zero-allocating parsers this means decoding the value as part of the copy). Below is an example:

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

outer: while (parser.next()) |row| {
    // Free row (and field) memory
    defer row.deinit();

    var fieldIter = row.iter();
    while (fieldIter) |field| {
        // Set a pointer to the field's memory
        // that will persist outside of the loop
        firstField = try field.clone(allocator);
        break :outer;
    }
}

// Okay! No more use after free
std.debug.print("{s}", .{firstField});
```

> Note: the `detachMemory` method was removed in version 0.4.0. `detachMemory` required that every field get a separate memory allocation, which caused a lot of memory allocations and was rather slow. In version 0.4.0 the field memory was merged with the row memory which resulted in fewer allocations and a significant speed up, but it also meant that simply "detaching" (or "moving") field memory was no longer possible.

## Utility Methods

There are several utility methods provided to help convert CSV data to Zig builtins. These methods are opinionated based on my use cases, so if they don't suit your needs they can be ignored (or used as a template to create your own version). Methods which work on fields do try to be usable on both allocating and non-allocating parser fields (with 2 exceptions). Methods which work on slices exist as well (useful if you're writing to memory with the stream parser).

All utility methods are under the `zcsv.decode` namespace.

### Field Methods

These are the methods which work on CSV fields (usually retrieved from a row iterator). None of these methods perform allocations.

- **fieldIsNull**
    - Returns whether the field is considered "null" (can be an empty string or a dash)
- **fieldToInt**
    - Parses a field into an integer, or returns `null` if `fieldIsNull` returns true
- **fieldToBool**
    - Parses a field to a boolean value, or returns `null` if `fieldIsNull` returns true. This method is case insensitive.
    - Truthy values include: `yes`, `y`, `1`, `true`, `t`
    - Falsey values include: `no`, `n`, `0`, `false`, `f`
- **fieldToFloat**
    - Parses a field into a float, or returns `null` if `fieldIsNull` returns true
- **fieldToStr**
    - Returns the underlying string slice of the field
    - The slice will be unquoted if the field is from an allocating parser
    - The slice will be raw (e.g. quoted) if the field is from a zero-allocation parser
    - The result has the field `is_raw` which indicates if it is quoted (`true`) or unquoted (`false`)
- **writeFieldStrTo**
    - Writes a field's unquoted value to a writer
- **fieldToDecodedStr**
    - _Only works on fields from allocating parsers!_
    - Returns `null` if `fieldIsNull` returns true
    - Returns a slice to the unquoted string
- **fieldToRawStr**
    - _Only works on fields from zero-allocation parsers!_
    - Returns `null` if `fieldIsNull` returns true
    - Returns a slice to the raw string

### Slice Methods

These are the methods that operate on slices of bytes. None of these methods perform memory allocations. All of these methods assume that the slice has been decoded (i.e. unquoted) prior to being called.

- **sliceIsNull**
    - Returns whether the slice is considered "null" (can be an empty string or a dash)
- **sliceToInt**
    - Parses a slice into an integer, or returns `null` if `sliceIsNull` returns true
- **sliceToBool**
    - Parses a slice to a boolean value, or returns `null` if `sliceIsNull` returns true. This method is case insensitive.
    - Truthy values include: `yes`, `y`, `1`, `true`, `t`
    - Falsey values include: `no`, `n`, `0`, `false`, `f`
- **sliceToFloat**
    - Parses a field into a float, or returns `null` if `sliceIsNull` returns true
- **unquote**
    - Decodes/unquotes a raw CSV slice into a writer

## License

This code is licensed under the MIT license.

