//! this namespace contains facilities for syntax highlighting via the
//! predefined keyword \highlight

const std = @import("std");

const nyarna = @import("../nyarna.zig");

const errors = nyarna.errors;
const Loader = nyarna.Loader;

pub const Error = error {
  OutOfMemory,
  syntax_parser_error,
};

/// Description of a syntax highlighter. Use Processor to execute it.
pub const Syntax = struct {
  pub const Item = union(enum) {
    text : []const u8,
    enter: usize,
    exit : usize,
  };

  pub const Processor = struct {
    syntax   : *Syntax,
    nextFn   : fn(self: *Processor) Error!?Item,
    destroyFn: fn(self: *Processor) void,

    pub fn create(
      allocator: std.mem.Allocator,
      syntax   : *Syntax,
      input    : []const u8,
    ) std.mem.Allocator.Error!*Processor {
      return syntax.createProcFn(allocator, syntax, input);
    }

    pub fn destroy(self: Processor) void {
      self.destroyFn(self);
    }

    pub fn next(self: *@This()) Error!?Item {
      return self.nextFn(self);
    }
  };

  /// nodes that make up the structure of this syntax
  node_kinds: []const []const u8,

  createProcFn: fn(
    allocator: std.mem.Allocator,
    syntax   : *Syntax,
    input    : []const u8,
  ) std.mem.Allocator.Error!void,
};

/// highlighter for Nyarna syntax
pub const NyarnaSyntax = struct {
  const nodes = []const []const u8{
    "comment", "keyword", "symref", "special", "tag"
  };

  syntax: Syntax,
  stdlib: *Loader.Resolver,

  fn init(stdlib: *Loader.Resolver) NyarnaSyntax {
    return .{
      .syntax = .{
        .node_kinds   = nodes,
        .createProcFn = createProc,
      },
      .stdlib = stdlib,
    };
  }

  fn createProc(
    allocator: std.mem.Allocator,
    syntax: *Syntax,
    input: []const u8,
  ) std.mem.Allocator.Error!void {
    const self = @fieldParentPtr(NyarnaSyntax, "syntax", syntax);
    const ret = try allocator.create(NyarnaProcessor);
    errdefer allocator.destroy(ret);
    ret.* = .{
      .proc = .{
        .syntax    = syntax,
        .nextFn    = NyarnaProcessor.next,
        .destroyFn = NyarnaProcessor.destroy,
      },
      .ignore    = errors.Ignore.init(),
      .nyarna    = undefined,
      .main      = undefined,
      .doc_res   = undefined,
      .allocated = false,
    };
    const content = if (
      input.len < 4 or
      !std.mem.eql(u8, input[input.len - 4..], "\x04\x04\x04\x04")
    ) blk: {
      const buffer = try allocator.alloc(u8, input.len + 4);
      std.mem.copy(u8, buffer, input);
      std.mem.copy(u8, buffer[input.len..], "\x04\x04\x04\x04");
      ret.allocated = true;
      break :blk buffer;
    } else input;
    errdefer if (ret.allocated) allocator.free(content);
    ret.doc_res = Loader.SingleResolver.init(content);
    ret.nyarna = try nyarna.Processor.init(
      allocator, nyarna.default_stack_size, &ret.ignore.reporter, self.stdlib);
    errdefer (ret.nyarna.deinit());
    ret.main = ret.nyarna.initMainModule(&ret.doc_res.resolver, "", true);
    return &ret.proc;
  }
};

const NyarnaProcessor = struct {
  proc     : Syntax.Processor,
  ignore   : errors.Ignore,
  nyarna   : nyarna.Processor,
  main     : *Loader.Main,
  doc_res  : Loader.SingleResolver,
  allocated: bool,

  fn next(proc: *Syntax.Processor) Error!?Syntax.Item {
    _ = proc;
    return null;
  }

  fn destroy(proc: *Syntax.Processor) void {
    _ = proc;
  }
};