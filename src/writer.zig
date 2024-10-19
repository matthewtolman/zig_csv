const std = @import("std");
const CsvWriteError = @import("common.zig").CsvWriteError;

/// Writes a CSV row to a writer
/// CSV rows are tuples with fields of the following types:
/// * int (comptime, i32, i16, etc)
/// * float (copmtime, f32, f64)
/// * []u8, []const u8, [_]u8, [_]const u8
/// * bool
/// * optional
/// * error unions
/// * enum, enum literal
/// * tagged union
/// * pointer to a valid type
/// * type (e.g. @TypeOf(_))
/// * null
///
/// Note: fields are written in an opinionated way
/// Strings are wrapped in quotes always, while encoded values are not
/// (numbers, bools, types, etc are not in quotes)
/// Null is encoded as an empty field
///
/// Arrays and slices can only contain u8
/// Structs, tuples, etc for fields is not allowed
/// Unions must be tagged. Only the value will be encoded (not the union's tag).
///
/// Errors will be either CsvWriteError or your writer's errors
///
/// Error sets are not encodeable
pub fn row(writer: anytype, in_row: anytype) !void {
    const RowType = @TypeOf(in_row);
    const row_type_info = @typeInfo(RowType);

    // Zig 0.13.0 use UpperCase
    // Zig 0.14.0-dev use snake_case
    // These if statements are to support both the latest stable and nightly
    if (@hasField(@TypeOf(row_type_info), "Struct")) {
        if (row_type_info != .Struct) {
            @compileError(
                "expected tuple or struct argument, found " ++ @typeName(RowType),
            );
        }
    } else {
        if (row_type_info != .@"struct") {
            @compileError(
                "expected tuple or struct argument, found " ++ @typeName(RowType),
            );
        }
    }

    const fields_info = if (@hasField(@TypeOf(row_type_info), "Struct"))
        row_type_info.Struct.fields
    else
        row_type_info.@"struct".fields;

    // Some large value. 32 columns (the std.fmt limit) seemed really small
    // (I've seen some nutty CSV files)
    // I have yet to see a CSV file with 1,000 columns
    // If someone did need more that, then they will probably need to create
    // their own library and they probably aren't using mine
    const max_row_args = 1024;
    if (fields_info.len > max_row_args) {
        @compileError("1024 columns max are supported per row write call");
    }

    @setEvalBranchQuota(20000000);
    comptime var i = 0;
    inline while (i < fields_info.len) {
        const field = @field(in_row, fields_info[i].name);

        if (i != 0) {
            try writer.writeByte(',');
        }

        try value(writer, field);
        i += 1;
    }
    try writer.writeAll("\r\n");
}

/// Writes a value to a CSV writer. Does NOT write the comma
pub fn value(writer: anytype, field: anytype) !void {
    const FieldType = @TypeOf(field);
    const field_type_info = @typeInfo(FieldType);

    // Zig 0.13.0 use UpperCase
    // Zig 0.14.0-dev use snake_case
    // These if statements are to support both the latest stable and nightly
    if (@hasField(@TypeOf(field_type_info), "Struct")) {
        switch (field_type_info) {
            .ComptimeInt, .Int, .ComptimeFloat, .Float => {
                try writer.print("{d}", .{field});
            },
            .Bool => {
                if (field) {
                    try writer.print("yes", .{});
                } else {
                    try writer.print("no", .{});
                }
            },
            .Optional => {
                if (field) |payload| {
                    return value(writer, payload);
                } else {
                    return;
                }
            },
            .ErrorUnion => {
                if (field) |payload| {
                    try value(writer, payload);
                } else |err| {
                    try writer.writeAll(@errorName(err));
                }
            },
            .Enum => |enum_info| {
                if (enum_info.is_exhaustive) {
                    try writer.writeAll(@tagName(field));
                    return;
                }

                @setEvalBranchQuota(3 * enum_info.fields.len);
                inline for (enum_info.fields) |enum_field| {
                    if (@intFromEnum(field) == enum_field.value) {
                        try writer.writeAll(@tagName(field));
                        return;
                    }
                }

                try value(writer, @intFromEnum(field));
            },
            .Union => |info| {
                if (info.tag_type) |UnionTagType| {
                    inline for (info.fields) |u_field| {
                        if (field == @field(UnionTagType, u_field.name)) {
                            try value(writer, @field(field, u_field.name));
                            return;
                        }
                    }
                }
                return CsvWriteError.InvalidValueType;
            },
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .Array,
                    .Enum,
                    .Union,
                    => {
                        return value(writer, field.*);
                    },
                    else => return CsvWriteError.InvalidValueType,
                },
                .Many, .C => {
                    if (ptr_info.child == u8) {
                        return writeCsvStr(writer, field);
                    }
                    return CsvWriteError.InvalidValueType;
                },
                .Slice => {
                    if (ptr_info.child == u8) {
                        return writeCsvStr(writer, field);
                    }
                    return CsvWriteError.InvalidValueType;
                },
            },
            .Array => |info| {
                if (info.child == u8) {
                    return writeCsvStr(writer, &field);
                }
                return CsvWriteError.InvalidValueType;
            },
            .Type => {
                try writer.writeAll(@typeName(field));
            },
            .EnumLiteral => {
                return writeCsvStr(writer, @tagName(field));
            },
            .Null => {
                return;
            },
            else => CsvWriteError.InvalidValueType,
        }
    } else {
        switch (field_type_info) {
            .comptime_int, .int, .comptime_float, .float => {
                try writer.print("{d}", .{field});
            },
            .bool => {
                if (field) {
                    try writer.print("yes", .{});
                } else {
                    try writer.print("no", .{});
                }
            },
            .optional => {
                if (field) |payload| {
                    return value(writer, payload);
                } else {
                    return;
                }
            },
            .error_union => {
                if (field) |payload| {
                    try value(writer, payload);
                } else |err| {
                    try writer.writeAll(@errorName(err));
                }
            },
            .@"enum" => |enum_info| {
                if (enum_info.is_exhaustive) {
                    try writer.writeAll(@tagName(field));
                    return;
                }

                @setEvalBranchQuota(3 * enum_info.fields.len);
                inline for (enum_info.fields) |enum_field| {
                    if (@intFromEnum(field) == enum_field.value) {
                        try writer.writeAll(@tagName(field));
                        return;
                    }
                }

                try value(writer, @intFromEnum(field));
            },
            .@"union" => |info| {
                if (info.tag_type) |UnionTagType| {
                    inline for (info.fields) |u_field| {
                        if (field == @field(UnionTagType, u_field.name)) {
                            try value(writer, @field(field, u_field.name));
                            return;
                        }
                    }
                }
                return CsvWriteError.InvalidValueType;
            },
            .pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .array,
                    .@"enum",
                    .@"union",
                    => {
                        return value(writer, field.*);
                    },
                    else => return CsvWriteError.InvalidValueType,
                },
                .Many, .C => {
                    if (ptr_info.child == u8) {
                        return writeCsvStr(writer, field);
                    }
                    return CsvWriteError.InvalidValueType;
                },
                .Slice => {
                    if (ptr_info.child == u8) {
                        return writeCsvStr(writer, field);
                    }
                    return CsvWriteError.InvalidValueType;
                },
            },
            .array => |info| {
                if (info.child == u8) {
                    return writeCsvStr(writer, &field);
                }
                return CsvWriteError.InvalidValueType;
            },
            .type => {
                try writer.writeAll(@typeName(field));
            },
            .enum_literal => {
                return writeCsvStr(writer, @tagName(field));
            },
            .null => {
                return;
            },
            else => CsvWriteError.InvalidValueType,
        }
    }
}

fn writeCsvStr(writer: anytype, name: []const u8) !void {
    try writer.writeByte('\"');
    for (name) |c| {
        if (c == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\"');
}

test "row good" {
    const testing = @import("std").testing;

    const E = enum {
        bay,
        area,
    };
    const U = union(enum) {
        baker: i32,
        chef: []const u8,
    };

    const ArrayList = @import("std").ArrayList;
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();

    const arr1 = [_]u8{ 'c', 'o', 'l', '1' };
    const arr = [_]u8{ 'c', 'o', 'l', '3' };
    const slice: []const u8 = &arr;

    try row(writer, .{ arr1, "col2", slice, "col4", "col5" });

    const o1: ?i32 = 34;
    const o2: ?i32 = null;

    try row(writer, .{ 1, null, "test", true, false });
    try row(writer, .{ 23.34, E.bay, E.area, null, null });
    try row(writer, .{
        U{ .baker = 34 },
        U{ .chef = "hello" },
        @TypeOf(E),
        o1,
        o2,
    });

    const e1: anyerror!i32 = 32;
    const e2: anyerror!i32 = error.InvalidValueType;
    const v1: i64 = 12;
    try row(writer, .{
        e1,
        e2,
        v1,
        @TypeOf(v1),
        null,
    });

    try testing.expectEqualStrings("\"col1\",\"col2\",\"col3\",\"col4\",\"col5\"\r\n" ++
        "1,,\"test\",yes,no\r\n" ++
        "23.34,bay,area,,\r\n" ++
        "34,\"hello\",type,34,\r\n" ++
        "32,InvalidValueType,12,i64,\r\n", list.items);
}

test "row large" {
    const testing = @import("std").testing;

    const ArrayList = @import("std").ArrayList;
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();

    // Check that we can do 1,024 elements (which is super big)
    // If you need more than 1,024 elements, then you need something special
    // and this is probably not the right library for you
    // Heck, if you do need 1,024 elements then this is probably still not
    // the right library for you.
    var expected = ArrayList(u8).init(testing.allocator);
    defer expected.deinit();
    for (1..1025) |i| {
        if (i != 1) {
            try expected.writer().writeByte(',');
        }
        try expected.writer().print("{d}", .{i});
    }
    try expected.writer().print("\r\n", .{});
    try row(writer, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 419, 420, 421, 422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 432, 433, 434, 435, 436, 437, 438, 439, 440, 441, 442, 443, 444, 445, 446, 447, 448, 449, 450, 451, 452, 453, 454, 455, 456, 457, 458, 459, 460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510, 511, 512, 513, 514, 515, 516, 517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543, 544, 545, 546, 547, 548, 549, 550, 551, 552, 553, 554, 555, 556, 557, 558, 559, 560, 561, 562, 563, 564, 565, 566, 567, 568, 569, 570, 571, 572, 573, 574, 575, 576, 577, 578, 579, 580, 581, 582, 583, 584, 585, 586, 587, 588, 589, 590, 591, 592, 593, 594, 595, 596, 597, 598, 599, 600, 601, 602, 603, 604, 605, 606, 607, 608, 609, 610, 611, 612, 613, 614, 615, 616, 617, 618, 619, 620, 621, 622, 623, 624, 625, 626, 627, 628, 629, 630, 631, 632, 633, 634, 635, 636, 637, 638, 639, 640, 641, 642, 643, 644, 645, 646, 647, 648, 649, 650, 651, 652, 653, 654, 655, 656, 657, 658, 659, 660, 661, 662, 663, 664, 665, 666, 667, 668, 669, 670, 671, 672, 673, 674, 675, 676, 677, 678, 679, 680, 681, 682, 683, 684, 685, 686, 687, 688, 689, 690, 691, 692, 693, 694, 695, 696, 697, 698, 699, 700, 701, 702, 703, 704, 705, 706, 707, 708, 709, 710, 711, 712, 713, 714, 715, 716, 717, 718, 719, 720, 721, 722, 723, 724, 725, 726, 727, 728, 729, 730, 731, 732, 733, 734, 735, 736, 737, 738, 739, 740, 741, 742, 743, 744, 745, 746, 747, 748, 749, 750, 751, 752, 753, 754, 755, 756, 757, 758, 759, 760, 761, 762, 763, 764, 765, 766, 767, 768, 769, 770, 771, 772, 773, 774, 775, 776, 777, 778, 779, 780, 781, 782, 783, 784, 785, 786, 787, 788, 789, 790, 791, 792, 793, 794, 795, 796, 797, 798, 799, 800, 801, 802, 803, 804, 805, 806, 807, 808, 809, 810, 811, 812, 813, 814, 815, 816, 817, 818, 819, 820, 821, 822, 823, 824, 825, 826, 827, 828, 829, 830, 831, 832, 833, 834, 835, 836, 837, 838, 839, 840, 841, 842, 843, 844, 845, 846, 847, 848, 849, 850, 851, 852, 853, 854, 855, 856, 857, 858, 859, 860, 861, 862, 863, 864, 865, 866, 867, 868, 869, 870, 871, 872, 873, 874, 875, 876, 877, 878, 879, 880, 881, 882, 883, 884, 885, 886, 887, 888, 889, 890, 891, 892, 893, 894, 895, 896, 897, 898, 899, 900, 901, 902, 903, 904, 905, 906, 907, 908, 909, 910, 911, 912, 913, 914, 915, 916, 917, 918, 919, 920, 921, 922, 923, 924, 925, 926, 927, 928, 929, 930, 931, 932, 933, 934, 935, 936, 937, 938, 939, 940, 941, 942, 943, 944, 945, 946, 947, 948, 949, 950, 951, 952, 953, 954, 955, 956, 957, 958, 959, 960, 961, 962, 963, 964, 965, 966, 967, 968, 969, 970, 971, 972, 973, 974, 975, 976, 977, 978, 979, 980, 981, 982, 983, 984, 985, 986, 987, 988, 989, 990, 991, 992, 993, 994, 995, 996, 997, 998, 999, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 1018, 1019, 1020, 1021, 1022, 1023, 1024 });
    try testing.expectEqualStrings(
        expected.items,
        list.items,
    );
}
