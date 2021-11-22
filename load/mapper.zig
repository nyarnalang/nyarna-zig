const std = @import("std");
const nyarna = @import("../nyarna.zig");
const data = nyarna.data;
const Type = data.Type;
const Interpreter = nyarna.Interpreter;

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
  const ArgKind = data.Node.UnresolvedCall.ArgKind;

  mapFn: fn(self: *Self, pos: data.Position, input: ArgKind,
            flag: ProtoArgFlag) ?Cursor,
  pushFn: fn(self: *Self, alloc: *std.mem.Allocator, at: Cursor,
             content: *data.Node) nyarna.Error!void,
  configFn: fn(self: *Self, at: Cursor) ?*data.BlockConfig,
  paramTypeFn: fn(self: *Self, at: Cursor) ?data.Type,
  finalizeFn: fn(self: *Self, alloc: *std.mem.Allocator,
                 pos: data.Position) nyarna.Error!*data.Node,

  pub fn map(self: *Self, pos: data.Position, input: ArgKind,
             flag: ProtoArgFlag) ?Cursor {
    return self.mapFn(self, pos, input, flag);
  }

  pub fn config(self: *Self, at: Cursor) ?*data.BlockConfig {
    return self.configFn(self, at);
  }

  pub fn paramType(self: *Self, at: Cursor) ?data.Type {
    return self.paramTypeFn(self, at);
  }

  pub fn push(self: *Self, alloc: *std.mem.Allocator, at: Cursor,
              content: *data.Node) !void {
    try self.pushFn(self, alloc, at, content);
  }

  pub fn finalize(self: *Self, alloc: *std.mem.Allocator, pos: data.Position)
      nyarna.Error!*data.Node {
    return self.finalizeFn(self, alloc, pos);
  }
};

pub const SignatureMapper = struct {
  mapper: Mapper,
  subject: *data.Expression,
  signature: *const Type.Signature,
  cur_pos: ?u21 = 0,
  args: []*data.Node,
  filled: []bool,
  context: *Interpreter,

  pub fn init(ctx: *Interpreter, subject: *data.Expression,
              sig: *const data.Type.Signature) !SignatureMapper {
    return SignatureMapper{
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
      .args = try ctx.storage.allocator.alloc(*data.Node, sig.parameters.len),
      .filled = try ctx.storage.allocator.alloc(bool, sig.parameters.len),
    };
  }

  /// workaround for https://github.com/ziglang/zig/issues/6059
  inline fn varmapAt(self: *SignatureMapper, index: u21) bool {
    return if (self.signature.varmap) |vm| vm == index else false;
  }

  fn map(mapper: *Mapper, pos: data.Position,
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
        self.context.loader.logger.UnknownParameter(pos);
        return null;
      },
      .primary => {
        self.cur_pos = null;
        if (self.signature.primary) |index| {
          return Mapper.Cursor{
            .param = .{.index = index},
            .config = flag == .block_with_config, .direct = true};
        } else {
          self.context.loader.logger.UnexpectedPrimaryBlock(pos);
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
            self.context.loader.logger.TooManyArguments(pos);
            return null;
          }
        } else {
          self.context.loader.logger.InvalidPositionalArgument(pos);
          return null;
        }
      },
    }
  }

  fn config(mapper: *Mapper, at: Mapper.Cursor) ?*data.BlockConfig {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return switch (at.param) {
      .index => |index|
        if (self.signature.parameters[index].config) |*bc| bc else null,
      .kind => null
    };
  }

  fn paramType(mapper: *Mapper, at: Mapper.Cursor) ?data.Type {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    return switch (at.param) {
      .index => |index| self.signature.parameters[index].ptype,
      .kind => null
    };
  }

  fn push(mapper: *Mapper, _: *std.mem.Allocator, at: Mapper.Cursor,
          content: *data.Node) nyarna.Error!void {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    const param = &self.signature.parameters[at.param.index];
    const target_type =
      if (at.direct) param.ptype
      else if (self.varmapAt(at.param.index)) unreachable
      else switch (param.capture) {
      .varargs => unreachable,
      else => param.ptype,
    };
    const arg = if (target_type.is(.ast_node)) blk: {
      const ast_expr =
        try self.context.storage.allocator.create(data.Expression);
      break :blk try data.Node.valueNode(
        &self.context.storage.allocator, ast_expr, content.pos, .{
          .ast = .{.root = content},
        });
    } else blk: {
      if (try self.context.associate(content, param.ptype)) |expr|
        content.data = .{.expression = expr};
      break :blk content;
    };
    if (self.varmapAt(at.param.index)) unreachable
    else switch (param.capture) {
      .varargs => unreachable,
      else => {}
    }
    if (self.filled[at.param.index])
      self.context.loader.logger.DuplicateParameterArgument(
        self.signature.parameters[at.param.index].name, content.pos,
        self.args[at.param.index].pos)
    else {
      self.args[at.param.index] = arg;
      self.filled[at.param.index] = true;
    }
  }

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position)
      nyarna.Error!*data.Node {
    const self = @fieldParentPtr(SignatureMapper, "mapper", mapper);
    const ret = try alloc.create(data.Node);
    var missing_param = false;
    for (self.signature.parameters) |param, i| {
      if (!self.filled[i]) {
        self.args[i] = switch (param.ptype) {
          .intrinsic => |intr| switch (intr) {
            .void, .ast_node => try data.Node.genVoid(alloc, pos),
            else => null,
          },
          .structural => |strct| switch (strct.*) {
            .optional, .concat, .paragraphs =>
              try data.Node.genVoid(alloc, pos),
            else => null,
          },
          .instantiated => null,
        } orelse {
          self.context.loader.logger.MissingParameterArgument(
            param.name, pos, param.pos);
          missing_param = true;
          continue;
        };
      }
    }
    ret.* = .{
      .pos = pos,
      .data = if (missing_param) .poisonNode else .{
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
    return Mapper.Cursor{
      .param = .{.kind = input}, .config = flag == .block_with_config,
      .direct = input.isDirect()
    };
  }

  fn config(_: *Mapper, _: Mapper.Cursor) ?*data.BlockConfig {
    return null;
  }

  fn paramType(_: *Mapper, _: Mapper.Cursor) ?data.Type {
    return null;
  }

  fn push(mapper: *Mapper, alloc: *std.mem.Allocator, at: Mapper.Cursor,
          content: *data.Node) nyarna.Error!void {
    const self = @fieldParentPtr(CollectingMapper, "mapper", mapper);
    try self.items.append(alloc, .{
        .kind = at.param.kind, .content = content,
        .had_explicit_block_config = at.config
      });
  }

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position)
      nyarna.Error!*data.Node {
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
    return Mapper.Cursor{
      .param = .{.index = 0}, .config = flag == .block_with_config,
      .direct = input == .primary,
    };
  }

  fn push(mapper: *Mapper, _: *std.mem.Allocator, _: Mapper.Cursor,
          content: *data.Node) !void {
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

  fn finalize(mapper: *Mapper, alloc: *std.mem.Allocator, pos: data.Position)
      !*data.Node {
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
