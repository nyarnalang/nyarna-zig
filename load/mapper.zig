const std = @import("std");
const data = @import("data");

pub const Mapper = struct {
  const Self = @This();

  pub const Cursor = struct {
    param: union(enum) {
      index: usize,
      kind: data.Node.UnresolvedCall.ParamKind,
    },
    config: bool,
  };

  pub const ParamFlag = enum {
    flow, block_no_config, block_with_config
  };

  mapFn: fn(self: *Self, pos: data.Position, input: data.Node.UnresolvedCall.ParamKind, flag: ParamFlag) ?Cursor,
  pushFn: fn(self: *Self, alloc: *std.mem.Allocator, at: Cursor, content: *data.Node) std.mem.Allocator.Error!void,
  configFn: fn(self: *Self, at: Cursor) ?*data.BlockConfig,
  finalizeFn: fn(self: *Self, alloc: *std.mem.Allocator, pos: data.Position) std.mem.Allocator.Error!*data.Node,

  pub fn map(self: *Self, pos: data.Position, input: data.Node.UnresolvedCall.ParamKind, flag: ParamFlag) ?Cursor {
    return self.mapFn(self, pos, input, flag);
  }

  pub fn config(self: *Self, at: Cursor) ?*data.BlockConfig {
    return self.configFn(self, at);
  }

  pub fn push(self: *Self, alloc: *std.mem.Allocator, at: Cursor, content: *data.Node) !void {
    try self.pushFn(self, alloc, at, content);
  }

  pub fn finalize(self: *Self, alloc: *std.mem.Allocator, pos: data.Position) std.mem.Allocator.Error!*data.Node {
    return self.finalizeFn(self, alloc, pos);
  }
};

pub const SignatureMapper = struct {
  mapper: Mapper,
  subject: *data.Expression,
  signature: *data.Signature,
  cur_pos: ?u31 = 0,
  args: []*data.Node,

  pub fn init(alloc: *std.mem.Allocator, subject: *data.Expression, sig: *data.Signature) !SignatureMapper {
    return .{
      .mapper = .{
        .mapFn = SignatureMapper.map,
        .configFn = SignatureMapper.config,
        .pushFn = SignatureMapper.push,
        .finalizeFn = SignatureMapper.finalize,
      },
      .subject = subject,
      .signature = sig,
      .args = try alloc.alloc(*data.Node, sig.parameter.len),
    };
  }

  fn map(mapper: *Mapper, pos: data.Position, input: data.Node.UnresolvedCall.ParamKind, flag: Mapper.ParamFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);

    switch (input) {
      .named, .direct => |name| {
        self.cur_pos = null;
        for (self.signature.parameter) |i, p| {
          if ((p.capture != .varmap or input == .direct) and
              std.mem.eql(u8, name, p.name)) {
            return Cursor{.param = .{.index = i}, .direct = input == .direct};
          }
        }
        // TODO: errmsg?
        return null;
      },
      .primary => {
        self.cur_pos = null;
        if (self.signature.primary) |index| {
          return Mapper.Cursor{.index = index, .direct = false};
        } else {
          // TODO: errmsg?
          return null;
        }
      },
      .position => {
        if (self.cur_pos) |index| {
          if (index < self.signature.parameter.len) {
            if (self.signature.parameter[index].capture != .varargs) {
              self.cur_pos = index + 1;
            }
            return Cursor{.param = .{.index = index}, .direct = false};
          } else {
            // TODO: errmsg
            return null;
          }
        } else {
          // TODO: errmsg
          return null;
        }
      },
    }
  }

  fn config(mapper: *Mapper, at: Mapper.Cursor) ?*data.BlockConfig {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return &self.signature.parameter[at.index].config;
  }

  fn push(mapper: *Mapper, alloc: *self.mem.Allocator, at: Cursor, content: *data.Node) void {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    if (self.signature.parameter[at.index].capture == .varargs and !c.direct) {
      unreachable; // TODO
    } else if (self.signature.parameter[at.index].capture == .varmap and !c.direct) {
      unreachable; // TODO
    } else {
      self.args[c.index] = content;
    }
  }

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position) !*data.Node {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    const ret = try alloc.create(data.Node);
    ret.* = .{
      .position = pos,
      .data = .{
        .resolved_call = .{
          .target = self.subject,
          .args = self.args,
        },
      },
    };
    return ret;
  }
};

pub const CollectingMapper = struct {
  mapper: Mapper,
  target: *data.Node,
  items: std.ArrayListUnmanaged(data.Node.UnresolvedCall.Param) = .{},
  first_block: ?usize = null,

  pub fn init(target: *data.Node) CollectingMapper {
    return .{
      .mapper = .{
        .mapFn = CollectingMapper.map,
        .configFn = CollectingMapper.config,
        .pushFn = CollectingMapper.push,
        .finalizeFn = CollectingMapper.finalize,
      },
      .target = target,
    };
  }

  fn map(mapper: *Mapper, pos: data.Position, input: data.Node.UnresolvedCall.ParamKind, flag: Mapper.ParamFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    if (flag != .flow and self.first_block == null) {
      self.first_block = self.items.items.len;
    }
    return Mapper.Cursor{.param = .{.kind = input}, .config = flag == .block_with_config};
  }

  fn config(mapper: *Mapper, at: Mapper.Cursor) ?*data.BlockConfig {
    return null;
  }

  fn push(mapper: *Mapper, alloc: *std.mem.Allocator, at: Mapper.Cursor, content: *data.Node) !void {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    try self.items.append(alloc, .{.kind = at.param.kind, .content = content, .had_explicit_block_config = at.config});
  }

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position) std.mem.Allocator.Error!*data.Node {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    var ret = try alloc.create(data.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .unresolved_call = .{
          .target = self.target,
          .params = self.items.items,
          .first_block_param = self.first_block orelse self.items.items.len,
        },
      },
    };
    return ret;
  }
};

pub const AssignmentMapper = struct {
  mapper: Mapper,
  subject: *data.Node,
  replacement: ?*data.Node,

  pub fn init(subject: *data.Node) AssignmentMapper {
    return .{
      .mapper = .{
        .mapFn = AssignmentMapper.map,
        .configFn = AssignmentMapper.config,
        .pushFn =  AssignmentMapper.push,
        .finalizeFn = AssignmentMapper.finalize,
      },
      .subject = subject,
      .replacement = null,
    };
  }

  pub fn map(mapper: *Mapper, pos: data.Position, input: data.Node.UnresolvedCall.ParamKind, flag: Mapper.ParamFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    if (input == .named or input == .direct) {
      // TODO: report error
      return null;
    } else if (self.replacement != null) {
      // TODO: report error
      return null;
    }
    return Mapper.Cursor{.param = .{.index = 0}, .config = flag == .block_with_config};
  }

  fn push(mapper: *Mapper, alloc: *std.mem.Allocator, at: Mapper.Cursor, content: *data.Node) !void {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    self.replacement = content;
  }

  fn config(mapper: *Mapper, at: Mapper.Cursor) ?*data.BlockConfig {
    // TODO: block config on variable definition
    return null;
  }

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position) !*data.Node {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    const ret = try alloc.create(data.Node);
    ret.* = .{
      .pos = pos,
      .data = .{
        .assignment = .{
          .target = .{
            .unresolved = self.subject,
          },
          .replacement = self.replacement.? // TODO: error when missing
        },
      },
    };
    return ret;
  }
};
