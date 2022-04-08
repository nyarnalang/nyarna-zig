const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const interpret = @import("../interpret.zig");
const graph = @import("graph.zig");

/// Result of resolving an accessor chain.
pub const Resolution = union(enum) {
  /// chain descends into a runtime value. The base may be either a variable
  /// or an arbitrary expression.
  runtime_chain: struct {
    base: *model.Node,
    /// command character used for the base
    ns: u15,
    /// list of indexes to descend into at runtime.
    indexes: std.ArrayListUnmanaged(usize) = .{},
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
    ns: u15,
    sym: *model.Symbol,
    prefix: ?*model.Node,
    name_pos: model.Position,
    preliminary: bool,
  ) Resolution {
    return .{.sym_ref = .{
      .ns = ns, .sym = sym, .prefix = prefix, .name_pos = name_pos,
      .preliminary = preliminary,
    }};
  }

  fn chain(
    ns: u15,
    base: *model.Node,
    indexes: std.ArrayListUnmanaged(usize),
    t: model.Type,
    last_name_pos: model.Position,
    preliminary: bool,
  ) Resolution {
    return .{.runtime_chain = .{
      .ns = ns, .base = base, .indexes = indexes, .t = t,
      .last_name_pos = last_name_pos, .preliminary = preliminary,
    }};
  }

  fn functionReturning(t: model.Type, ns: u15) Resolution {
    return .{.function_returning = .{.returns = t, .ns = ns}};
  }
};

pub const Resolver = struct {
  const SearchResult = union(enum) {
    field: struct {
      index: usize,
      t: model.Type,
    },
    symbol: *model.Symbol,
  };


  intpr: *interpret.Interpreter,
  stage: interpret.Stage,

  pub fn init(intpr: *interpret.Interpreter, stage: interpret.Stage) Resolver {
    return .{.intpr = intpr, .stage = stage};
  }

  fn searchAccessible(
    intpr: *interpret.Interpreter,
    t: model.Type,
    name: []const u8
  ) !?SearchResult {
    switch (t) {
      .instantiated => |inst| switch (inst.data) {
        .record => |*rec| {
          for (rec.constructor.sig.parameters) |*field, index| {
            if (std.mem.eql(u8, field.name, name)) {
              return SearchResult{.field = .{.index = index, .t = field.ptype}};
            }
          }
        },
        else => {},
      },
      else => {},
    }
    if (intpr.type_namespaces.get(t)) |ns| {
      if (ns.data.get(name)) |sym| return SearchResult{.symbol = sym};
    }
    if (try intpr.ctx.types().instanceFuncsOf(t)) |funcs| {
      if (try funcs.find(intpr.ctx, name)) |sym| {
        return SearchResult{.symbol = sym};
      }
    }
    return null;
  }

  fn resolveSymref(self: Resolver, rs: *model.Node.ResolvedSymref) Resolution {
    switch (rs.sym.data) {
      .poison => return Resolution.poison,
      .variable => |*v| {
        if (v.t.isInst(.every)) {
          std.debug.assert(self.stage.kind == .intermediate);
          return Resolution{.failed = rs.ns};
        } else {
          return Resolution.chain(
            rs.ns, rs.node(), .{}, v.t, rs.name_pos, false);
        }
      },
      else => {},
    }
    return Resolution.symRef(rs.ns, rs.sym, null, rs.name_pos, false);
  }

  fn fromGraphResult(
    self: Resolver,
    node: *model.Node,
    ns: u15,
    name: []const u8,
    name_pos: model.Position,
    res: graph.ResolutionContext.StrippedResult,
    stage: interpret.Stage,
  ) Resolution {
    switch (res) {
      .variable => |v| {
        node.data = .{.resolved_symref = .{
          .sym = v.sym(),
          .ns = ns,
          .name_pos = name_pos,
        }};
        std.debug.assert(!v.t.isInst(.every));
        return Resolution.chain(ns, node, .{}, v.t, name_pos, false);
      },
      .poison => return Resolution.poison,
      .unknown => switch (stage.kind) {
        .keyword => {
          self.intpr.ctx.logger.CannotResolveImmediately(node.pos);
          return Resolution.poison;
        },
        .final => {
          self.intpr.ctx.logger.UnknownSymbol(node.pos, name);
          return Resolution.poison;
        },
        .assumed => unreachable,
        else => return Resolution{.failed = ns},
      },
      .unfinished_function => |t| return Resolution.functionReturning(t, ns),
      else => return Resolution{.failed = ns},
    }
  }

  fn resolveUAccess(
    self: Resolver,
    uacc: *model.Node.UnresolvedAccess,
  ) nyarna.Error!Resolution {
    var res = try self.resolve(uacc.subject);
    const ns = switch (res) {
      // access on an unknown function. can't be resolved.
      .function_returning => |*fr| fr.ns,
      .runtime_chain => |*rc| blk: {
        if (try searchAccessible(self.intpr, rc.t, uacc.id)) |sr| switch (sr) {
          .field => |field| {
            try rc.indexes.append(self.intpr.allocator, field.index);
            rc.t = field.t;
            return res;
          },
          .symbol => |sym| {
            if (sym.data == .poison) return Resolution.poison;
            const subject = if (rc.indexes.items.len == 0) rc.base
              else (try self.intpr.node_gen.raccess(
                uacc.node().pos, rc.base, rc.indexes.items, rc.last_name_pos,
                rc.ns)).node();
            return Resolution.symRef(
              rc.ns, sym, subject, uacc.id_pos, rc.preliminary);
          },
        };
        break :blk rc.ns;
      },
      .sym_ref => |ref| blk: {
        if (!ref.preliminary and ref.prefix != null) {
          self.intpr.ctx.logger.PrefixedSymbolMustBeCalled(uacc.subject.pos);
          return Resolution.poison;
        }
        switch (ref.sym.data) {
          .func => |func| {
            const target = (
              try searchAccessible(
                self.intpr, func.callable.typedef(), uacc.id)
            ) orelse break :blk ref.ns;
            switch (target) {
              .field => unreachable, // TODO: do functions have fields?
              .symbol => |sym| {
                if (sym.data == .poison) return .poison;
                return Resolution.symRef(
                  ref.ns, sym, uacc.subject, uacc.id_pos, ref.preliminary);
              },
            }
          },
          .@"type" => |t| {
            const target = (
              try searchAccessible(self.intpr, t, uacc.id)
            ) orelse break :blk ref.ns;
            switch (target) {
              .field => {
                self.intpr.ctx.logger.FieldAccessWithoutInstance(
                  uacc.node().pos);
                return .poison;
              },
              .symbol => |sym| {
                if (sym.data == .poison) return .poison;
                return Resolution.symRef(
                  ref.ns, sym, null, ref.name_pos, ref.preliminary);
              },
            }
          },
          // TODO: could we get a prototype here?
          .variable, .poison, .prototype => unreachable,
        }
      },
      .failed => |ns| ns,
      .poison => return res,
    };

    if (self.stage.kind != .intermediate and self.stage.kind != .resolve) {
      // in .resolve stage there may still be unresolved accesses to the
      // current type's namespace, so we don't poison in that case yet.
      self.intpr.ctx.logger.UnknownSymbol(uacc.id_pos, uacc.id);
      return Resolution.poison;
    } else if (self.stage.resolve) |r| {
      return self.fromGraphResult(uacc.node(), ns, uacc.id, uacc.id_pos,
        (try r.resolveAccess(self.intpr, uacc, self.stage)).result, self.stage);
    } else return Resolution{.failed = ns};
  }

  fn resolveUCall(
    self: Resolver,
    ucall: *model.Node.UnresolvedCall,
  ) nyarna.Error!Resolution {
    const res = try self.resolve(ucall.target);
    switch (res) {
      .function_returning => |*fr| {
        return Resolution.chain(fr.ns, ucall.target, .{}, fr.returns,
          self.intpr.input.at(ucall.node().pos.end), true);
      },
      .runtime_chain => |*rc| {
        if (rc.preliminary) {
          switch (rc.t) {
            .structural => |strct| switch (strct.*) {
              .callable => |*callable| {
                return Resolution.chain(
                  rc.ns, ucall.node(), .{}, callable.sig.returns,
                  self.intpr.input.at(ucall.node().pos.end), true
                );
              },
              else => {},
            },
            else => {},
          }
          return Resolution{.failed = rc.ns}; // TODO: or poison (?)
        } else {
          const expr =
            (try self.intpr.interpretCallToChain(ucall, res, self.stage))
          orelse return Resolution{.failed = rc.ns};
          const node = ucall.node();
          node.data = .{.expression = expr};
          return Resolution.chain(
            undefined, node, .{}, expr.expected_type, rc.last_name_pos, false);
        }
      },
      .sym_ref => |*sr| {
        if (sr.preliminary) {
          switch (sr.sym.data) {
            .func => |f|
              return Resolution.chain(sr.ns, ucall.node(), .{},
                f.callable.sig.returns, sr.name_pos, true),
            .variable => |*v| {
              switch (v.t) {
                .structural => |strct| switch (strct.*) {
                  .callable => |*callable| return Resolution.chain(sr.ns,
                    ucall.node(), .{}, callable.sig.returns, sr.name_pos, true),
                  else => {},
                },
                else => {},
              }
              return Resolution{.failed = sr.ns};
            },
            .@"type" => |t| return Resolution.chain(
              sr.ns, ucall.node(), .{}, t, sr.name_pos, true),
            // since prototypes cannot be assigned to variables or returned
            // from functions, delayed resolution can never result in a
            // prototype.
            .prototype => unreachable,
            .poison => return Resolution.poison,
          }
        } else {
          const expr =
            (try self.intpr.interpretCallToChain(ucall, res, self.stage))
          orelse return Resolution{.failed = sr.ns};
          const node = ucall.node();
          node.data = .{.expression = expr};
          return Resolution.chain(
            undefined, node, .{}, expr.expected_type, sr.name_pos, false);
        }
      },
      .failed, .poison => return res,
    }
  }

  /// resolves an accessor chain of *model.Node. if stage.kind != .intermediate,
  /// failure to resolve the base symbol will be reported as error and
  /// .poison will be returned; else .failed will be returned.
  pub fn resolve(self: Resolver, chain: *model.Node) nyarna.Error!Resolution {
    var ns: u15 = undefined;
    const last_name_pos = switch (chain.data) {
      .resolved_symref => |*rs| return self.resolveSymref(rs),
      .unresolved_access => |*uacc| return try self.resolveUAccess(uacc),
      .unresolved_call => |*ucall| return try self.resolveUCall(ucall),
      .unresolved_symref => |*usym| blk: {
        const namespace = self.intpr.namespace(usym.ns);
        const name_pos = usym.namePos();
        if (namespace.data.get(usym.name)) |sym| {
          chain.data = .{.resolved_symref = .{
            .ns = usym.ns, .sym = sym, .name_pos = name_pos,
          }};
          ns = usym.ns;
          break :blk name_pos;
        } else if (self.stage.resolve) |r| {
          return self.fromGraphResult(chain, usym.ns, usym.name, name_pos,
            try r.resolveSymbol(self.intpr, usym), self.stage);
        } else switch (self.stage.kind) {
          .keyword => {
            self.intpr.ctx.logger.CannotResolveImmediately(chain.pos);
            return Resolution.poison;
          },
          .final => {
            self.intpr.ctx.logger.UnknownSymbol(chain.pos, usym.name);
            return Resolution.poison;
          },
          .assumed => unreachable,
          else => return Resolution{.failed = usym.ns},
        }
      },
      .resolved_access => |*racc| blk: {
        ns = racc.ns;
        break :blk racc.last_name_pos;
      },
      else => self.intpr.input.at(chain.pos.end),
    };

    if (try self.intpr.tryInterpret(chain, self.stage)) |expr| {
      chain.data = .{.expression = expr};
      return Resolution.chain(
        undefined, chain, .{}, expr.expected_type, last_name_pos, false);
    } else return switch (self.stage.kind) {
      .intermediate, .resolve => Resolution{.failed = ns},
      else => Resolution.poison,
    };
  }
};

pub const CallContext = union(enum) {
  known: struct {
    target: *model.Node,
    ns: u15,
    signature: *const model.Signature,
    first_arg: ?*model.Node,
  },
  unknown, poison,

  fn chainIntoCallCtx(
    intpr: *interpret.Interpreter,
    target: *model.Node,
    t: model.Type,
    ns: u15,
  ) !CallContext {
    const callable = switch (t) {
      .structural => |strct| switch (strct.*) {
        .callable => |*callable| callable,
        else => null,
      },
      .instantiated => |inst| switch (inst.data) {
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
    intpr: *interpret.Interpreter,
    node: *model.Node,
    res: Resolution,
  ) !CallContext {
    switch (res) {
      .runtime_chain => |rc| {
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
              .instantiated => |inst| switch (inst.data) {
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