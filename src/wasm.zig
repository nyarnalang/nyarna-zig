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

  storage : std.heap.ArenaAllocator,
  resolver: MapResolver,
  args    : std.ArrayListUnmanaged(Arg),
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

export fn allocStr(self: *Input, len: usize) ?[*]u8 {
  const ret = self.storage.allocator().alloc(u8, len) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  return ret.ptr;
}

export fn createInput() ?*Input {
  const ret = std.heap.page_allocator.create(Input) catch |err| {
    const name = @errorName(err);
    consoleLog(name.ptr, @intCast(u8, name.len));
    return null;
  };
  ret.* = .{
    .storage  = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    .resolver = undefined,
    .args     = .{},
  };
  ret.resolver = MapResolver.init(ret.storage.allocator());
  return ret;
}

export fn destroyInput(self: *Input) void {
  self.storage.deinit();
  std.heap.page_allocator.destroy(self);
}

/// name and content must have been created via allocStr and will be owned by
/// the input.
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
  self.args.append(self.storage.allocator(), .{
    .name = name[0..name_len], .content = content[0..content_len],
  }) catch |err| {
    const en = @errorName(err);
    consoleLog(en.ptr, @intCast(u8, en.len));
    return false;
  };
  return true;
}

export fn process(self: *Input, main: [*]const u8, main_len: usize) ?*Result {
  var error_out = std.ArrayList(u8).init(self.storage.allocator());
  var term = errors.Terminal(@TypeOf(error_out).Writer, false).init(
    error_out.writer());

  var stdlib = nyarna.Loader.MapResolver.init(self.storage.allocator());
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
    self.storage.allocator(), nyarna.default_stack_size, &term.reporter,
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
    const res = self.storage.allocator().create(Result) catch |err| {
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
    var docs = std.ArrayList(Result.Output).init(self.storage.allocator());
    defer docs.deinit();
    for (container.documents.items) |output| {
      if (
        if (output.schema) |schema| schema.backend != null else false
      ) continue;
      const name = self.storage.allocator().dupe(
        u8, output.name.content
      ) catch |err| {
        const name = @errorName(err);
        consoleLog(name.ptr, @intCast(u8, name.len));
        return null;
      };
      const content = switch (output.body.data) {
        .text => |*txt| (
          self.storage.allocator().dupe(u8, txt.content)
        ) catch |err| {
          const en = @errorName(err);
          consoleLog(en.ptr, @intCast(u8, en.len));
          return null;
        },
        else => {
          const msg = std.fmt.allocPrint(
            self.storage.allocator(), "unsupported non-text output: {s}",
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

export fn errorLength(result: *Result) usize {
  return result.error_output.len;
}

export fn errorOutput(result: *Result) [*]const u8 {
  return result.error_output.ptr;
}

export fn outputLength(result: *Result) usize {
  return result.documents.len;
}

export fn documentNameLength(result: *Result, index: usize) usize {
  return result.documents[index].name.len;
}

export fn documentName(result: *Result, index: usize) [*]const u8 {
  return result.documents[index].name.ptr;
}

export fn documentContentLength(result: *Result, index: usize) usize {
  return result.documents[index].content.len;
}

export fn documentContent(result: *Result, index: usize) [*]const u8 {
  return result.documents[index].content.ptr;
}

pub fn panic(
  msg: []const u8,
  _  : ?*std.builtin.StackTrace,
) noreturn {
  consoleLog(msg.ptr, @intCast(u8, msg.len));
  unreachable;
}