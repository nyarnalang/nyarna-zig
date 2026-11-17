const std = @import("std");

pub const Value = struct {
  line_offset: usize,
  /// uses the arena allocator of the containing File. given like this so that
  /// end markers ("\x04") can be appended as required by the lexer.
  content: std.ArrayList(u8),
};

pub const Values = std.StringHashMap(Value);

const ParseError = error {
  parsing_failed,
};

const Tags = struct {
  strip: bool = false,
  crlf : bool = false,
  chars: bool = false,
};

/// A file describing a test case. Test cases usually describe input and
/// expected output or errors. They have a format that aims to be readable to
/// the user, so that they can understand what the test is supposed to do,
/// and also machine-readable, so that it can be executed.
///
/// Quick overview of the format:
///
///  * title must be given on first line and prefixed with `=== `.
///  * after title, multiple sections can be given, each starting with a
///    section heading.
///  * a section heading has the form `--- <kind>[:name] [{flag,...}]`.
///    `kind` can be:
///    * `input`, for input data. input without a name is the primary input,
///      additional inputs (which can then be included) can be given with name.
///    * `tokens`, will run a tokenization test that checks whether the input
///      tokenizes into the given stream of tokens.
///    * `rawast`, will run an AST generation test without evaluating even
///      static expressions, and compare the resulting AST.
///    * `expr`, will run an AST generation test by evaluating static
///      expressions in the input, and then compare the resulting AST.
///    * `document`, will run a document generation test and checks the
///      generated document against the given document.
///    * `output`, will fully execute the input, transform it into text, and
///      check the generated output against the given output.
///    * `end-marker`, does nothing but can be used to safeguard preceding
///      empty lines from overzealous text editors that remove them at the
///      end of a file.
///    * `errors`, expect the input to yield errors. `name` must always be
///      given and identifies the stage at which errors are expected (`rawast`,
///      `expr`, `document`, `output`).
///  * the flags at the end of a section heading can be used to transform the
///    input before processing:
///    * `crlf` will replace POSIX line endings with Windows line endings.
///    * `strip` will strip trailing whitespace from the content
///    * `chars` will process e.g. `%0A` into a linefeed.
pub const File = struct {
  arena : std.heap.ArenaAllocator,
  name  : []const u8,
  items : Values,
  params: struct {
    @"inline": Values,
    file     : Values,
    input    : Values,
    output   : Values,
    errors   : Values,
  },

  fn failWith(
             path: []const u8,
    comptime msg : []const u8,
             args: anytype,
  ) ParseError {
    std.log.err("{s}: " ++ msg ++ "\n", .{path} ++ args);
    return ParseError.parsing_failed;
  }

  pub fn allocator(f: *File) std.mem.Allocator {
    return f.arena.allocator();
  }

  pub fn loadPath(
    alloc: std.mem.Allocator,
    io   : std.Io,
    path : []const u8,
  ) !File {
    return loadFile(alloc, io, std.Io.Dir.cwd(), path);
  }

  pub fn loadFile(
    alloc: std.mem.Allocator,
    io   : std.Io,
    dir  : std.Io.Dir,
    path : []const u8,
  ) !File {
    const file_contents = try dir.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(file_contents);
    return load(alloc, path, file_contents);
  }

  pub fn load(
    alloc: std.mem.Allocator,
    name : []const u8,
    input: []const u8,
  ) !File {
    // if input ends with newline, do not treat this as an additional empty
    // line. In accordance to POSIX, a final newline ends the previous line,
    // but doesn't start a new one.
    const body = std.mem.cutSuffix(u8, input, "\n") orelse input;
    var lines = std.mem.splitSequence(u8, body, "\n");

    var line = lines.next() orelse {
      return failWith(name, "missing header", .{});
    };
    var line_index: u32 = 1;
    if (!std.mem.eql(u8, line[0..4], "=== ")) {
      return failWith(name, "file does not start with `=== `", .{});
    }
    var ret: File = undefined;
    ret.arena = std.heap.ArenaAllocator.init(alloc);
    errdefer ret.deinit();
    ret.items = Values.init(ret.allocator());
    ret.params = .{
      .@"inline" = Values.init(ret.allocator()),
      .file      = Values.init(ret.allocator()),
      .input     = Values.init(ret.allocator()),
      .output    = Values.init(ret.allocator()),
      .errors    = Values.init(ret.allocator()),
    };
    ret.name = try ret.allocator().dupe(u8, line[4..]);

    line = lines.next() orelse {
      return failWith(name, "missing value after header", .{});
    };
    line_index += 1;

    var line_available = true;
    while (line_available) {
      const start = line_index;
      const header = line[4..];
      const name_end = std.mem.findScalar(u8, header, ':');
      const tag_start = std.mem.findScalar(u8, header, '{');
      var sub_name: []const u8 = "";
      const item_name = std.mem.trim(u8, try ret.allocator().dupe(u8, blk: {
        if (name_end) |val| {
          if (tag_start) |tval| {
            if (val > tval) return failWith(
              name, "`{{` before `:` in value header", .{});
            sub_name = try ret.allocator().dupe(
              u8, std.mem.trim(u8, header[val + 1..tval], " \t"));
          } else {
            sub_name = try ret.allocator().dupe(
              u8, std.mem.trim(u8, header[val + 1..], " \t"));
          }
          break :blk header[0..val];
        } else if (tag_start) |tval| {
          break :blk header[0..tval];
        } else break :blk header;
      }), " \t");
      var tags = Tags{};
      if (tag_start) |tval| {
        const tag_end = std.mem.findScalarLast(u8, header, '}') orelse {
          return failWith(name, "header misses `}}`", .{});
        };
        if (tag_end != std.mem.trimEnd(u8, header, " \t").len - 1) {
          return failWith(name, "content after `}}`", .{});
        }
        var tags_str = std.mem.trimEnd(u8, header[tval..tag_end], " \t");
        var sep: ?usize = 0;
        while (sep) |b| {
          tags_str = std.mem.trimStart(u8, tags_str[b + 1..], " \t");
          if (tags_str.len == 0) break;
          sep = std.mem.findScalar(u8, tags_str, ',');
          const tag = std.mem.trim(
            u8, if (sep) |e| tags_str[0..e] else tags_str, " \t");
          if (std.mem.eql(u8, tag, "strip")) {
            tags.strip = true;
          } else if (std.mem.eql(u8, tag , "crlf")) {
            tags.crlf = true;
          } else if (std.mem.eql(u8, tag, "chars")) {
            tags.chars = true;
          } else {
            return failWith(name, "unknown tag: `{s}`", .{tag});
          }
        }
      }

      const newline = if (tags.crlf) "\r\n" else "\n";

      var content: std.ArrayList(u8) = .empty;
      while (true) {
        line = lines.next() orelse {
          line_available = false;
          break;
        };
        line_index += 1;
        if (line.len >= 4 and std.mem.eql(u8, line[0..4], "--- ")) break;
        if (tags.chars) {
          var cur = line;
          while (cur.len > 0) {
            const esc = std.mem.findScalar(u8, cur, '%') orelse {
              try content.appendSlice(ret.allocator(), cur);
              break;
            };
            try content.appendSlice(ret.allocator(), cur[0..esc]);
            try content.append(ret.allocator(),
                try std.fmt.parseUnsigned(u8, cur[esc+1..esc+3], 16));
            cur = cur[esc+3..];
          }
        } else {
          try content.appendSlice(ret.allocator(), line);
        }
        try content.appendSlice(ret.allocator(), newline);
      }
      if (tags.strip) {
        if (std.mem.findLastAny(u8, content.items, "\r\n\t ")) |e| {
          content.shrinkRetainingCapacity(e);
          try content.append(ret.allocator(), '\n');
        }
      }
      var found = false;
      if (name_end == null) {
        inline for (.{"inline", "file", "input", "output", "errors"}) |field| {
          if (std.mem.eql(u8, field, item_name)) {
            try @field(ret.params, field).put("", .{
              .line_offset = start, .content = content,
            });
            found = true;
          }
        }
      } else {
        if (sub_name.len == 0) return failWith(
          name, "subname must follow after ':'", .{});
        inline for (.{"inline", "file", "input", "output", "errors"}) |field| {
          if (std.mem.eql(u8, field, item_name)) {
            try @field(ret.params, field).put(
              sub_name, .{.line_offset = start, .content = content});
            found = true;
            break;
          }
        }
        if (!found) {
          return failWith(name, "unknown selector: `{s}`", .{item_name});
        }
      }
      if (!found) try ret.items.put(
        item_name, .{.line_offset = start, .content = content});
    }
    return ret;
  }

  pub fn deinit(f: *File) void {
    f.arena.deinit();
  }
};

test "simple file" {
  var f = try File.load(std.testing.allocator, "test file",
    \\=== Titel
    \\--- input
    \\a b c
    \\--- errors:expr {strip}
    \\foo
    \\--- inline:a
    \\d e
  );
  defer f.deinit();
  try std.testing.expectEqualStrings("Titel", f.name);

  try std.testing.expectEqual(@as(u32, 1), f.params.input.count());
  const input = f.params.input.get("").?;
  try std.testing.expectEqual(@as(usize, 2), input.line_offset);
  try std.testing.expectEqualStrings("a b c\n", input.content.items);

  try std.testing.expectEqual(@as(u32, 1), f.params.errors.count());
  const ast = f.params.errors.get("expr").?;
  try std.testing.expectEqual(@as(usize, 4), ast.line_offset);
  try std.testing.expectEqualStrings("foo\n", ast.content.items);

  try std.testing.expectEqual(@as(u32, 1), f.params.@"inline".count());
  const a = f.params.@"inline".get("a").?;
  try std.testing.expectEqual(@as(usize, 6), a.line_offset);
  try std.testing.expectEqualStrings("d e\n", a.content.items);
}

test "chars" {
  var f = try File.load(std.testing.allocator, "test file",
    \\=== Chars test
    \\--- input {chars}
    \\a b %0A
  );
  defer f.deinit();
  try std.testing.expectEqualStrings("Chars test", f.name);

  try std.testing.expectEqual(@as(u32, 1), f.params.input.count());
  const input = f.params.input.get("").?;
  try std.testing.expectEqual(@as(usize, 2), input.line_offset);
  try std.testing.expectEqualStrings("a b \n\n", input.content.items);
}

test "trailing newline" {
  var f = try File.load(std.testing.allocator, "trailing newline",
    \\=== Trailing newline
    \\--- input
    \\wurbl
    \\--- output
    \\wurbl
    \\
  );
  defer f.deinit();
  try std.testing.expectEqualStrings("Trailing newline", f.name);

  try std.testing.expectEqual(@as(u32, 1), f.params.input.count());
  try std.testing.expectEqual(@as(u32, 1), f.params.output.count());
  const output = f.params.output.get("").?;
  try std.testing.expectEqualStrings("wurbl\n", output.content.items);
}
