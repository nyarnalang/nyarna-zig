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

extern fn consoleLog(
  descr: [*]const u8,
  descr_len: usize,
  message: [*]const u8,
  length: usize,
) void;

fn jsLog(descr: []const u8, message: []const u8) void {
  consoleLog(descr.ptr, descr.len, message.ptr, message.len);
}

export fn allocStr(self: *Input, len: usize) ?[*]u8 {
  const ret = self.storage.allocator().alloc(u8, len) catch |err| {
    const name = @errorName(err);
    jsLog("error while allocating:", name);
    return null;
  };
  return ret.ptr;
}

export fn createInput() ?*Input {
  const ret = std.heap.page_allocator.create(Input) catch |err| {
    const name = @errorName(err);
    jsLog("error while creating input:", name);
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
    jsLog("error while adding input:", @errorName(err));
    return false;
  };
  jsLog("pushed input:", name[0..name_len]);
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
    jsLog("error while adding arg:", @errorName(err));
    return false;
  };
  return true;
}

fn pushStdlib(
  self: *nyarna.Loader.MapResolver,
  name: []const u8,
  content: []const u8,
) bool {
  self.content.put(name, content) catch |err| {
    jsLog("error while building stdlib:", @errorName(err));
    return false;
  };
  return true;
}

export fn process(self: *Input, main: [*]const u8, main_len: usize) ?*Result {
  var error_out = std.ArrayList(u8).init(self.storage.allocator());
  var term = errors.Terminal(@TypeOf(error_out).Writer, false).init(
    error_out.writer());

  jsLog("debug", "initializing stdlib");
  var stdlib = nyarna.Loader.MapResolver.init(self.storage.allocator());
  if (!pushStdlib(&stdlib, "system", system_ny)) return null;
  if (!pushStdlib(&stdlib, "meta", meta_ny)) return null;
  if (!pushStdlib(&stdlib, "Schema", schema_ny)) return null;

  jsLog("debug", "initializing processor");
  var proc = nyarna.Processor.init(
    self.storage.allocator(), nyarna.default_stack_size, &term.reporter,
    &stdlib.api
  ) catch |err| {
    jsLog("error while initializing Processor:", @errorName(err));
    return null;
  };
  defer proc.deinit();

  jsLog("debug", "start loading");
  var loader = proc.startLoading(
    &self.resolver.api, main[0..main_len]
  ) catch |err| {
    jsLog("error while starting to load main module:", @errorName(err));
    return null;
  };

  jsLog("debug", "push args");
  for (self.args.items) |item| {
    loader.pushArg(item.name, item.content) catch |err| {
      jsLog("error while pushing argument:", @errorName(err));
      return null;
    };
  }

  jsLog("debug", "finalize loading");
  const res = self.storage.allocator().create(Result) catch |err| {
    jsLog("error while allocating Result:", @errorName(err));
    return null;
  };
  res.* = .{};
  if (
    loader.finalize() catch |err| {
      jsLog("error while finalizing loader:", @errorName(err));
      return null;
    }
  ) |container| {
    if (
      !(container.process() catch |err| {
        jsLog("error while processing containers:", @errorName(err));
        return null;
      })
    ) {
      res.* = .{.error_output = error_out.items};
      return res;
    }
    defer container.destroy();
    var docs = std.ArrayList(Result.Output).init(self.storage.allocator());
    defer docs.deinit();
    for (container.documents.items) |output| {
      if (
        if (output.schema) |schema| schema.backend != null else false
      ) continue;
      const name = self.storage.allocator().dupe(
        u8, output.name.content
      ) catch |err| {
        jsLog("error while allocating output name:", @errorName(err));
        return null;
      };
      const content = switch (output.body.data) {
        .text => |*txt| (
          self.storage.allocator().dupe(u8, txt.content)
        ) catch |err| {
          jsLog("error while allocating output content:", @errorName(err));
          return null;
        },
        else => {
          jsLog("unsupported non-text output:", @tagName(output.body.data));
          return null;
        },
      };
      docs.append(.{.name = name, .content = content}) catch |err| {
        jsLog("error while appending output document:", @errorName(err));
        return null;
      };
    }
    res.* = .{
      .documents = docs.toOwnedSlice(),
    };
    return res;
  }
  // TODO: missing inputs
  res.* = .{.error_output = error_out.items};
  return res;
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

extern fn throwPanic(msg: [*]const u8, msg_size: usize) noreturn;

pub fn panic(
  msg: []const u8,
  _  : ?*std.builtin.StackTrace,
  _  : ?usize,
) noreturn {
  throwPanic(msg.ptr, msg.len);
}