const std = @import("std");

const nyarna      = @import("nyarna.zig");
const MapResolver = @import("nyarna/Loader/MapResolver.zig");

const errors = nyarna.errors;

const system_ny = @embedFile("../lib/system.ny") ++ "\x04\x04\x04\x04";
const meta_ny   = @embedFile("../lib/meta.ny")   ++ "\x04\x04\x04\x04";
const schema_ny = @embedFile("../lib/Schema.ny") ++ "\x04\x04\x04\x04";

pub const Input = struct {
  const Arg = struct {
    name   : []const u8,
    content: []const u8,
  };

  resolver: MapResolver,
  args    : std.ArrayList(Arg),
};

pub const Result = struct {
  const Missing = struct {
    name   : []const u8,
    @"type": []const u8,
  };
  const Output = struct {
    name   : []const u8,
    content: []const u8,
  };

  missing_args: []Missing  = &.{},
  error_output: []const u8 = &.{},
  documents   : []Output   = &.{},
};

extern fn consoleLog(message: [*]const u8, length: u8) void;

export fn createInput() ?*Input {
  const ret = std.heap.page_allocator.create(Input) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  ret.* = .{
    .resolver = MapResolver.init(),
    .args = std.ArrayList(Input.Arg).init(std.heap.page_allocator),
  };
  return ret;
}

export fn pushInput(
  self       : *Input,
  name       : [*]const u8,
  name_len   : usize,
  content    : [*]const u8,
  content_len: usize,
) bool {
  self.resolver.content.put(
    name[0..name_len], content[0..content_len]
  ) catch |err| {
    const en = @errorName(err);
    consoleLog(en.ptr, @intCast(u8, en.len));
    return false;
  };
  return true;
}

export fn pushArg(
  self       : *Input,
  name       : [*]const u8,
  name_len   : usize,
  content    : [*]const u8,
  content_len: usize,
) bool {
  self.args.append(.{
    .name = name[0..name_len], .content = content[0..content_len],
  }) catch |err| {
    const en = @errorName(err);
    consoleLog(en.ptr, @intCast(u8, en.len));
    return false;
  };
  return true;
}

export fn process(self: *Input, main: [*]const u8, main_len: usize) ?*Result {
  var error_out = std.ArrayList(u8).init(std.heap.page_allocator);
  var term = errors.Terminal(@TypeOf(error_out).Writer, false).init(
    error_out.writer());

  var stdlib = nyarna.Loader.MapResolver.init();
  stdlib.content.put("system", system_ny) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  stdlib.content.put("meta", meta_ny) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  stdlib.content.put("Schema", schema_ny) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };

  var proc = nyarna.Processor.init(
    std.heap.page_allocator, nyarna.default_stack_size, &term.reporter,
    &stdlib.api
  ) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  defer proc.deinit();

  var loader = proc.startLoading(
    &self.resolver.api, main[0..main_len]
  ) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };

  for (self.args.items) |item| {
    loader.pushArg(item.name, item.content) catch |err| {
      const name = @errorName(err);
      consoleLog(name.ptr, @intCast(u8, name.len));
      return null;
    };
  }

  if (
    loader.finalize() catch |err| {
      const name = @errorName(err);
      consoleLog(name.ptr, @intCast(u8, name.len));
      return null;
    }
  ) |container| {
    defer container.destroy();
    const res = std.heap.page_allocator.create(Result) catch |err| {
      const name = @errorName(err);
      consoleLog(name.ptr, @intCast(u8, name.len));
      return null;
    };
    if (
      !(container.process() catch |err| {
        const name = @errorName(err);
        consoleLog(name.ptr, @intCast(u8, name.len));
        return null;
      })
    ) {
      res.* = .{.error_output = error_out.items};
      return res;
    }
    res.* = .{};
    var docs = std.ArrayList(Result.Output).init(std.heap.page_allocator);
    defer docs.deinit();
    for (container.documents.items) |output| {
      if (
        if (output.schema) |schema| schema.backend != null else false
      ) continue;
      const name = std.heap.page_allocator.dupe(
        u8, output.name.content
      ) catch |err| {
        const name = @errorName(err);
        consoleLog(name.ptr, @intCast(u8, name.len));
        return null;
      };
      const content = switch (output.body.data) {
        .text => |*txt| std.heap.page_allocator.dupe(u8, txt.content) catch |err| {
          const en = @errorName(err);
          consoleLog(en.ptr, @intCast(u8, en.len));
          return null;
        },
        else => {
          const msg = std.fmt.allocPrint(
            std.heap.page_allocator, "unsupported non-text output: {s}",
            .{@tagName(output.body.data)}
          ) catch |err| @as([]const u8, @errorName(err));
          consoleLog(msg.ptr, @intCast(u8, msg.len));
          return null;
        },
      };
      docs.append(.{.name = name, .content = content}) catch |err| {
        const en = @errorName(err);
        consoleLog(en.ptr, @intCast(u8, en.len));
        return null;
      };
    }
    res.* = .{
      .documents = docs.toOwnedSlice(),
    };
    return res;
  }
  return null; // TODO: missing_inputs
}

pub fn panic(
  msg: []const u8,
  _  : ?*std.builtin.StackTrace,
) noreturn {
  consoleLog(msg.ptr, @intCast(u8, msg.len));
  unreachable;
}