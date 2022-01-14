const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const Type = model.Type;
const Interpreter = @import("interpret.zig").Interpreter;

pub const Mapper = struct {
  const Self = @This();

  pub const Cursor = struct {
    param: union(enum) {
      index: u21,
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
  const ArgKind = model.Node.UnresolvedCall.ArgKind;

  mapFn: fn(self: *Self, pos: model.Position, input: ArgKind,
            flag: ProtoArgFlag) ?Cursor,
  pushFn: fn(self: *Self, at: Cursor, content: *model.Node) nyarna.Error!void,
  configFn: fn(self: *Self, at: Cursor) ?*model.BlockConfig,
  paramTypeFn: fn(self: *Self, at: Cursor) ?model.Type,
  finalizeFn: fn(self: *Self, pos: model.Position) nyarna.Error!*model.Node,

  pub fn map(self: *Self, pos: model.Position, input: ArgKind,
             flag: ProtoArgFlag) ?Cursor {
    return self.mapFn(self, pos, input, flag);
  }

  pub fn config(self: *Self, at: Cursor) ?*model.BlockConfig {
    return self.configFn(self, at);
  }

  pub fn paramType(self: *Self, at: Cursor) ?model.Type {
    return self.paramTypeFn(self, at);
  }

  pub fn push(self: *Self, at: Cursor, content: *model.Node) !void {
    try self.pushFn(self, at, content);
  }

  pub fn finalize(self: *Self, pos: model.Position) nyarna.Error!*model.Node {
    return self.finalizeFn(self, pos);
  }
};

pub const SignatureMapper = struct {
  mapper: Mapper,
  subject: *model.Expression,
  signature: *const Type.Signature,
  cur_pos: ?u21 = 0,
  args: []*model.Node,
  filled: []bool,
  intpr: *Interpreter,
  ns: u15,

  pub fn init(intpr: *Interpreter, subject: *model.Expression, ns: u15,
              sig: *const model.Type.Signature) !SignatureMapper {
    var res = SignatureMapper{
      .mapper = .{
        .mapFn = SignatureMapper.map,
        .configFn = SignatureMapper.config,
        .paramTypeFn = SignatureMapper.paramType,
        .pushFn = SignatureMapper.push,
        .finalizeFn = SignatureMapper.finalize,
      },
      .subject = subject,
      .signature = sig,
      .intpr = intpr,
      .ns = ns,
      .args =
        try intpr.allocator().alloc(*model.Node, sig.parameters.len),
      .filled = try intpr.allocator().alloc(bool, sig.parameters.len),
    };
    for (res.filled) |*item| item.* = false;
    return res;
  }

  /// workaround for https://github.com/ziglang/zig/issues/6059
  inline fn varmapAt(self: *SignatureMapper, index: u21) bool {
    return if (self.signature.varmap) |vm| vm == index else false;
  }

  fn map(mapper: *Mapper, pos: model.Position,
         input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    // TODO: process ProtoArgFlag (?)
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);

    switch (input) {
      .named, .direct => |name| {
        self.cur_pos = null;
        for (self.signature.parameters) |p, i| {
          const index = @intCast(u21, i);
          if ((!self.varmapAt(index) or input == .direct) and
              std.mem.eql(u8, name, p.name)) {
            return Mapper.Cursor{.param = .{.index = index},
              .config = flag == .block_with_config, .direct = input == .named};
          }
        }
        self.intpr.ctx.logger.UnknownParameter(pos);
        return null;
      },
      .primary => {
        self.cur_pos = null;
        if (self.signature.primary) |index| {
          return Mapper.Cursor{
            .param = .{.index = index},
            .config = flag == .block_with_config, .direct = true};
        } else {
          self.intpr.ctx.logger.UnexpectedPrimaryBlock(pos);
          return null;
        }
      },
      .position => {
        if (self.cur_pos) |index| {
          if (index < self.signature.parameters.len) {
            if (self.signature.parameters[index].capture != .varargs) {
              self.cur_pos = index + 1;
            }
            return Mapper.Cursor{.param = .{.index = index},
              .config = flag == .block_with_config, .direct = false};
          } else {
            self.intpr.ctx.logger.TooManyArguments(pos);
            return null;
          }
        } else {
          self.intpr.ctx.logger.InvalidPositionalArgument(pos);
          return null;
        }
      },
    }
  }

  fn config(mapper: *Mapper, at: Mapper.Cursor) ?*model.BlockConfig {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return switch (at.param) {
      .index => |index|
        if (self.signature.parameters[index].config) |*bc| bc else null,
      .kind => null
    };
  }

  fn paramType(mapper: *Mapper, at: Mapper.Cursor) ?model.Type {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return switch (at.param) {
      .index => |index| self.signature.parameters[index].ptype,
      .kind => null
    };
  }

  fn push(mapper: *Mapper, at: Mapper.Cursor, content: *model.Node)
      nyarna.Error!void {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    const param = &self.signature.parameters[at.param.index];
    const target_type =
      if (at.direct) param.ptype
      else if (self.varmapAt(at.param.index)) unreachable
      else switch (param.capture) {
      .varargs => unreachable,
      else => param.ptype,
    };
    const arg = if (target_type.is(.ast_node))
      try self.intpr.genValueNode(content.pos, .{
        .ast = .{.root = content},
      })
    else blk: {
      if (try self.intpr.associate(content, param.ptype, .{.kind = .initial}))
          |expr| content.data = .{.expression = expr};
      break :blk content;
    };
    if (self.varmapAt(at.param.index)) unreachable
    else switch (param.capture) {
      .varargs => unreachable,
      else => {}
    }
    if (self.filled[at.param.index])
      self.intpr.ctx.logger.DuplicateParameterArgument(
        self.signature.parameters[at.param.index].name, content.pos,
        self.args[at.param.index].pos)
    else {
      self.args[at.param.index] = arg;
      self.filled[at.param.index] = true;
    }
  }

  fn finalize(mapper: *Mapper, pos: model.Position) nyarna.Error!*model.Node {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    var missing_param = false;
    for (self.signature.parameters) |param, i| {
      if (!self.filled[i]) {
        self.args[i] = switch (param.ptype) {
          .intrinsic => |intr| switch (intr) {
            .void => try self.intpr.node_gen.@"void"(pos),
            .ast_node => blk: {
              break :blk try self.intpr.genValueNode(pos, .{
                .ast = .{.root = try self.intpr.node_gen.@"void"(pos)},
              });
            },
            else => null,
          },
          .structural => |strct| switch (strct.*) {
            .optional, .concat, .paragraphs =>
              try self.intpr.node_gen.@"void"(pos),
            else => null,
          },
          .instantiated => null,
        } orelse {
          self.intpr.ctx.logger.MissingParameterArgument(
            param.name, pos, param.pos);
          missing_param = true;
          continue;
        };
      }
    }
    return if (missing_param) try self.intpr.node_gen.poison(pos) else
      (try self.intpr.node_gen.rcall(pos, .{
        .ns = self.ns,
        .target = self.subject,
        .args = self.args,
      })).node();
  }
};

pub const CollectingMapper = struct {
  mapper: Mapper,
  target: *model.Node,
  items: std.ArrayListUnmanaged(model.Node.UnresolvedCall.ProtoArg) = .{},
  first_block: ?usize = null,
  intpr: *Interpreter,

  pub fn init(target: *model.Node, intpr: *Interpreter)
      CollectingMapper {
    return .{
      .mapper = .{
        .mapFn = CollectingMapper.map,
        .configFn = CollectingMapper.config,
        .paramTypeFn = CollectingMapper.paramType,
        .pushFn = CollectingMapper.push,
        .finalizeFn = CollectingMapper.finalize,
      },
      .target = target,
      .intpr = intpr,
    };
  }

  fn map(mapper: *Mapper, _: model.Position,
         input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    if (flag != .flow and self.first_block == null) {
      self.first_block = self.items.items.len;
    }
    return Mapper.Cursor{
      .param = .{.kind = input}, .config = flag == .block_with_config,
      .direct = input.isDirect()
    };
  }

  fn config(_: *Mapper, _: Mapper.Cursor) ?*model.BlockConfig {
    return null;
  }

  fn paramType(_: *Mapper, _: Mapper.Cursor) ?model.Type {
    return null;
  }

  fn push(mapper: *Mapper, at: Mapper.Cursor,
          content: *model.Node) nyarna.Error!void {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    try self.items.append(self.intpr.allocator(), .{
        .kind = at.param.kind, .content = content,
        .had_explicit_block_config = at.config
      });
  }

  fn finalize(mapper: *Mapper, pos: model.Position)
      nyarna.Error!*model.Node {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    return (try self.intpr.node_gen.ucall(pos, .{
      .target = self.target,
      .proto_args = self.items.items,
      .first_block_arg = self.first_block orelse self.items.items.len,
    })).node();
  }
};

pub const AssignmentMapper = struct {
  mapper: Mapper,
  subject: *model.Node,
  replacement: ?*model.Node,
  intpr: *Interpreter,

  pub fn init(subject: *model.Node, intpr: *Interpreter) AssignmentMapper {
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
      .intpr = intpr,
    };
  }

  pub fn map(mapper: *Mapper, _: model.Position,
             input: Mapper.ArgKind, flag: Mapper.ProtoArgFlag) ?Mapper.Cursor {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    if (input == .named or input == .direct) {
      // TODO: report error
      return null;
    } else if (self.replacement != null) {
      // TODO: report error
      return null;
    }
    return Mapper.Cursor{
      .param = .{.index = 0}, .config = flag == .block_with_config,
      .direct = input == .primary,
    };
  }

  fn push(mapper: *Mapper, _: Mapper.Cursor, content: *model.Node) !void {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    self.replacement = content;
  }

  fn config(_: *Mapper, _: Mapper.Cursor) ?*model.BlockConfig {
    // TODO: block config on variable definition
    return null;
  }

  fn paramType(_: *Mapper, _: Mapper.Cursor) ?model.Type {
    // TODO: param type of subject
    return null;
  }

  fn finalize(mapper: *Mapper, pos: model.Position) !*model.Node {
    const self = @fieldParentPtr(AssignmentMapper, "mapper", mapper);
    return (try self.intpr.node_gen.assign(pos, .{
      .target = .{
        .unresolved = self.subject,
      },
      .replacement = self.replacement.? // TODO: error when missing
    })).node();
  }
};
