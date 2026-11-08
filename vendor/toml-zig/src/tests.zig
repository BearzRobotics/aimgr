//! Tests derived from the examples in the TOML 1.0.0 specification
//! (https://toml.io/en/v1.0.0) and from its stated invalid cases.

const std = @import("std");
const toml = @import("root.zig");
const testing = std.testing;

const TrickleReader = @import("io_tests.zig").TrickleReader;

const V10: toml.Options = .{ .version = .v1_0 };
const V11: toml.Options = .{ .version = .v1_1 };

/// Parses with `opts`, and again one byte at a time through a Reader with no
/// buffer of its own; the result must be identical.
fn parseWith(opts: toml.Options, src: []const u8) !toml.Document {
    var diag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(testing.allocator, src, opts, &diag) catch |e| {
        std.debug.print("unexpected failure on {s}: {f}\n", .{ src, diag });
        return e;
    };
    errdefer doc.deinit();
    var tr = TrickleReader.init(src, 1, null);
    var diag2: toml.Diagnostic = .{};
    var doc2 = toml.Document.parseReader(testing.allocator, &tr.interface, opts, &diag2) catch |e| {
        std.debug.print("one-byte reader failed on {s}: {f}\n", .{ src, diag2 });
        return e;
    };
    defer doc2.deinit();
    const a = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(a);
    const b = try doc2.toOwnedString(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    return doc;
}

/// A document valid in TOML 1.0. It must also be valid in 1.1 and mean the
/// same thing; returns the 1.0 result.
fn parseOk(src: []const u8) !toml.Document {
    var doc = try parseWith(V10, src);
    errdefer doc.deinit();
    var doc11 = try parseWith(V11, src);
    defer doc11.deinit();
    const a = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(a);
    const b = try doc11.toOwnedString(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    return doc;
}

fn rejects(opts: toml.Options, src: []const u8) !bool {
    var diag: toml.Diagnostic = .{};
    if (toml.Document.parse(testing.allocator, src, opts, &diag)) |*doc| {
        var d = doc.*;
        d.deinit();
        return false;
    } else |e| {
        // The error and its position must not depend on how bytes arrive.
        var tr = TrickleReader.init(src, 1, null);
        var diag2: toml.Diagnostic = .{};
        try testing.expectError(e, toml.Document.parseReader(testing.allocator, &tr.interface, opts, &diag2));
        try testing.expectEqual(diag.line, diag2.line);
        try testing.expectEqual(diag.column, diag2.column);
        return true;
    }
}

/// Invalid in every TOML version.
fn expectInvalid(src: []const u8) !void {
    for ([_]toml.Options{ V10, V11 }) |opts| {
        if (!try rejects(opts, src)) {
            std.debug.print("accepted invalid input ({t}): {s}\n", .{ opts.version, src });
            return error.AcceptedInvalid;
        }
    }
}

/// Invalid in TOML 1.0 but valid in 1.1.
fn expectOnly11(src: []const u8) !void {
    if (!try rejects(V10, src)) {
        std.debug.print("1.0 accepted a 1.1-only input: {s}\n", .{src});
        return error.AcceptedInvalid;
    }
    var doc = try parseWith(V11, src);
    doc.deinit();
}

test "key/value basics and comments" {
    var doc = try parseOk(
        \\# comment
        \\key = "value" # trailing
        \\bare_key-1 = 1
        \\"quoted key" = true
        \\'lit key' = false
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("value", doc.root.getString("key").?);
    try testing.expectEqual(@as(i64, 1), doc.root.getInt("bare_key-1").?);
    try testing.expectEqual(true, doc.root.getBool("quoted key").?);
    try testing.expectEqual(false, doc.root.getBool("lit key").?);
}

test "invalid key/value forms" {
    try expectInvalid("key = # INVALID");
    try expectInvalid("first = \"Tom\" last = \"Preston-Werner\"");
    try expectInvalid("= \"no key name\"");
    try expectInvalid("a = 1\na = 2");
    try expectInvalid("a = 1\n\"a\" = 2");
    try expectInvalid("name = \"Tom\"\nname = \"Pradyun\"");
}

test "dotted keys" {
    var doc = try parseOk(
        \\name = "Orange"
        \\physical.color = "orange"
        \\physical.shape = "round"
        \\site."google.com" = true
        \\fruit . flavor = "banana"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("orange", doc.root.lookup("physical.color").?.string);
    try testing.expectEqual(true, doc.root.getTable("site").?.getBool("google.com").?);
    try testing.expectEqualStrings("banana", doc.root.lookup("fruit.flavor").?.string);
}

test "dotted key conflicts" {
    try expectInvalid("fruit.apple = 1\nfruit.apple.smooth = true");
    try expectInvalid("[fruit]\napple.color = \"red\"\n[fruit.apple]");
    try expectInvalid("[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.taste]");
    try expectInvalid("[a.b.c]\nz = 9\n[a]\nb.c.t = 1");
}

test "dotted keys may be extended by deeper headers" {
    var doc = try parseOk(
        \\[fruit]
        \\apple.color = "red"
        \\apple.taste.sweet = true
        \\[fruit.apple.texture]
        \\smooth = true
    );
    defer doc.deinit();
    try testing.expectEqual(true, doc.root.lookup("fruit.apple.texture.smooth").?.boolean);
    try testing.expectEqual(true, doc.root.lookup("fruit.apple.taste.sweet").?.boolean);
}

test "strings: basic escapes" {
    var doc = try parseOk(
        \\a = "I'm a string. \"You can quote me\". Name\tJos\u00E9\nLocation\tSF."
        \\b = "\U0001F600 \\ \b\f\r"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("I'm a string. \"You can quote me\". Name\tJos\u{E9}\nLocation\tSF.", doc.root.getString("a").?);
    try testing.expectEqualStrings("\u{1F600} \\ \x08\x0C\r", doc.root.getString("b").?);
}

test "strings: invalid" {
    try expectInvalid("a = \"bad \\x escape\"");
    try expectInvalid("a = \"unterminated");
    try expectInvalid("a = \"new\nline\"");
    try expectInvalid("a = \"\\uD800\"");
    try expectInvalid("a = \"\\U00110000\"");
    try expectInvalid("a = \"\\u12\"");
    try expectInvalid("a = \"\\u+123\"");
    try expectInvalid("a = \"nul \x00 char\"");
    try expectInvalid("a = \"del \x7f char\"");
    try expectInvalid("a = 'new\nline'");
}

test "strings: multi-line" {
    var doc = try parseOk(
        "a = \"\"\"\nRoses are red\nViolets are blue\"\"\"\n" ++
            "b = \"\"\"\nThe quick brown \\\n\n   fox jumps over \\\n the lazy dog.\"\"\"\n" ++
            "c = \"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"\n" ++
            "d = \"\"\"Here are three quotation marks: \"\"\\\".\"\"\"\n" ++
            "e = \"\"\"\"This,\" she said, \"is just a pointless statement.\"\"\"\"\n" ++
            "f = '''\nfirst\n  second'''\n" ++
            "g = ''''That,' she said, 'is still pointless.''''\n" ++
            "h = '''I [dw]on't need \\d{2} apples'''\n",
    );
    defer doc.deinit();
    try testing.expectEqualStrings("Roses are red\nViolets are blue", doc.root.getString("a").?);
    try testing.expectEqualStrings("The quick brown fox jumps over the lazy dog.", doc.root.getString("b").?);
    try testing.expectEqualStrings("Here are two quotation marks: \"\". Simple enough.", doc.root.getString("c").?);
    try testing.expectEqualStrings("Here are three quotation marks: \"\"\".", doc.root.getString("d").?);
    try testing.expectEqualStrings("\"This,\" she said, \"is just a pointless statement.\"", doc.root.getString("e").?);
    try testing.expectEqualStrings("first\n  second", doc.root.getString("f").?);
    try testing.expectEqualStrings("'That,' she said, 'is still pointless.'", doc.root.getString("g").?);
    try testing.expectEqualStrings("I [dw]on't need \\d{2} apples", doc.root.getString("h").?);
}

test "strings: multi-line invalid" {
    try expectInvalid("a = \"\"\"unterminated");
    try expectInvalid("a = \"\"\"six \"\"\"\"\"\"");
    try expectInvalid("a = '''unterminated");
}

test "strings: literal keeps backslashes" {
    var doc = try parseOk("winpath = 'C:\\Users\\nodejs\\templates'\nregex = '<\\i\\c*\\s*>'\n");
    defer doc.deinit();
    try testing.expectEqualStrings("C:\\Users\\nodejs\\templates", doc.root.getString("winpath").?);
}

test "integers" {
    var doc = try parseOk(
        \\int1 = +99
        \\int2 = 42
        \\int3 = 0
        \\int4 = -17
        \\int5 = 1_000
        \\int6 = 5_349_221
        \\int7 = 53_49_221
        \\int8 = 1_2_3_4_5
        \\hex1 = 0xDEADBEEF
        \\hex2 = 0xdeadbeef
        \\hex3 = 0xdead_beef
        \\oct1 = 0o01234567
        \\oct2 = 0o755
        \\bin1 = 0b11010110
        \\min = -9223372036854775808
        \\max = 9223372036854775807
        \\zero = -0
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(@as(i64, 99), r.getInt("int1").?);
    try testing.expectEqual(@as(i64, -17), r.getInt("int4").?);
    try testing.expectEqual(@as(i64, 1000), r.getInt("int5").?);
    try testing.expectEqual(@as(i64, 12345), r.getInt("int8").?);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), r.getInt("hex1").?);
    try testing.expectEqual(@as(i64, 0xdeadbeef), r.getInt("hex3").?);
    try testing.expectEqual(@as(i64, 0o01234567), r.getInt("oct1").?);
    try testing.expectEqual(@as(i64, 214), r.getInt("bin1").?);
    try testing.expectEqual(std.math.minInt(i64), r.getInt("min").?);
    try testing.expectEqual(std.math.maxInt(i64), r.getInt("max").?);
    try testing.expectEqual(@as(i64, 0), r.getInt("zero").?);
}

test "integers: invalid" {
    try expectInvalid("a = 01");
    try expectInvalid("a = +01");
    try expectInvalid("a = 1__0");
    try expectInvalid("a = _1");
    try expectInvalid("a = 1_");
    try expectInvalid("a = 0x_1");
    try expectInvalid("a = 0x");
    try expectInvalid("a = +0x1");
    try expectInvalid("a = 0o8");
    try expectInvalid("a = 0b2");
    try expectInvalid("a = 9223372036854775808");
    try expectInvalid("a = -9223372036854775809");
    try expectInvalid("a = 0xFFFFFFFFFFFFFFFF");
    try expectInvalid("a = 12abc");
    try expectInvalid("a = 1 2");
}

test "floats" {
    var doc = try parseOk(
        \\flt1 = +1.0
        \\flt2 = 3.1415
        \\flt3 = -0.01
        \\flt4 = 5e+22
        \\flt5 = 1e06
        \\flt6 = -2E-2
        \\flt7 = 6.626e-34
        \\flt8 = 224_617.445_991_228
        \\sf1 = inf
        \\sf2 = +inf
        \\sf3 = -inf
        \\sf4 = nan
        \\sf5 = +nan
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(@as(f64, 1.0), r.getFloat("flt1").?);
    try testing.expectEqual(@as(f64, 5e22), r.getFloat("flt4").?);
    try testing.expectEqual(@as(f64, 1e6), r.getFloat("flt5").?);
    try testing.expectEqual(@as(f64, -0.02), r.getFloat("flt6").?);
    try testing.expectEqual(@as(f64, 224617.445991228), r.getFloat("flt8").?);
    try testing.expect(std.math.isInf(r.getFloat("sf2").?));
    try testing.expect(r.getFloat("sf3").? < 0);
    try testing.expect(std.math.isNan(r.getFloat("sf4").?));
    // An integer is accepted by getFloat, but a float is not an integer.
    try testing.expect(r.getInt("flt1") == null);
}

test "floats: invalid" {
    try expectInvalid("a = .7");
    try expectInvalid("a = 7.");
    try expectInvalid("a = 3.e+20");
    try expectInvalid("a = 1e");
    try expectInvalid("a = 1e+");
    try expectInvalid("a = 01.5");
    try expectInvalid("a = 1._5");
    try expectInvalid("a = 1_.5");
    try expectInvalid("a = 1e_1");
    try expectInvalid("a = 1.5.2");
    try expectInvalid("a = Inf");
    try expectInvalid("a = NaN");
    try expectInvalid("a = 0x1p3");
}

test "booleans" {
    var doc = try parseOk("a = true\nb = false\n");
    defer doc.deinit();
    try testing.expectEqual(true, doc.root.getBool("a").?);
    try testing.expectEqual(false, doc.root.getBool("b").?);
    try expectInvalid("a = True");
    try expectInvalid("a = TRUE");
}

test "datetimes" {
    var doc = try parseOk(
        \\odt1 = 1979-05-27T07:32:00Z
        \\odt2 = 1979-05-27T00:32:00-07:00
        \\odt3 = 1979-05-27T00:32:00.999999-07:00
        \\odt4 = 1979-05-27 07:32:00Z
        \\ldt1 = 1979-05-27T07:32:00
        \\ldt2 = 1979-05-27T00:32:00.999999
        \\ld1 = 1979-05-27
        \\lt1 = 07:32:00
        \\lt2 = 00:32:00.999999
        \\leap = 2024-02-29
    );
    defer doc.deinit();
    const r = doc.root;
    const odt2 = r.get("odt2").?.datetime;
    try testing.expectEqual(@as(i16, -420), odt2.offset_minutes.?);
    try testing.expectEqual(@as(u32, 999999000), r.get("odt3").?.datetime.time.?.nanosecond);
    try testing.expectEqual(@as(i16, 0), r.get("odt4").?.datetime.offset_minutes.?);
    try testing.expect(r.get("ldt1").?.datetime.offset_minutes == null);
    try testing.expect(r.get("ld1").?.datetime.time == null);
    try testing.expect(r.get("lt1").?.datetime.date == null);
    try testing.expectEqual(@as(u8, 29), r.get("leap").?.datetime.date.?.day);
}

test "datetimes: invalid" {
    try expectInvalid("a = 2023-02-29");
    try expectInvalid("a = 1979-13-01");
    try expectInvalid("a = 1979-00-10");
    try expectInvalid("a = 1979-05-32");
    try expectInvalid("a = 1979-05-27T25:00:00");
    try expectInvalid("a = 1979-05-27T07:60:00");
    try expectInvalid("a = 07:32:00Z");
    try expectOnly11("a = 07:32");
    try expectInvalid("a = 1979-05-27T07:32:00+0700");
    try expectInvalid("a = 1979-5-27");
    try expectInvalid("a = 07:32:00.");
}

test "arrays" {
    var doc = try parseOk(
        \\integers = [ 1, 2, 3 ]
        \\colors = [ "red", "yellow", "green" ]
        \\nested = [ [ 1, 2 ], ["a", "b", "c"] ]
        \\mixed = [ 1, "two", 3.0, [ true ], { x = 1 } ]
        \\multi = [
        \\  1, # one
        \\  2,
        \\  # nothing
        \\  3,
        \\]
        \\empty = []
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(@as(usize, 3), r.getArray("integers").?.items.items.len);
    try testing.expectEqual(@as(usize, 2), r.getArray("nested").?.items.items.len);
    try testing.expectEqual(@as(usize, 5), r.getArray("mixed").?.items.items.len);
    try testing.expectEqual(@as(usize, 3), r.getArray("multi").?.items.items.len);
    try testing.expectEqual(@as(usize, 0), r.getArray("empty").?.items.items.len);
}

test "arrays: invalid" {
    try expectInvalid("a = [1, 2");
    try expectInvalid("a = [1 2]");
    try expectInvalid("a = [,]");
    try expectInvalid("a = [1,,2]");
}

test "tables" {
    var doc = try parseOk(
        \\[table-1]
        \\key1 = "some string"
        \\[table-2]
        \\key1 = "another string"
        \\[dog."tater.man"]
        \\type.name = "pug"
        \\[ j . "ʞ" . 'l' ]
        \\x = 1
    );
    defer doc.deinit();
    try testing.expectEqualStrings("pug", doc.root.getTable("dog").?.getTable("tater.man").?.lookup("type.name").?.string);
    try testing.expectEqual(@as(i64, 1), doc.root.getTable("j").?.getTable("ʞ").?.getTable("l").?.getInt("x").?);
}

test "tables: super table defined after" {
    var doc = try parseOk(
        \\[x.y.z.w]
        \\a = 1
        \\[x]
        \\b = 2
    );
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 2), doc.root.getTable("x").?.getInt("b").?);
    try testing.expectEqual(@as(i64, 1), doc.root.lookup("x.y.z.w.a").?.integer);
}

test "tables: invalid" {
    try expectInvalid("[a]\n[a]");
    try expectInvalid("[a]\nb = 1\n[a.b]");
    try expectInvalid("[a]\nb = 1\n[a]\nc = 2");
    try expectInvalid("[]");
    try expectInvalid("[a.]");
    try expectInvalid("[.a]");
    try expectInvalid("[a..b]");
    try expectInvalid("[a");
    try expectInvalid("[a] b = 1");
    try expectInvalid("a = 1\n[a]");
    try expectInvalid("[fruit]\napple = \"red\"\n[fruit.apple]");
    try expectInvalid("[fruit]\napple = \"red\"\n[fruit.apple.texture]");
}

test "inline tables" {
    var doc = try parseOk(
        \\name = { first = "Tom", last = "Preston-Werner" }
        \\point = { x = 1, y = 2 }
        \\animal = { type.name = "pug" }
        \\empty = {}
    );
    defer doc.deinit();
    try testing.expectEqualStrings("Tom", doc.root.lookup("name.first").?.string);
    try testing.expectEqualStrings("pug", doc.root.lookup("animal.type.name").?.string);
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("empty").?.count());
}

test "inline tables: invalid" {
    try expectOnly11("a = { x = 1,\n y = 2 }");
    try expectOnly11("a = { x = 1, }");
    try expectInvalid("a = { x = 1 y = 2 }");
    try expectInvalid("a = { x = 1, x = 2 }");
    try expectInvalid("a = { x = 1 }\n[a]");
    try expectInvalid("a = { x = 1 }\n[a.b]");
    try expectInvalid("a = { b = {} }\n[a.b]");
    try expectInvalid("a = { x = 1 }\na.y = 2");
    try expectInvalid("a = { x = 1");
}

test "array of tables" {
    var doc = try parseOk(
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\[[products]]  # empty table within the array
        \\[[products]]
        \\name = "Nail"
        \\[[fruits]]
        \\name = "apple"
        \\[fruits.physical]
        \\color = "red"
        \\[[fruits.varieties]]
        \\name = "red delicious"
        \\[[fruits.varieties]]
        \\name = "granny smith"
        \\[[fruits]]
        \\name = "banana"
        \\[[fruits.varieties]]
        \\name = "plantain"
    );
    defer doc.deinit();
    const products = doc.root.getArray("products").?;
    try testing.expectEqual(@as(usize, 3), products.items.items.len);
    try testing.expectEqual(@as(usize, 0), products.items.items[1].table.count());
    const fruits = doc.root.getArray("fruits").?;
    try testing.expectEqual(@as(usize, 2), fruits.items.items.len);
    const apple = fruits.items.items[0].table;
    try testing.expectEqualStrings("red", apple.lookup("physical.color").?.string);
    try testing.expectEqual(@as(usize, 2), apple.getArray("varieties").?.items.items.len);
    try testing.expectEqual(@as(usize, 1), fruits.items.items[1].table.getArray("varieties").?.items.items.len);
}

test "array of tables: invalid" {
    try expectInvalid("a = [1]\n[[a]]");
    try expectInvalid("a = [{x = 1}]\n[[a]]");
    try expectInvalid("[[a]]\n[a]");
    try expectInvalid("[a]\n[[a]]");
    try expectInvalid("a = 1\n[[a]]");
    try expectInvalid("[[a]\n");
    try expectInvalid("[[a]]]\n");
    try expectInvalid("a = [{x = 1}]\n[a.b]");
}

test "line endings, BOM, whitespace" {
    var doc = try parseOk("\xEF\xBB\xBFa = 1\r\nb = \"\"\"x\r\ny\"\"\"\r\n[t]\r\nc = 2");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.getInt("a").?);
    try testing.expectEqualStrings("x\r\ny", doc.root.getString("b").?);
    try expectInvalid("a = 1\rb = 2");
    try expectInvalid("a = 1 # bare \r cr");
    try expectInvalid("a = 1 # nul \x00");
}

fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| out[i * s.len ..][0..s.len].* = s.*;
    const final = out;
    return &final;
}

test "invalid UTF-8 and limits" {
    var diag: toml.Diagnostic = .{};
    try testing.expectError(error.InvalidUtf8, toml.Document.parse(testing.allocator, "a = \"\xff\"", .{}, &diag));
    try testing.expectEqual(@as(usize, 1), diag.line);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, "a = 1", .{ .max_bytes = 2 }, null));
    // Deep nesting must be rejected rather than overflow the stack.
    const deep = "a = " ++ rep("[", 100) ++ rep("]", 100);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, deep, .{}, null));
    const ok = "a = " ++ rep("[", 60) ++ rep("]", 60);
    var d = try toml.Document.parse(testing.allocator, ok, .{}, null);
    d.deinit();
    const deep_inline = "a = " ++ rep("{ b = ", 100) ++ "1" ++ rep(" }", 100);
    try testing.expectError(error.LimitExceeded, toml.Document.parse(testing.allocator, deep_inline, .{}, null));
}

test "diagnostics report line and column" {
    var diag: toml.Diagnostic = .{};
    try testing.expectError(error.Syntax, toml.Document.parse(testing.allocator, "a = 1\nb = 2\nc = @\n", .{}, &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expect(diag.message.len > 0);
}

test "empty and comment-only documents" {
    var doc = try parseOk("");
    doc.deinit();
    doc = try parseOk("# just a comment");
    doc.deinit();
    doc = try parseOk("\n\n   \n\t\n");
    doc.deinit();
}

test "full example from the spec" {
    var doc = try parseOk(
        \\# This is a TOML document.
        \\title = "TOML Example"
        \\[owner]
        \\name = "Tom Preston-Werner"
        \\dob = 1979-05-27T07:32:00-08:00
        \\[database]
        \\enabled = true
        \\ports = [ 8000, 8001, 8002 ]
        \\data = [ ["delta", "phi"], [3.14] ]
        \\temp_targets = { cpu = 79.5, case = 72.0 }
        \\[servers]
        \\[servers.alpha]
        \\ip = "10.0.0.1"
        \\role = "frontend"
        \\[servers.beta]
        \\ip = "10.0.0.2"
        \\role = "backend"
    );
    defer doc.deinit();
    try testing.expectEqualStrings("10.0.0.2", doc.root.lookup("servers.beta.ip").?.string);
    try testing.expectEqual(@as(f64, 79.5), doc.root.lookup("database.temp_targets.cpu").?.float);
}

// ---- writing and round trips ---------------------------------------------

fn roundTrip(src: []const u8) !void {
    var a = try parseOk(src);
    defer a.deinit();
    const text = try a.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    var diag: toml.Diagnostic = .{};
    var b = toml.Document.parse(testing.allocator, text, .{}, &diag) catch |e| {
        std.debug.print("re-parse failed ({f}) for output:\n{s}\n", .{ diag, text });
        return e;
    };
    defer b.deinit();
    const text2 = try b.toOwnedString(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expectEqualStrings(text, text2);
}

test "writer: round trips preserve structure" {
    try roundTrip("a = 1e-7\nb = 123456789012345680.0\nc = 5e-324\nd = 0.0001\n");
    try roundTrip(
        \\title = "x"
        \\n = 5
        \\f = 1.5
        \\whole = 3.0
        \\big = 1e300
        \\neg = -0.0
        \\s = "line\nbreak \"q\" \\ \u0001 é"
        \\d = 1979-05-27T07:32:00.5-07:00
        \\arr = [1, [2, 3], { a = 1 }]
        \\inl = { x = 1, "y z" = { q = true } }
        \\"odd key" = 1
        \\[a.b]
        \\c = 1
        \\[a.b.d]
        \\e = 2
        \\[[list]]
        \\n = 1
        \\[list.sub]
        \\z = 1
        \\[[list]]
        \\n = 2
        \\[x.y.z]
        \\only = "leaf"
    );
}

test "writer: output is as expected for a simple document" {
    var doc = try parseOk("b = 1\na = \"s\"\n[t]\nk = true\n[[arr]]\nx = 1\n[[arr]]\nx = 2\n");
    defer doc.deinit();
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "b = 1\na = \"s\"\n\n[t]\nk = true\n\n[[arr]]\nx = 1\n\n[[arr]]\nx = 2\n",
        text,
    );
}

test "writer: floats always look like floats" {
    var doc = try parseOk("a = 3.0\nb = 1e22\nc = inf\nd = -inf\ne = nan\n");
    defer doc.deinit();
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    var re = try parseOk(text);
    defer re.deinit();
    try testing.expect(re.root.get("a").? == .float);
    try testing.expect(re.root.get("b").? == .float);
    try testing.expectEqual(@as(f64, 1e22), re.root.getFloat("b").?);
}

test "building and editing a document" {
    var doc = try toml.Document.init(testing.allocator);
    defer doc.deinit();
    try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("bottom") });
    try doc.set(&.{ "panel", "auto_hide" }, .{ .boolean = false });
    try doc.set(&.{ "appearance", "accent" }, .{ .string = try doc.dupe("#3a6ea5") });
    try testing.expectError(error.NotATable, doc.set(&.{ "panel", "position", "x" }, .{ .integer = 1 }));
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "[panel]\nposition = \"bottom\"\nauto_hide = false\n\n[appearance]\naccent = \"#3a6ea5\"\n",
        text,
    );
}

test "editing a parsed document keeps unknown keys" {
    var doc = try parseOk("[panel]\nposition = \"top\"\nfuture_key = [1, 2]\n[other]\nx = 1\n");
    defer doc.deinit();
    try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("bottom") });
    const text = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[panel]\nposition = \"bottom\"\nfuture_key = [1, 2]\n\n[other]\nx = 1\n", text);
}

test "no leaks on error paths" {
    // testing.allocator reports leaks; each of these fails part-way through parsing.
    const bad = [_][]const u8{
        "a = [1, 2",
        "[a]\nb = { c = 1, c = 2 }",
        "a = \"abc",
        "[[a]]\n[a]",
    };
    for (bad) |src| try expectInvalid(src);
}

test "allocation failure is handled" {
    const src = "a = [1, 2, { b = \"x\" }]\n[t.u]\nk = 1\n[[l]]\nz = 2\n";
    var fail_index: usize = 0;
    while (fail_index < 200) : (fail_index += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (toml.Document.parse(fa.allocator(), src, .{}, null)) |*d| {
            var dd = d.*;
            dd.deinit();
            break;
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    }
}

test "parseReader reads from a std.Io.Reader and enforces max_bytes" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("a = 1\n[t]\nb = \"x\"\n");
    var doc = try toml.Document.parseReader(gpa, &r, .{}, null);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 1), doc.root.lookup("a").?.integer);

    var big: std.Io.Reader = .fixed("a = 1\n");
    try std.testing.expectError(error.LimitExceeded, toml.Document.parseReader(gpa, &big, .{ .max_bytes = 3 }, null));
}

// ---- TOML 1.1.0 -----------------------------------------------------------
// Grammar: https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf

test "1.1: inline tables may span lines, hold comments and end with a comma" {
    const src =
        \\a = {
        \\    x = 1, # first
        \\    y = { z = [1,
        \\        2] },
        \\
        \\}
        \\b = { k = "v", }
        \\c = {
        \\}
        \\d = { # only a comment
        \\}
        \\
    ;
    try expectOnly11(src);
    var doc = try parseWith(V11, src);
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.lookup("a.x").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.root.lookup("a.y").?.table.getArray("z").?.items.items[1].integer);
    try testing.expectEqualStrings("v", doc.root.lookup("b.k").?.string);
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("c").?.count());
    try testing.expectEqual(@as(usize, 0), doc.root.getTable("d").?.count());
}

test "1.1: inline tables still reject malformed separators" {
    try expectInvalid("a = { , }");
    try expectInvalid("a = { x = 1,, }");
    try expectInvalid("a = { x = 1 y = 2 }");
    try expectInvalid("a = { x = 1,\n");
    try expectInvalid("a = { x = 1, x = 2 }");
    try expectInvalid("a = { x = 1,\n y }");
}

test "1.1: \\e and \\xHH escapes" {
    try expectOnly11("a = \"\\e[0m\"");
    try expectOnly11("a = \"\\x61\"");
    var doc = try parseWith(V11,
        \\a = "csi: \e["
        \\b = "null: \x00, a: \x61, ÿ: \xFF"
        \\c = """
        \\multi \e \x41"""
        \\d = 'literal \e \x41 stays literal'
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("csi: \x1b[", doc.root.getString("a").?);
    try testing.expectEqualStrings("null: \x00, a: a, \xc3\xbf: \xc3\xbf", doc.root.getString("b").?);
    try testing.expectEqualStrings("multi \x1b A", doc.root.getString("c").?);
    try testing.expectEqualStrings("literal \\e \\x41 stays literal", doc.root.getString("d").?);
}

test "1.1: malformed \\x escapes are rejected" {
    try expectInvalid("a = \"\\x6\"");
    try expectInvalid("a = \"\\xZZ\"");
    try expectInvalid("a = \"\\x\"");
    try expectInvalid("a = \"\\x+1\"");
    try expectInvalid("a = \"\\E\"");
}

test "1.1: seconds are optional in times and datetimes" {
    try expectOnly11("a = 07:32");
    try expectOnly11("a = 1979-05-27 07:32Z");
    try expectOnly11("a = 1979-05-27T07:32");
    try expectOnly11("a = 1979-05-27T07:32-05:00");
    var doc = try parseWith(V11,
        \\lt = 07:32
        \\odt = 1979-05-27 07:32Z
        \\ldt = 1979-05-27T07:32
        \\off = 1979-05-27T07:32-05:30
        \\full = 07:32:10.5
        \\
    );
    defer doc.deinit();
    const lt = doc.root.get("lt").?.datetime.time.?;
    try testing.expectEqual(@as(u8, 7), lt.hour);
    try testing.expectEqual(@as(u8, 32), lt.minute);
    try testing.expectEqual(@as(u8, 0), lt.second);
    try testing.expectEqual(@as(i16, 0), doc.root.get("odt").?.datetime.offset_minutes.?);
    try testing.expect(doc.root.get("ldt").?.datetime.offset_minutes == null);
    try testing.expectEqual(@as(i16, -330), doc.root.get("off").?.datetime.offset_minutes.?);
    try testing.expectEqual(@as(u32, 500_000_000), doc.root.get("full").?.datetime.time.?.nanosecond);
}

test "1.1: optional seconds do not loosen the rest of the time grammar" {
    try expectInvalid("a = 07:3");
    try expectInvalid("a = 7:32");
    try expectInvalid("a = 07:32.5"); // a fraction needs seconds
    try expectInvalid("a = 1979-05-27T07:32.5Z");
    try expectInvalid("a = 07:32Z"); // a bare time has no offset
    try expectInvalid("a = 24:00");
    try expectInvalid("a = 07:60");
    try expectInvalid("a = 1979-05-27T07:32:");
}

test "1.1: version defaults to 1.1" {
    var doc = try toml.Document.parse(testing.allocator, "a = 07:32\nb = \"\\e\"\n", .{}, null);
    doc.deinit();
    try testing.expectEqual(toml.Version.v1_1, (toml.Options{}).version);
}
