const std = @import("std");
const data = @import("data");
const Type = data.Type;
const Context = @import("interpret.zig").Context;

pub const Mapper = struct {
  const Self = @This();

  pub const Cursor = struct {
    param: union(enum) {
      index: usize,
      kind: ArgKind,
    },
    config: bool,
    // true iff kind in {direct,primary}. exists to preserve this fact after
    // resolving the argument to an index.
    direct: bool,
  };

  pub const ProtoArgFlag = enum {
    flow, block_no_config, block_with_config
  };
  const ArgKind = data.Node.UnresolvedCall.ArgKind;

  mapFn: fn(self: *Self, pos: data.Position, input: ArgKind, flag: ProtoArgFlag) ?Cursor,
  pushFn: fn(self: *Self, alloc: *std.mem.Allocator, at: Cursor, content: *data.Node) std.mem.Allocator.Error!void,
  configFn: fn(self: *Self, at: Cursor) ?*data.BlockConfig,
  paramTypeFn: fn(self: *Self, at: Cursor) ?data.Type,
  finalizeFn: fn(self: *Self, alloc: *std.mem.Allocator, pos: data.Position) std.mem.Allocator.Error!*data.Node,

  pub fn map(self: *Self, pos: data.Position, input: ArgKind, flag: ProtoArgFlag) ?Cursor {
    return self.mapFn(self, pos, input, flag);
  }

  pub fn config(self: *Self, at: Cursor) ?*data.BlockConfig {
    return self.configFn(self, at);
  }

  pub fn paramType(self: *Self, at: Cursor) ?data.Type {
    return self.paramTypeFn(self, at);
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
  signature: *Type.Signature,
  cur_pos: ?u31 = 0,
  args: []*data.Node,
  context: *Context,

  pub fn init(ctx: *Context, subject: *data.Expression, sig: *data.Signature) !SignatureMapper {
    return .{
      .mapper = .{
        .mapFn = SignatureMapper.map,
        .configFn = SignatureMapper.config,
        .paramTypeFn = SignatureMapper.paramType,
        .pushFn = SignatureMapper.push,
        .finalizeFn = SignatureMapper.finalize,
      },
      .subject = subject,
      .signature = sig,
      .context = ctx,
      .args = try ctx.temp_nodes.allocator.alloc(*data.Node, sig.parameter.len),
    };
  }

  fn map(mapper: *Mapper, _: data.Position,
         input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    // TODO: process ProtoArgFlag (?)
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);

    switch (input) {
      .named, .direct => |name| {
        self.cur_pos = null;
        for (self.signature.parameter) |i, p| {
          if ((p.capture != .varmap or input == .direct) and
              std.mem.eql(u8, name, p.name)) {
            return Mapper.Cursor{.param = .{.index = i},
              .config = flag == .block_with_config, .direct = input == .named};
          }
        }
        // TODO: errmsg?
        return null;
      },
      .primary => {
        self.cur_pos = null;
        if (self.signature.primary) |index| {
          return Mapper.Cursor{.index = index,
            .config = flag == .block_with_config, .direct = true};
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
            return Mapper.Cursor{.param = .{.index = index},
              .config = flag == .block_with_config, .direct = false};
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
    return switch (at.param) {
      .index => |index| &self.signature.parameter[index].config,
      .kind => null
    };
  }

  fn paramType(mapper: *Mapper, at: Mapper.Cursor) ?data.Type {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return switch (at.param) {
      .index => |index| &self.signature.parameter[index].ptype,
      .kind => null
    };
  }

  fn push(mapper: *Mapper, _: *std.mem.Allocator, at: Mapper.Cursor, content: *data.Node) !void {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    const param = &self.signature.parameter[at.index];
    const target_type = if (at.direct) param.ptype else switch (param.capture) {
      .varargs => unreachable,
      .varmap => unreachable,
      else => param.ptype,
    };
    if (switch (target_type) {
      .intrinsic => |it| it == .ast_node,
      else => false
    }) {
      // TODO: create AST expression
      unreachable;
    } else if (try self.context.associate(content, param.ptype)) |expr| {
      self.context.data = .{.expression = expr};
    }
    switch (param.capture) {
      .varargs => unreachable,
      .varmap => unreachable,
      else => self.args[at.index] = content,
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
  items: std.ArrayListUnmanaged(data.Node.UnresolvedCall.ProtoArg) = .{},
  first_block: ?usize = null,

  pub fn init(target: *data.Node) CollectingMapper {
    return .{
      .mapper = .{
        .mapFn = CollectingMapper.map,
        .configFn = CollectingMapper.config,
        .paramTypeFn = CollectingMapper.paramType,
        .pushFn = CollectingMapper.push,
        .finalizeFn = CollectingMapper.finalize,
      },
      .target = target,
    };
  }

  fn map(mapper: *Mapper, _: data.Position,
         input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    if (flag != .flow and self.first_block == null) {
      self.first_block = self.items.items.len;
    }
    return Mapper.Cursor{.param = .{.kind = input}, .config = flag == .block_with_config,
      .direct = input.isDirect()};
  }

  fn config(_: *Mapper, _: Mapper.Cursor) ?*data.BlockConfig {
    return null;
  }

  fn paramType(_: *Mapper, _: Mapper.Cursor) ?data.Type {
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
          .proto_args = self.items.items,
          .first_block_arg = self.first_block orelse self.items.items.len,
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
        .paramTypeFn = AssignmentMapper.paramType,
        .pushFn =  AssignmentMapper.push,
        .finalizeFn = AssignmentMapper.finalize,
      },
      .subject = subject,
      .replacement = null,
    };
  }

  pub fn map(mapper: *Mapper, _: data.Position,
             input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    if (input == .named or input == .direct) {
      // TODO: report error
      return null;
    } else if (self.replacement != null) {
      // TODO: report error
      return null;
    }
    return Mapper.Cursor{.param = .{.index = 0}, .config = flag == .block_with_config,
      .direct = input == .primary};
  }

  fn push(mapper: *Mapper, _: *std.mem.Allocator, _: Mapper.Cursor, content: *data.Node) !void {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    self.replacement = content;
  }

  fn config(_: *Mapper, _: Mapper.Cursor) ?*data.BlockConfig {
    // TODO: block config on variable definition
    return null;
  }

  fn paramType(_: *Mapper, _: Mapper.Cursor) ?data.Type {
    // TODO: param type of subject
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
