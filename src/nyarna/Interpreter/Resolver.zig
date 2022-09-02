//! The Resolver resolves names in Nodes to symbols or fields.
//! It handles both direct symbol references (e.g. `\someName`) and access
//! names (e.g. `\someExpr()::someName`).

const std = @import("std");

const graph     = @import("graph.zig");
const nyarna    = @import("../../nyarna.zig");

const errors      = nyarna.errors;
const Interpreter = nyarna.Interpreter;
const lib         = nyarna.lib;
const model       = nyarna.model;

const last = @import("../helpers.zig").last;

/// A Context provides resolution for names that are not established symbols.
/// The main use-case for this are references to other symbols in a declare
/// command, as they need to be resolved before they are established as symbols.
/// In that use-case, the Context also registers dependencies between symbols.
///
/// Other use-cases are the resolution of compile-time variables e.g. in macros
/// and unroll commands.
pub const Context = struct {
  pub const Result = union(enum) {
    /// The name resolves to an unfinished function. The returned type may be
    /// used to calculate the type of calls to this function.
    unfinished_function: model.Type,
    /// The name resolves to an unfinished variable. The returned type may be
    /// used to calculate retrievals on this variable.
    unfinished_variable: model.Type,
    /// The name has been resolved to a type which has not yet been finalized.
    /// The returned type may be used as inner type to construct another type,
    /// but must not be used for anything else since it is unfinished.
    unfinished_type: model.Type,
    /// The name has been resolved to the given variable.
    variable: *model.Symbol.Variable,
    /// The name resolves to a comptime parameter, given as node.
    node: *model.Node,
    /// The symbol's name can be resolved to a sibling symbol but no type
    /// information is currently available. The value is the index of the
    /// target sibling node. It is used when building up a dependency graph
    /// between items in a \declare command, it creates a dependency edge
    /// between the current node and the node at the given index.
    known: u21,
    /// return this if the name cannot be resolved but may be later. This is
    /// used when discovering cross-function references because there may be
    /// variables yet unresolved that should not lead to an error.
    unknown,
    /// The referenced symbol is unknown altogether and the caller must assume
    /// this reference cannot be resolved in future steps. Returning .failed
    /// implies that an appropriate error has been logged.
    failed,
  };
  pub const StrippedResult = union(enum) {
    unfinished_function: model.Type,
    unfinished_variable: model.Type,
    unfinished_type    : model.Type,
    variable           : *model.Symbol.Variable,
    node               : *model.Node,
    /// subject *may* be resolvable in the future but currently isn't.
    unknown,
    /// subject is guaranteed to be poison and an error message has been logged.
    poison,
  };
  pub const AccessData = struct {
    result: StrippedResult,
    is_prefix: bool,
  };

  pub const Target = union(enum) {
    ns: u15,
    t : model.Type,
  };

  /// try to resolve an unresolved name in the current context.
  /// this function is called when the name originates in a symref in the
  /// correct namespace (if context is namespace-based) or in an access on the
  /// correct type or an expression of the correct type
  /// (if context is type-based).
  resolveNameFn: fn(
    ctx     : *Context,
    name    : []const u8,
    name_pos: model.Position,
  ) nyarna.Error!Result,

  /// registers all links to sibling nodes that are encountered.
  /// will be set during graph processing and is not to be set by the caller.
  dependencies: std.ArrayListUnmanaged(usize) = undefined,
  /// the target in whose namespace all symbols declared via this context
  /// reside. either a command character namespace or a type.
  target: Target,
  /// used if multiple context are active. Resolution is delegated to upper
  /// context if this one is not able to resolve.
  parent: ?*Context = null,

  fn strip(
    ctx  : *Context,
    local: std.mem.Allocator,
    res  : Result
  ) !StrippedResult {
    return switch (res) {
      .unfinished_function => |t| StrippedResult{.unfinished_function = t},
      .unfinished_variable => |t| StrippedResult{.unfinished_variable = t},
      .unfinished_type     => |t| StrippedResult{.unfinished_type = t},
      .variable            => |v| StrippedResult{.variable = v},
      .node                => |n| StrippedResult{.node = n},
      .known               => |index| {
        for (ctx.dependencies.items) |item| {
          if (item == index) return StrippedResult.unknown;
        }
        try ctx.dependencies.append(local, index);
        return StrippedResult.unknown;
      },
      .unknown => StrippedResult.unknown,
      .failed => StrippedResult.poison,
    };
  }

  /// manually establish a link to the symbol of the given name. used for some
  /// system.ny bootstrapping.
  pub fn establishLink(
    ctx  : *Context,
    intpr: *Interpreter,
    name : []const u8,
  ) !StrippedResult {
    const res = try ctx.resolveNameFn(ctx, name, model.Position.intrinsic());
    return try ctx.strip(intpr.allocator(), res);
  }

  /// try to resolve an unresolved symbol reference in the context.
  pub fn resolveSymbol(
    ctx  : *Context,
    intpr: *Interpreter,
    item : *model.Node.UnresolvedSymref,
  ) nyarna.Error!StrippedResult {
    switch (ctx.target) {
      .ns => |ns| if (ns == item.ns) {
        const res = try ctx.resolveNameFn(ctx, item.name, item.node().pos);
        if (res == .unknown) if (ctx.parent) |p| {
          return try p.resolveSymbol(intpr, item);
        };
        return try ctx.strip(intpr.allocator(), res);
      },
      .t => {},
    }
    return StrippedResult.unknown;
  }

  /// try to resolve an unresolved access node in the context.
  pub fn resolveAccess(
    ctx    : *Context,
    intpr  : *Interpreter,
    subject: *model.Node,
    name   : *model.Node.Literal,
    stage  : Interpreter.Stage,
  ) !AccessData {
    switch (ctx.target) {
      .ns => {},
      .t => |t| {
        switch (subject.data) {
          .resolved_symref => |*rsym| switch (rsym.sym.data) {
            .@"type" => |st| if (t.eql(st)) return AccessData{
              .result = try ctx.strip(intpr.allocator(),
                try ctx.resolveNameFn(ctx, name.content, name.node().pos)),
              .is_prefix = false,
            },
            else => {},
          },
          else => {},
        }
        const pt = (try intpr.probeType(subject, stage, false)) orelse {
          // typically means that we hit a variable in a function body. If so,
          // we just assume that this variable has the \declare type.
          // This means we'll resolve the name of this access in our defs to
          // discover dependencies.
          // This will overreach but we accept that for now.
          // we ignore the result and return .unknown to avoid linking to a
          // possibly wrong function.
          _ = try ctx.strip(intpr.allocator(),
            try ctx.resolveNameFn(ctx, name.content, name.node().pos));
          return AccessData{.result = .unknown, .is_prefix = true};
        };
        if (t.eql(pt)) return AccessData{
          .result = try ctx.strip(intpr.allocator(),
            try ctx.resolveNameFn(ctx, name.content, name.node().pos)),
          .is_prefix = true,
        };
      }
    }
    return AccessData{.result = .unknown, .is_prefix = false};
  }
};

/// A Context that can resolve comptime variables (during unroll or in macros).
pub const ComptimeContext = struct {
  ctx: Context,
  entries: std.StringHashMap(*model.Node),

  pub fn init(ns: u15, allocator: std.mem.Allocator) ComptimeContext {
    return .{
      .entries = std.StringHashMap(*model.Node).init(allocator),
      .ctx = .{
        .resolveNameFn = resolveName,
        .target        = .{.ns = ns},
      },
    };
  }

  fn resolveName(
    ctx     : *Context,
    name    : []const u8,
    name_pos: model.Position,
  ) nyarna.Error!Context.Result {
    _ = name_pos;
    const self = @fieldParentPtr(ComptimeContext, "ctx", ctx);
    if (self.entries.get(name)) |node| {
      return Context.Result{.node = node};
    }
    return Context.Result.unknown;
  }
};

/// Result of resolving an accessor chain.
pub const Chain = union(enum) {
  /// chain descends into a runtime value. The base will be either a variable
  /// or an arbitrary expression.
  runtime: struct {
    base: *model.Node,
    /// command character used for the base
    ns: u15,
    /// list of items to descend into at runtime.
    indexes: std.ArrayListUnmanaged(model.Node.Assign.PathItem) = .{},
    /// the current type of the accessed value.
    t: model.Type,
    /// position of the last resolved name in the chain.
    last_name_pos: model.Position,
    /// if true, base is unresolved and chain has been calculated on its
    /// currently known return type (possibly as part of a fixpoint iteration).
    preliminary: bool,
  },
  /// last chain item was resolved to a symbol.
  sym_ref: struct {
    ns: u15,
    sym: *model.Symbol,
    name_pos: model.Position,
    /// set if target symbol is declare in the namespace of a type and has
    /// been accessed via an expression of that type. Such a reference must
    /// directly be called.
    prefix: ?*model.Node = null,
    /// set if the symref has been resolved on a preliminary type, for example
    /// due to fixpoint iteration.
    preliminary: bool,
  },
  /// last chain item was resolved to a function that is not yet fully known.
  /// however what is known is its (possibly preliminary) return type with
  /// which we can continue discovering types, if it is called.
  function_returning: struct {
    /// command character used for the base
    ns: u15,
    returns: model.Type,
  },
  /// the resolution failed because an identifier in the chain could not be
  /// resolved – this is not necessarily an error since the chain may be
  /// successfully resolved later. The value is the namespace.
  failed: u15,
  /// this will be set if the chain is guaranteed to be faulty.
  poison,

  fn symRef(
    ns         : u15,
    sym        : *model.Symbol,
    prefix     : ?*model.Node,
    name_pos   : model.Position,
    preliminary: bool,
  ) Chain {
    return .{.sym_ref = .{
      .ns = ns, .sym = sym, .prefix = prefix, .name_pos = name_pos,
      .preliminary = preliminary,
    }};
  }

  fn runtime(
    ns           : u15,
    base         : *model.Node,
    indexes      : std.ArrayListUnmanaged(model.Node.Assign.PathItem),
    t            : model.Type,
    last_name_pos: model.Position,
    preliminary  : bool,
  ) Chain {
    return .{.runtime = .{
      .ns = ns, .base = base, .indexes = indexes, .t = t,
      .last_name_pos = last_name_pos, .preliminary = preliminary,
    }};
  }

  fn functionReturning(t: model.Type, ns: u15) Chain {
    return .{.function_returning = .{.returns = t, .ns = ns}};
  }
};

/// Represents a chain that can be called.
pub const CallContext = union(enum) {
  known: struct {
    target   : *model.Node,
    ns       : u15,
    signature: *const model.Signature,
    first_arg: ?*model.Node,
  },
  unknown, poison,

  fn chainIntoCallCtx(
    intpr : *Interpreter,
    target: *model.Node,
    t     : model.Type,
    ns    : u15,
  ) !CallContext {
    const callable = switch (t) {
      .structural => |strct| switch (strct.*) {
        .callable => |*callable| callable,
        else => null,
      },
      .named => |named| switch (named.data) {
        .poison => return CallContext.poison,
        else => null,
      },
    } orelse {
      intpr.ctx.logger.CantBeCalled(target.pos);
      return CallContext.poison;
    };
    return CallContext{.known = .{
      .target = target,
      .ns = ns,
      .signature = callable.sig,
      .first_arg = null,
    }};
  }

  pub fn fromChain(
    intpr: *Interpreter,
    node : *model.Node,
    res  : Chain,
  ) !CallContext {
    switch (res) {
      .runtime => |rc| {
        if (rc.preliminary) return .unknown;
        const subject = if (rc.indexes.items.len == 0) rc.base
        else (try intpr.node_gen.raccess(
          node.pos, rc.base, rc.indexes.items, rc.last_name_pos, rc.ns)).node();
        return try chainIntoCallCtx(intpr, subject, rc.t, rc.ns);
      },
      .sym_ref => |*sr| {
        // node is not a resolved_symref if we are calling via prefix. In that
        // case, we need to create a proper symref node that we are calling.
        const target = if (node.data == .resolved_symref) node
        else (try intpr.node_gen.rsymref(node.pos, .{
          .ns = sr.ns, .sym = sr.sym, .name_pos = sr.name_pos,
        })).node();
        switch (sr.sym.data) {
          .func => |func| {
            return CallContext{.known = .{
              .target = target,
              .ns = sr.ns,
              .signature = func.sig(),
              .first_arg = sr.prefix,
            }};
          },
          .@"type" => |t| {
            switch (try intpr.ctx.types().typeType(t)) {
              .structural => |strct| switch (strct.*) {
                .callable => |*callable| {
                  return CallContext{.known = .{
                    .target = target,
                    .ns = undefined,
                    .signature = callable.sig,
                    .first_arg = null,
                  }};
                },
                else => {},
              },
              .named => |named| switch (named.data) {
                .poison => return .poison,
                else => {},
              }
            }
            intpr.ctx.logger.CantBeCalled(node.pos);
            return CallContext.poison;
          },
          .prototype => |pt| {
            return CallContext{.known = .{
              .target = node,
              .ns = undefined,
              .signature = if (
                intpr.ctx.types().prototypeConstructor(pt).callable
              ) |c| c.sig else {
                intpr.ctx.logger.ConstructorUnavailable(node.pos);
                return .poison;
              },
              .first_arg = null,
            }};
          },
          .poison, .variable => unreachable,
        }
      },
      .function_returning, .failed => return .unknown,
      .poison => return .poison,
    }
  }
};

/// result of trying to resolve an access item
const AccessResult = union(enum) {
  field: struct {
    access: struct {
      t    : *model.Type.Record,
      index: usize,
    },
    t: model.Type,
  },
  symbol: *model.Symbol,
};

const Resolver = @This();

intpr: *Interpreter,
stage: Interpreter.Stage,

pub fn init(intpr: *Interpreter, stage: Interpreter.Stage) Resolver {
  return .{.intpr = intpr, .stage = stage};
}

fn searchAccessible(
  intpr: *Interpreter,
  t    : model.Type,
  name : []const u8
) nyarna.Error!?AccessResult {
  switch (t) {
    .named => |named| switch (named.data) {
      .record => |*rec| {
        for (
          rec.constructor.sig.parameters[rec.first_own..]
        ) |field, index| {
          if (std.mem.eql(u8, field.name, name)) {
            return AccessResult{
              .field = .{
                .access = .{.t = rec, .index = index},
                .t = field.spec.t,
              },
            };
          }
        }
      },
      else => {},
    },
    else => {},
  }
  if (intpr.type_namespaces.get(t)) |ns| {
    if (ns.data.get(name)) |sym| return AccessResult{.symbol = sym};
  }
  if (try intpr.ctx.types().instanceFuncsOf(t)) |funcs| {
    if (try funcs.find(intpr.ctx, name)) |sym| {
      return AccessResult{.symbol = sym};
    }
  }
  switch (t) {
    .named => |named| switch (named.data) {
      .record => |*rec| {
        for (rec.embeds) |embed| {
          if (try searchAccessible(intpr, embed.t.typedef(), name)) |res| {
            return res;
          }
        }
      },
      else => {},
    },
    else => {},
  }
  return null;
}

fn resolveSymref(self: Resolver, rs: *model.Node.ResolvedSymref) Chain {
  switch (rs.sym.data) {
    .poison   => return Chain.poison,
    .variable => |*v| {
      if (v.spec.t.isNamed(.every)) {
        std.debug.assert(self.stage.kind == .intermediate);
        return Chain{.failed = rs.ns};
      } else {
        return Chain.runtime(
          rs.ns, rs.node(), .{}, v.spec.t, rs.name_pos, false);
      }
    },
    else => {},
  }
  return Chain.symRef(rs.ns, rs.sym, null, rs.name_pos, false);
}

fn fromResult(
  self    : Resolver,
  node    : *model.Node,
  ns      : u15,
  name    : []const u8,
  name_pos: model.Position,
  res     : Context.StrippedResult,
  stage   : Interpreter.Stage,
) nyarna.Error!Chain {
  switch (res) {
    .node     => |n| {
      node.data = n.data;
      return try self.resolveChain(node);
    },
    .variable => |v| {
      node.data = .{.resolved_symref = .{
        .sym = v.sym(),
        .ns = ns,
        .name_pos = name_pos,
      }};
      std.debug.assert(!v.spec.t.isNamed(.every));
      return Chain.runtime(ns, node, .{}, v.spec.t, name_pos, false);
    },
    .poison  => {
      node.data = .poison;
      return Chain.poison;
    },
    .unknown => switch (stage.kind) {
      .keyword => {
        self.intpr.ctx.logger.CannotResolveImmediately(node.pos);
        return Chain.poison;
      },
      .final => {
        self.intpr.ctx.logger.UnknownSymbol(node.pos, name);
        node.data = .poison;
        return Chain.poison;
      },
      .assumed => unreachable,
      else => return Chain{.failed = ns},
    },
    .unfinished_function => |t| return Chain.functionReturning(t, ns),
    .unfinished_variable => |t|
      return Chain.runtime(ns, node, .{}, t, name_pos, true),
    else => return Chain{.failed = ns},
  }
}

fn resolveUAccess(
  self: Resolver,
  uacc: *model.Node.UnresolvedAccess,
) nyarna.Error!Chain {
  const name_lit: ?*model.Node.Literal = switch (uacc.name.data) {
    .literal => |*lit| lit,
    .poison  => null,
    else     => if (
      try self.intpr.associate(
        uacc.name, self.intpr.ctx.types().text().predef(), self.stage)
    ) |expr| blk: {
      const value = try self.intpr.ctx.evaluator().evaluate(expr);
      switch (value.data) {
        .text   => |*txt| {
          uacc.name.data = .{.literal = .{
            .kind    = .text,
            .content = txt.content,
          }};
          break :blk &uacc.name.data.literal;
        },
        .poison => {
          uacc.name.data = .poison;
          break :blk null;
        },
        else => unreachable,
      }
    } else null
  };

  var res = try self.resolveChain(uacc.subject);
  const ns = switch (res) {
    // access on an unknown function. can't be resolved.
    .function_returning => |*fr| fr.ns,
    .runtime => |*rc| blk: {
      const type_val = switch (rc.base.data) {
        .expression => |expr| switch (expr.data) {
          .value => |val| switch (val.data) {
            .@"type" => |tv| if (rc.indexes.items.len == 0) tv else null,
            else => null,
          },
          else => null,
        },
        else => null,
      };

      if (
        if (name_lit) |name| (
          try searchAccessible(
            self.intpr, if (type_val) |tv| tv.t else rc.t, name.content)
        ) else @as(?AccessResult, null)
      ) |sr| switch (sr) {
        .field => |field| {
          if (type_val != null) {
            self.intpr.ctx.logger.FieldAccessWithoutInstance(uacc.node().pos);
            return .poison;
          } else {
            try rc.indexes.append(
              self.intpr.allocator(), .{.field = .{
                .t     = field.access.t,
                .index = field.access.index,
              }});
            rc.t = field.t;
            return res;
          }
        },
        .symbol => |sym| {
          if (sym.data == .poison) return Chain.poison;
          if (type_val != null) {
            return Chain.symRef(
              rc.ns, sym, null, rc.last_name_pos, false);
          }
          const subject = if (rc.indexes.items.len == 0) rc.base
            else (try self.intpr.node_gen.raccess(
              uacc.node().pos, rc.base, rc.indexes.items, rc.last_name_pos,
              rc.ns)).node();
          return Chain.symRef(
            rc.ns, sym, subject, uacc.name.pos, rc.preliminary);
        },
      };
      break :blk rc.ns;
    },
    .sym_ref => |ref| blk: {
      if (!ref.preliminary and ref.prefix != null) {
        self.intpr.ctx.logger.PrefixedSymbolMustBeCalled(uacc.subject.pos);
        return Chain.poison;
      }
      switch (ref.sym.data) {
        .func => |func| {
          const target = (
            if (name_lit) |name| (
              try searchAccessible(
                self.intpr, func.callable.typedef(), name.content)
            ) else @as(?AccessResult, null)
          ) orelse break :blk ref.ns;
          switch (target) {
            .field => unreachable, // OPPORTUNITY: do functions have fields?
            .symbol => |sym| {
              if (sym.data == .poison) return .poison;
              return Chain.symRef(
                ref.ns, sym, uacc.subject, uacc.name.pos, ref.preliminary);
            },
          }
        },
        .@"type" => |t| {
          const target = (
            if (name_lit) |name| (
              try searchAccessible(self.intpr, t, name.content)
            ) else @as(?AccessResult, null)
          ) orelse break :blk ref.ns;
          switch (target) {
            .field => {
              self.intpr.ctx.logger.FieldAccessWithoutInstance(
                uacc.node().pos);
              return .poison;
            },
            .symbol => |sym| {
              if (sym.data == .poison) return .poison;
              return Chain.symRef(
                ref.ns, sym, null, ref.name_pos, ref.preliminary);
            },
          }
        },
        .variable, .poison, .prototype => unreachable,
      }
    },
    .failed => |ns| ns,
    .poison => return res,
  };

  // during resolution there may still be unresolved accesses to the
  // current type's namespace, so we don't poison in that case yet.
  if (self.stage.kind != .intermediate or uacc.name.data == .poison) {
    if (name_lit) |name| {
      self.intpr.ctx.logger.UnknownSymbol(uacc.name.pos, name.content);
      const node = uacc.node();
      node.data = .poison;
    }
    return Chain.poison;
  } else if (self.stage.resolve_ctx) |ctx| {
    if (name_lit) |name| {
      const ares = try ctx.resolveAccess(
        self.intpr, uacc.subject, name, self.stage);
      return try self.fromResult(
        uacc.node(), ns, name.content, uacc.name.pos, ares.result, self.stage);
    }
  }
  return Chain{.failed = ns};
}

pub fn trySubscript(
  self: Resolver,
  base: *Chain,
  args: []model.Node.UnresolvedCall.ProtoArg,
  end : model.Position,
) nyarna.Error!?Chain {
  switch (base.*) {
    .runtime => |*rc| {
      if (
        switch (rc.t) {
          .structural => |strct| switch (strct.*) {
            .concat => |*con| blk: {
              rc.t = con.inner;
              break :blk @as(usize, 1);
            },
            .list => |*lst| blk: {
              rc.t = lst.inner;
              break :blk @as(usize, 1);
            },
            .sequence => |*seq| blk: {
              rc.t = try self.intpr.ctx.types().seqInnerType(seq);
              break :blk @as(usize, 1);
            },
            else => null,
          },
          else => null,
        }
      ) |expected_subscript| {
        if (args.len < expected_subscript) {
          self.intpr.ctx.logger.MissingSubscript(
            if (args.len > 0) last(args).content.pos else end);
        } else for (args[expected_subscript..]) |arg| {
          if (arg.kind != .position) {
            self.intpr.ctx.logger.NonPositionalSubscript(arg.content.pos);
          } else {
            self.intpr.ctx.logger.SuperfluousSubscript(arg.content.pos);
          }
        }
        // if nyarna adds matrixes some time, this needs to be rewritten.
        std.debug.assert(expected_subscript == 1);
        if (args[0].kind != .position) {
          self.intpr.ctx.logger.NonPositionalSubscript(args[0].content.pos);
        }
        try rc.indexes.append(self.intpr.allocator(),
          .{.subscript = args[0].content});
        return base.*;
      }
    },
    else => {},
  }
  return null;
}

fn resolveUCall(
  self : Resolver,
  ucall: *model.Node.UnresolvedCall,
) nyarna.Error!Chain {
  var res = try self.resolveChain(ucall.target);
  if (
    try self.trySubscript(&res, ucall.proto_args, ucall.node().pos)
  ) |subscr| {
    return subscr;
  }
  switch (res) {
    .function_returning => |*fr| {
      return Chain.runtime(fr.ns, ucall.target, .{}, fr.returns,
        ucall.node().pos.after(), true);
    },
    .runtime => |*rc| {
      if (rc.preliminary) {
        switch (rc.t) {
          .structural => |strct| switch (strct.*) {
            .callable => |*callable| {
              return Chain.runtime(
                rc.ns, ucall.node(), .{}, callable.sig.returns,
                ucall.node().pos.after(), true
              );
            },
            else => {},
          },
          else => {},
        }
        return Chain{.failed = rc.ns}; // TODO: or poison (?)
      } else {
        const expr = (
          try self.intpr.interpretCallToChain(ucall, res, self.stage)
        ) orelse return Chain{.failed = rc.ns};
        const node = ucall.node();
        node.data = .{.expression = expr};
        return Chain.runtime(
          undefined, node, .{}, expr.expected_type, rc.last_name_pos, false);
      }
    },
    .sym_ref => |*sr| {
      if (sr.preliminary) {
        switch (sr.sym.data) {
          .func => |f|
            return Chain.runtime(sr.ns, ucall.node(), .{},
              f.callable.sig.returns, sr.name_pos, true),
          .variable => |*v| {
            switch (v.spec.t) {
              .structural => |strct| switch (strct.*) {
                .callable => |*callable| return Chain.runtime(sr.ns,
                  ucall.node(), .{}, callable.sig.returns, sr.name_pos, true),
                else => {},
              },
              else => {},
            }
            return Chain{.failed = sr.ns};
          },
          .@"type" => |t| return Chain.runtime(
            sr.ns, ucall.node(), .{}, t, sr.name_pos, true),
          // since prototypes cannot be assigned to variables or returned
          // from functions, delayed resolution can never result in a
          // prototype.
          .prototype => unreachable,
          .poison => return Chain.poison,
        }
      } else {
        const expr = (
          try self.intpr.interpretCallToChain(ucall, res, self.stage)
        ) orelse return Chain{.failed = sr.ns};
        const node = ucall.node();
        node.data = .{.expression = expr};
        return Chain.runtime(
          undefined, node, .{}, expr.expected_type, sr.name_pos, false);
      }
    },
    .failed, .poison => return res,
  }
}

/// resolves an accessor chain of *model.Node. if stage.kind != .intermediate,
/// failure to resolve the base symbol will be reported as error and
/// .poison will be returned; else .failed will be returned.
pub fn resolveChain(
  self : Resolver,
  chain: *model.Node,
) nyarna.Error!Chain {
  var ns: u15 = undefined;
  const last_name_pos = switch (chain.data) {
    .resolved_symref   => |*rs| return self.resolveSymref(rs),
    .unresolved_access => |*uacc| return try self.resolveUAccess(uacc),
    .unresolved_call   => |*ucall| return try self.resolveUCall(ucall),
    .unresolved_symref => |*usym| {
      const namespace = self.intpr.namespace(usym.ns);
      const name_pos = usym.namePos();
      if (namespace.data.get(usym.name)) |sym| {
        chain.data = .{.resolved_symref = .{
          .ns = usym.ns, .sym = sym, .name_pos = name_pos,
        }};
        return self.resolveSymref(&chain.data.resolved_symref);
      } else if (self.stage.resolve_ctx) |ctx| {
        return try self.fromResult(chain, usym.ns, usym.name, name_pos,
          try ctx.resolveSymbol(self.intpr, usym), self.stage);
      } else switch (self.stage.kind) {
        .keyword => {
          self.intpr.ctx.logger.CannotResolveImmediately(chain.pos);
          return Chain.poison;
        },
        .final => {
          self.intpr.ctx.logger.UnknownSymbol(chain.pos, usym.name);
          chain.data = .poison;
          return Chain.poison;
        },
        .assumed => unreachable,
        else => return Chain{.failed = usym.ns},
      }
    },
    .resolved_access => |*racc| blk: {
      ns = racc.ns;
      break :blk racc.last_name_pos;
    },
    else => chain.pos.after(),
  };

  if (try self.intpr.tryInterpret(chain, self.stage)) |expr| {
    chain.data = .{.expression = expr};
    return Chain.runtime(
      undefined, chain, .{}, expr.expected_type, last_name_pos, false);
  } else return switch (self.stage.kind) {
    .intermediate => Chain{.failed = ns},
    else => Chain.poison,
  };
}

/// try to resolve all unresolved names in the given node.
pub fn resolve(
  self: *Resolver,
  node: *model.Node,
) nyarna.Error!void {
  switch (node.data) {
    .assign            => |ass| {
      switch (ass.target) {
        .unresolved => |ures| try self.resolve(ures),
        .resolved   => {},
      }
      try self.resolve(ass.replacement);
    },
    .backend  => |ba| {
      if  (ba.vars)  |vnode| try self.resolve(vnode);
      for (ba.funcs) |def|   try self.resolve(def.content);
      if  (ba.body)  |bval|  try self.resolve(bval.root);
    },
    .@"if" => |ifn| {
      try self.resolve(ifn.condition);
      try self.resolve(ifn.then.root);
      if (ifn.@"else") |en| try self.resolve(en);
    },
    .concat     => |con| for (con.items) |item| try self.resolve(item),
    .builtingen => |bgen| {
      switch (bgen.params) {
        .unresolved => |unode| try self.resolve(unode),
        .resolved   => |res| for (res.locations) |lref| switch (lref) {
          .node => |lnode| try self.resolve(lnode.node()),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      switch (bgen.returns) {
        .node => |rnode| try self.resolve(rnode),
        .expr => {},
      }
    },
    .capture    => |cap| try self.resolve(cap.content),
    .definition => |def| try self.resolve(def.content),
    .@"for"     => |f| {
      try self.resolve(f.input);
      if (f.collector) |cnode| try self.resolve(cnode);
      try self.resolve(f.body);
    },
    .expression => |expr| switch (expr.data) {
      .value => |value| switch (value.data) {
        .ast => |ast| try self.resolve(ast.root),
        else => {},
      },
      else => {},
    },
    .funcgen => |fgen| {
      switch (fgen.params) {
        .unresolved => |pnode| try self.resolve(pnode),
        .resolved   => |res| for (res.locations) |lref| switch (lref) {
          .node => |lnode| try self.resolve(lnode.node()),
          .expr, .value, .poison => {},
        },
        .pregen => {},
      }
      try self.resolve(fgen.body);
    },
    .gen_concat       => |gc| try self.resolve(gc.inner),
    .gen_enum         => |ge| for (ge.values) |vi| try self.resolve(vi.node),
    .gen_intersection => |gi| for (gi.types) |item| try self.resolve(item.node),
    .gen_list         => |gl| try self.resolve(gl.inner),
    .gen_map          => |gm| {
      try self.resolve(gm.key);
      try self.resolve(gm.value);
    },
    .gen_numeric      => |gn| if (self.stage.resolve_ctx) |ctx| {
      // bootstrapping for system.ny
      if (std.mem.eql(u8, ".std.system", node.pos.source.locator.repr)) {
        _ = try ctx.establishLink(self.intpr, "NumericImpl");
        try self.resolve(gn.backend);
        for ([_]?*model.Node{gn.min, gn.max}) |item| {
          if (item) |n| try self.resolve(n);
        }
      }
    },
    .gen_optional  => |go| try self.resolve(go.inner),
    .gen_unique    => |gu| if (gu.constr_params) |pn| try self.resolve(pn),
    .gen_prototype => |gp| {
      switch (gp.params) {
        .unresolved => |unode| try self.resolve(unode),
        .resolved   => |res| for (res.locations) |lref| switch (lref) {
          .node => |lnode| try self.resolve(lnode.node()),
          .expr => |expr| switch (expr.data) {
            .value => |value| switch (value.data) {
              .ast => |ast| try self.resolve(ast.root),
              else => {},
            },
            else => {},
          },
          .value, .poison => {},
        },
        .pregen => {},
      }
      for ([_]?*model.Node{gp.constructor, gp.funcs}) |cur| {
        if (cur) |n| try self.resolve(n);
      }
    },
    .gen_record => |gr| {
      switch (gr.fields) {
        .unresolved => |unode| try self.resolve(unode),
        .resolved   => |res| for (res.locations) |lref| switch (lref) {
          .node => |lnode| try self.resolve(lnode.node()),
          .expr => |expr| switch (expr.data) {
            .value => |value| switch (value.data) {
              .ast => |ast| try self.resolve(ast.root),
              else => {},
            },
            else => {},
          },
          .value, .poison => {},
        },
        .pregen => {},
      }
      if (gr.abstract) |anode| try self.resolve(anode);
      for (gr.embed) |embed| try self.resolve(embed.node);
    },
    .gen_sequence => |gs| {
      for (gs.inner) |item| try self.resolve(item.node);
      for ([_]?*model.Node{gs.direct, gs.auto}) |cur| {
        if (cur) |n| try self.resolve(n);
      }
    },
    .gen_textual => |*gt| if (self.stage.resolve_ctx) |ctx| {
      // bootstrapping for system.ny
      if (std.mem.eql(u8, ".std.system", gt.node().pos.source.locator.repr)) {
        _ = try ctx.establishLink(self.intpr, "UnicodeCategory");
        for (gt.categories) |cat| try self.resolve(cat.node);
        for ([_]?*model.Node{gt.exclude_chars, gt.include_chars}) |cur| {
          if (cur) |n| try self.resolve(n);
        }
      }
    },
    .highlighter => |*hl| {
      try self.resolve(hl.syntax);
      for (hl.renderers) |renderer| try self.resolve(renderer.content);
    },
    .import, .literal => {},
    .location => |loc| {
      try self.resolve(loc.name);
      if (loc.@"type") |tnode| try self.resolve(tnode);
      if (loc.default) |dnode| try self.resolve(dnode);
    },
    .map => |map| {
      try self.resolve(map.input);
      if (map.func) |fnode| try self.resolve(fnode);
      if (map.collector) |cnode| try self.resolve(cnode);
    },
    .match => |mat| {
      try self.resolve(mat.subject);
      for (mat.cases) |case| {
        try self.resolve(case.t);
        try self.resolve(case.content.root);
      }
    },
    .matcher => |mtr| try self.resolve(mtr.body.node()),
    .output  => |out| {
      try self.resolve(out.name);
      try self.resolve(out.body);
      if (out.schema) |snode| try self.resolve(snode);
    },
    .poison        => {},
    .resolved_call => |rcall| {
      _ = try self.resolveChain(rcall.target);
      for (rcall.args) |arg| try self.resolve(arg);
    },
    .resolved_access, .resolved_symref => {},
    .root_def => |rd| {
      if (rd.root) |rnode| try self.resolve(rnode);
      if (rd.params) |pnode| try self.resolve(pnode);
    },
    .seq => |seq| for (seq.items) |item| try self.resolve(item.content),
    .unresolved_access => |uacc| {
      try self.resolve(uacc.subject);
      try self.resolve(uacc.name);
    },
    .unresolved_call   => |ucall| {
      _ = try self.resolveChain(ucall.target);
      for (ucall.proto_args) |arg| try self.resolve(arg.content);
    },
    .unresolved_symref => _ = try self.resolveChain(node),
    .varargs => |va| for (va.content.items) |item| try self.resolve(item.node),
    .varmap  => |vm| for (vm.content.items) |item| {
      switch (item.key) {
        .node   => |knode| try self.resolve(knode),
        .direct => {},
      }
      try self.resolve(item.value);
    },
    .void      => {},
    .vt_setter => |vts| try self.resolve(vts.content),
  }
}