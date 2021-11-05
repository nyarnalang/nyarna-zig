const std = @import("std");

pub const Value = struct {
  line_offset: usize,
  /// uses the arena allocator of the containing File. given like this so that
  /// end markers ("\x04") can be appended as required by the lexer.
  content: std.ArrayListUnmanaged(u8),
};

pub const Values = std.StringHashMap(Value);

const ParseError = error {
  parsing_failed,
};

const Tags = struct {
  strip: bool = false,
  crlf: bool = false,
  chars: bool = false,
};

pub const File = struct {
  arena: std.heap.ArenaAllocator,
  name: []const u8,
  items: Values,
  params: struct {
    @"inline": Values,
    file: Values,
    lib: Values,
    output: Values,
    errors: Values,
  },

  fn failWith(path: []const u8, comptime msg: []const u8, args: anytype) ParseError {
    std.log.err("{s}: " ++ msg ++ "\n", .{path} ++ args);
    return ParseError.parsing_failed;
  }

  pub fn alloc(f: *File) *std.mem.Allocator {
    return &f.arena.allocator;
  }

  pub fn loadPath(path: []const u8) !File {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, (try file.stat()).size + 1);
    defer std.testing.allocator.free(file_contents);
    return load(path, file_contents);
  }

  pub fn loadFile(dir: *std.fs.Dir, path: []const u8, file: *std.fs.File) !File {
    const file_contents = try dir.readFileAlloc(
      std.testing.allocator, path, (try file.stat()).size + 1);
    defer std.testing.allocator.free(file_contents);
    return load(path, file_contents);
  }

  pub fn load(name: []const u8, input: []const u8) !File {
    var lines = std.mem.split(u8, input, "\n");

    var line = lines.next() orelse {
      return failWith(name, "missing header", .{});
    };
    var line_index: u32 = 1;
    if (!std.mem.eql(u8, line[0..4], "=== ")) {
      return failWith(name, "file does not start with `=== `", .{});
    }
    var ret: File = undefined;
    ret.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer ret.deinit();
    ret.items = Values.init(ret.alloc());
    ret.params = .{
      .@"inline" = Values.init(ret.alloc()),
      .file = Values.init(ret.alloc()),
      .lib = Values.init(ret.alloc()),
      .output = Values.init(ret.alloc()),
      .errors = Values.init(ret.alloc()),
    };
    ret.name = try ret.alloc().dupe(u8, line[4..]);

    line = lines.next() orelse {
      return failWith(name, "missing value after header", .{});
    };
    line_index += 1;

    var line_available = true;
    while (line_available) {
       const start = line_index;
       const header = line[4..];
       const name_end = std.mem.indexOfScalar(u8, header, ':');
       const tag_start = std.mem.indexOfScalar(u8, header, '{');
       var sub_name: []const u8 = "";
       const item_name = std.mem.trim(u8, try ret.alloc().dupe(u8, blk: {
         if (name_end) |val| {
          if (tag_start) |tval| {
            if (val > tval) return failWith(name, "`{{` before `:` in value header", .{});
            sub_name = try ret.alloc().dupe(u8, std.mem.trim(u8, header[val + 1..tval], " \t"));
          } else {
            sub_name = try ret.alloc().dupe(u8, std.mem.trim(u8, header[val + 1..], " \t"));
          }
          break :blk header[0..val];
        } else if (tag_start) |tval| {
          break :blk header[0..tval];
        } else break :blk header;
      }), " \t");
      var tags = Tags{};
      if (tag_start) |tval| {
        const tag_end = std.mem.lastIndexOfScalar(u8, header, '}') orelse {
          return failWith(name, "header misses `}}`", .{});
        };
        if (tag_end != std.mem.trimRight(u8, header, " \t").len - 1) {
          return failWith(name, "content after `}}`", .{});
        }
        var tags_str = std.mem.trimRight(u8, header[tval..tag_end], " \t");
        var sep: ?usize = 0;
        while (sep) |b| {
          tags_str = std.mem.trimLeft(u8, tags_str[b + 1..], " \t");
          if (tags_str.len == 0) break;
          sep = std.mem.indexOfScalar(u8, tags_str, ',');
          const tag = std.mem.trim(u8, if (sep) |e| tags_str[0..e] else tags_str, " \t");
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

      var content: std.ArrayListUnmanaged(u8) = .{};
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
            const esc = std.mem.indexOfScalar(u8, cur, '%') orelse {
              try content.appendSlice(ret.alloc(), cur);
              break;
            };
            try content.appendSlice(ret.alloc(), cur[0..esc]);
            try content.append(ret.alloc(),
                try std.fmt.parseUnsigned(u8, cur[esc+1..esc+3], 16));
            cur = cur[esc+3..];
          }
        } else {
          try content.appendSlice(ret.alloc(), line);
        }
        try content.appendSlice(ret.alloc(), newline);
      }
      if (tags.strip) {
        if (std.mem.lastIndexOfAny(u8, content.items, "\r\n\t ")) |e| {
          content.shrinkRetainingCapacity(e);
          try content.append(ret.alloc(), '\n');
        }
      }
      var found = false;
      inline for (.{"inline", "file", "lib", "output", "errors"}) |field| {
        if (std.mem.eql(u8, field, item_name)) {
          try @field(ret.params, field).put(sub_name, .{.line_offset = start, .content = content});
          found = true;
          break;
        }
      }
      if (!found) {
        if (sub_name.len > 0) {
          return failWith(name, "unknown selector: `{s}`", .{item_name});
        } else {
          try ret.items.put(item_name, .{.line_offset = start, .content = content});
        }
      }
    }
    return ret;
  }

  pub fn deinit(f: *File) void {
    f.arena.deinit();
  }
};

test "simple file" {
  var f = try File.load("test file",
    \\=== Titel
    \\--- input
    \\a b c
    \\--- errors:ast {strip}
    \\foo
    \\--- inline:a
    \\d e
  );
  defer f.deinit();
  try std.testing.expectEqualStrings("Titel", f.name);

  try std.testing.expectEqual(@as(u32, 1), f.items.count());
  const input = f.items.get("input").?;
  try std.testing.expectEqual(@as(usize, 2), input.line_offset);
  try std.testing.expectEqualStrings("a b c\n", input.content.items);

  try std.testing.expectEqual(@as(u32, 1), f.params.errors.count());
  const ast = f.params.errors.get("ast").?;
  try std.testing.expectEqual(@as(usize, 4), ast.line_offset);
  try std.testing.expectEqualStrings("foo\n", ast.content.items);

  try std.testing.expectEqual(@as(u32, 1), f.params.@"inline".count());
  const a = f.params.@"inline".get("a").?;
  try std.testing.expectEqual(@as(usize, 6), a.line_offset);
  try std.testing.expectEqualStrings("d e\n", a.content.items);
}

test "chars" {
  var f = try File.load("test file",
    \\=== Chars test
    \\--- input {chars}
    \\a b %0A
  );
  defer f.deinit();
  try std.testing.expectEqualStrings("Chars test", f.name);

  try std.testing.expectEqual(@as(u32, 1), f.items.count());
  const input = f.items.get("input").?;
  try std.testing.expectEqual(@as(usize, 2), input.line_offset);
  try std.testing.expectEqualStrings("a b \n\n", input.content.items);
}