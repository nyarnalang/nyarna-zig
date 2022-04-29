const std = @import("std");

const Interpreter = @import("../interpret.zig").Interpreter;
const nyarna      = @import("../../nyarna.zig");

const model = nyarna.model;
const Type  = model.Type;

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

mapFn: fn(
  self: *Self,
  pos: model.Position,
  input: ArgKind,
  flag: ProtoArgFlag,
) nyarna.Error!?Cursor,
pushFn: fn(self: *Self, at: Cursor, content: *model.Node) nyarna.Error!void,
configFn: fn(self: *Self, at: Cursor) ?*model.BlockConfig,
paramTypeFn: fn(self: *Self, at: Cursor) ?model.Type,
finalizeFn: fn(self: *Self, pos: model.Position) nyarna.Error!*model.Node,

subject_pos: model.Position,

pub fn map(
  self: *Self,
  pos: model.Position,
  input: ArgKind,
  flag: ProtoArgFlag,
) nyarna.Error!?Cursor {
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

pub const ToSignature = struct {
  mapper   : Self,
  subject  : *model.Node,
  signature: *const model.Signature,
  cur_pos  : ?u21 = 0,
  args     : []*model.Node,
  filled   : []bool,
  intpr    : *Interpreter,
  ns       : u15,
  /// used for arguments captured by varmap parameter
  last_key: *model.Node.Literal = undefined,

  pub fn init(
    intpr  : *Interpreter,
    subject: *model.Node,
    ns     : u15,
    sig    : *const model.Signature,
  ) !@This() {
    var res = @This(){
      .mapper = .{
        .mapFn       = @This().map,
        .configFn    = @This().config,
        .paramTypeFn = @This().paramType,
        .pushFn      = @This().push,
        .finalizeFn  = @This().finalize,
        .subject_pos = subject.lastIdPos(),
      },
      .subject   = subject,
      .signature = sig,
      .intpr     = intpr,
      .ns        = ns,
      .filled    = try intpr.allocator.alloc(bool, sig.parameters.len),
      .args      =
        try intpr.allocator.alloc(*model.Node, sig.parameters.len),
    };
    for (res.filled) |*item| item.* = false;
    return res;
  }

  /// workaround for https://github.com/ziglang/zig/issues/6059
  inline fn varmapAt(self: *@This(), index: u21) bool {
    return if (self.signature.varmap) |vm| vm == index else false;
  }

  fn checkFrameRoot(self: *@This(), t: model.Type) !void {
    if (t.isNamed(.frame_root)) {
      const container =
        try self.intpr.ctx.global().create(model.VariableContainer);
      container.* = .{.num_values = 0};
      try self.intpr.var_containers.append(self.intpr.allocator, .{
        .offset = self.intpr.variables.items.len,
        .container = container,
      });
    }
  }

  fn map(
    mapper: *Self,
    pos   : model.Position,
    input : ArgKind,
    flag  : ProtoArgFlag,
  ) nyarna.Error!?Cursor {
    const self = @fieldParentPtr(@This(), "mapper", mapper);

    switch (input) {
      .named, .direct => |name| {
        self.cur_pos = null;
        for (self.signature.parameters) |p, i| {
          const index = @intCast(u21, i);
          if (std.mem.eql(u8, name, p.name)) {
            if (p.capture == .varargs) self.cur_pos = index;
            try self.checkFrameRoot(p.spec.t);
            return Cursor{
              .param = .{.index = index},
              .config = flag == .block_with_config,
              .direct = input == .direct,
            };
          }
        }
        if (self.signature.varmap) |index| {
          self.last_key = try self.intpr.node_gen.literal(
            pos, .{.kind = .text, .content = name});
          return Cursor{
            .param = .{.index = index},
            .config = flag == .block_with_config,
            .direct = input == .direct,
          };
        }
        self.intpr.ctx.logger.UnknownParameter(pos, name);
        return null;
      },
      .primary => {
        self.cur_pos = null;
        if (self.signature.primary) |index| {
          try self.checkFrameRoot(self.signature.parameters[index].spec.t);
          return Cursor{
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
            try self.checkFrameRoot(self.signature.parameters[index].spec.t);
            return Cursor{.param = .{.index = index},
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

  fn config(mapper: *Self, at: Cursor) ?*model.BlockConfig {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    return switch (at.param) {
      .index => |index|
        if (self.signature.parameters[index].config) |*bc| bc else null,
      .kind => null
    };
  }

  fn paramType(mapper: *Self, at: Cursor) ?model.Type {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    return switch (at.param) {
      .index => |index| self.signature.parameters[index].spec.t,
      .kind => null
    };
  }

  fn addToVarargs(
    self  : *@This(),
    index : usize,
    t     : model.Type,
    arg   : *model.Node,
    direct: bool,
  ) !void {
    const vnode = if (self.filled[index]) (
      &self.args[index].data.varargs
    ) else blk: {
      const varargs = try self.intpr.node_gen.varargs(arg.pos, t);
      self.args[index] = varargs.node();
      self.filled[index] = true;
      break :blk varargs;
    };
    try vnode.content.append(
      self.intpr.allocator, .{.direct = direct, .node = arg});
    vnode.node().pos = vnode.node().pos.span(arg.pos);
  }

  fn addToVarmap(
    self  : *@This(),
    index : usize,
    t     : *model.Type.Map,
    arg   : *model.Node,
    direct: bool,
  ) !void {
    const vnode = if (self.filled[index]) (
      &self.args[index].data.varmap
    ) else blk: {
      const varmap = try self.intpr.node_gen.varmap(arg.pos, t);
      self.args[index] = varmap.node();
      self.filled[index] = true;
      break :blk varmap;
    };
    try vnode.content.append(self.intpr.allocator, .{
      .key = if (direct) .direct else .{.implicit = self.last_key},
      .value = arg,
    });
    vnode.node().pos = vnode.node().pos.span(arg.pos);
  }

  const ArgBehavior = enum {
    normal, ast_node, frame_root,

    fn calc(t: model.Type) ArgBehavior {
      return switch (t) {
        .structural => |strct| switch (strct.*) {
          .optional => |*opt| calc(opt.inner),
          else => .normal,
        },
        .named => |named| switch (named.data) {
          .ast => ArgBehavior.ast_node,
          .frame_root => .frame_root,
          else => .normal,
        },
      };
    }
  };

  fn push(
    mapper : *Self,
    at     : Cursor,
    content: *model.Node,
  ) nyarna.Error!void {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    const param = &self.signature.parameters[at.param.index];
    const target_spec =
      if (at.direct) param.spec
      else if (self.varmapAt(at.param.index)) model.SpecType{
        .t = param.spec.t.structural.map.value, .pos = param.spec.pos,
      } else switch (param.capture) {
      .varargs => model.SpecType{
        .t = param.spec.t.structural.list.inner, .pos = param.spec.pos,
      },
      else => param.spec,
    };
    const behavior = ArgBehavior.calc(target_spec.t);
    const arg = if (behavior == .ast_node or behavior == .frame_root) blk: {
      if (at.direct or param.capture != .varargs) {
        const container = if (behavior == .frame_root)
          self.intpr.var_containers.pop().container else null;
        break :blk try self.intpr.genValueNode(
          (try self.intpr.ctx.values.ast(content, container)).value());
      } else break :blk content;
    } else blk: {
      if (try self.intpr.associate(
          content, target_spec, .{.kind = .intermediate})) |expr| {
        content.data = .{.expression = expr};
      }
      break :blk content;
    };
    if (self.varmapAt(at.param.index)) {
      try self.addToVarmap(
        at.param.index, &param.spec.t.structural.map, arg, at.direct);
      return;
    } else switch (param.capture) {
      .varargs => {
        try self.addToVarargs(at.param.index, param.spec.t, arg, at.direct);
        return;
      },
      else => {}
    }
    if (self.filled[at.param.index]) {
      self.intpr.ctx.logger.DuplicateParameterArgument(
        self.signature.parameters[at.param.index].name, content.pos,
        self.args[at.param.index].pos);
    } else {
      self.args[at.param.index] = arg;
      self.filled[at.param.index] = true;
    }
  }

  fn finalize(mapper: *Self, pos: model.Position) nyarna.Error!*model.Node {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    var missing_param = false;
    for (self.signature.parameters) |param, i| {
      if (!self.filled[i]) {
        self.args[i] = if (param.default) |dexpr|
          try self.intpr.node_gen.expression(dexpr)
        else switch (param.spec.t) {
          .structural => |strct| switch (strct.*) {
            .optional, .concat, .sequence =>
              try self.intpr.node_gen.@"void"(pos),
            .list => if (param.capture == .varargs) (
              try self.intpr.node_gen.varargs(pos, param.spec.t)
            ).node() else null,
            .map => if (self.signature.varmap) |vi| if (vi == i) (
              try self.intpr.node_gen.varmap(
                pos, &param.spec.t.structural.map)
            ).node() else null else null,
            else => null,
          },
          .named => |named| switch (named.data) {
            .void => try self.intpr.node_gen.@"void"(pos),
            .poison => {
              missing_param = true;
              continue;
            },
            .frame_root => blk: {
              const container = try
                self.intpr.ctx.global().create(model.VariableContainer);
              container.* = .{.num_values = 0};
              break :blk try self.intpr.genValueNode(
                (try self.intpr.ctx.values.ast(
                  try self.intpr.node_gen.@"void"(pos), container)).value());
            },
            else => null,
          },
        } orelse {
          self.intpr.ctx.logger.MissingParameterArgument(
            param.name, pos, param.pos);
          missing_param = true;
          continue;
        };
      }
      if (param.capture == .varargs) switch (param.spec.t) {
        .structural => |strct| switch (strct.*) {
          .list => |*list| if (list.inner.isNamed(.ast)) {
            const content = self.args[i];
            self.args[i] = try self.intpr.genValueNode(
              (try self.intpr.ctx.values.ast(content, null)).value());
          },
          else => {},
        },
        else => {},
      };
    }
    return if (missing_param) try self.intpr.node_gen.poison(pos) else
      (try self.intpr.node_gen.rcall(pos, .{
        .ns = self.ns,
        .target = self.subject,
        .args = self.args,
        .sig = self.signature,
      })).node();
  }
};

pub const Collect = struct {
  mapper     : Self,
  target     : *model.Node,
  items      : std.ArrayListUnmanaged(model.Node.UnresolvedCall.ProtoArg) = .{},
  first_block: ?usize = null,
  intpr      : *Interpreter,

  pub fn init(
    target: *model.Node,
    intpr : *Interpreter,
  ) @This() {
    return .{
      .mapper = .{
        .mapFn       = @This().map,
        .configFn    = @This().config,
        .paramTypeFn = @This().paramType,
        .pushFn      = @This().push,
        .finalizeFn  = @This().finalize,
        .subject_pos = target.lastIdPos(),
      },
      .target = target,
      .intpr = intpr,
    };
  }

  fn map(
    mapper: *Self,
    _     : model.Position,
    input : ArgKind,
    flag  : ProtoArgFlag,
  ) nyarna.Error!?Cursor {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    if (flag != .flow and self.first_block == null) {
      self.first_block = self.items.items.len;
    }
    return Cursor{
      .param = .{.kind = input}, .config = flag == .block_with_config,
      .direct = input.isDirect()
    };
  }

  fn config(_: *Self, _: Cursor) ?*model.BlockConfig {
    return null;
  }

  fn paramType(_: *Self, _: Cursor) ?model.Type {
    return null;
  }

  fn push(mapper : *Self, at: Cursor, content: *model.Node) nyarna.Error!void {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    try self.items.append(self.intpr.allocator, .{
        .kind = at.param.kind, .content = content,
        .had_explicit_block_config = at.config
      });
  }

  fn finalize(mapper: *Self, pos: model.Position) nyarna.Error!*model.Node {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    return (try self.intpr.node_gen.uCall(pos, .{
      .target = self.target,
      .proto_args = self.items.items,
      .first_block_arg = self.first_block orelse self.items.items.len,
    })).node();
  }
};

pub const ToAssignment = struct {
  mapper     : Self,
  subject    : *model.Node,
  replacement: ?*model.Node,
  intpr      : *Interpreter,

  pub fn init(subject: *model.Node, intpr: *Interpreter) ToAssignment {
    return .{
      .mapper = .{
        .mapFn       = @This().map,
        .configFn    = @This().config,
        .paramTypeFn = @This().paramType,
        .pushFn      = @This().push,
        .finalizeFn  = @This().finalize,
        .subject_pos = subject.lastIdPos(),
      },
      .subject     = subject,
      .replacement = null,
      .intpr       = intpr,
    };
  }

  pub fn map(
    mapper: *Self,
    pos   : model.Position,
    input : ArgKind,
    flag  : ProtoArgFlag,
  ) nyarna.Error!?Cursor {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    if (input == .named or input == .direct) {
      self.intpr.ctx.logger.InvalidNamedArgInAssign(pos);
      return null;
    } else if (self.replacement != null) {
      self.intpr.ctx.logger.TooManyArguments(pos);
      return null;
    }
    return Cursor{
      .param  = .{.index = 0},
      .config = flag == .block_with_config,
      .direct = input == .primary,
    };
  }

  fn push(mapper: *Self, _: Cursor, content: *model.Node) !void {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    self.replacement = content;
  }

  fn config(_: *Self, _: Cursor) ?*model.BlockConfig {
    // TODO: block config on variable definition
    return null;
  }

  fn paramType(_: *Self, _: Cursor) ?model.Type {
    // TODO: param type of subject
    return null;
  }

  fn finalize(mapper: *Self, pos: model.Position) !*model.Node {
    const self = @fieldParentPtr(@This(), "mapper", mapper);
    return (try self.intpr.node_gen.assign(pos, .{
      .target = .{.unresolved = self.subject},
      .replacement = self.replacement orelse (
        try self.intpr.node_gen.@"void"(pos)
      ),
    })).node();
  }
};