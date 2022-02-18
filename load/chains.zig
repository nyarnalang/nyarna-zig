const std = @import("std");
const nyarna = @import("../nyarna.zig");
const model = nyarna.model;
const errors = nyarna.errors;
const types = nyarna.types;
const lib = nyarna.lib;

const interpret = @import("interpret.zig");

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
  },
  /// the resolution failed because an identifier in the chain could not be
  /// resolved – this is not necessarily an error since the chain may be
  /// successfully resolved later.
  failed,
  /// this will be set if the chain is guaranteed to be faulty.
  poison,

  fn symRef(
    ns: u15,
    sym: *model.Symbol,
    prefix: ?*model.Node,
    name_pos: model.Position,
  ) Resolution {
    return .{.sym_ref = .{
      .ns = ns, .sym = sym, .prefix = prefix, .name_pos = name_pos,
    }};
  }

  fn chain(
    ns: u15,
    base: *model.Node,
    indexes: std.ArrayListUnmanaged(usize),
    t: model.Type,
    last_name_pos: model.Position,
  ) Resolution {
    return .{.runtime_chain = .{
      .ns = ns, .base = base, .indexes = indexes, .t = t,
      .last_name_pos = last_name_pos,
    }};
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
  ) ?SearchResult {
    switch (t) {
      .intrinsic, .structural => {},
      .instantiated => |inst| switch (inst.data) {
        .record => |*rec| {
          for (rec.constructor.sig.parameters) |*field, index| {
            if (std.mem.eql(u8, field.name, name)) {
              return SearchResult{.field = .{.index = index, .t = field.ptype}};
            }
          }
        },
        else => {},
      }
    }
    if (intpr.type_namespaces.get(t)) |ns| {
      if (ns.data.get(name)) |sym| return SearchResult{.symbol = sym};
    }
    return null;
  }

  /// resolves an accessor chain of *model.Node. if stage.kind != .intermediate,
  /// failure to resolve the base symbol will be reported as error and
  /// .poison will be returned; else .failed will be returned.
  pub fn resolve(self: Resolver, chain: *model.Node) nyarna.Error!Resolution {
    const last_name_pos = switch (chain.data) {
      .resolved_symref => |*rs| {
        switch (rs.sym.data) {
          .poison => return Resolution.poison,
          .variable => |*v| if (v.t.is(.every)) {
            std.debug.assert(self.stage.kind == .intermediate);
            return Resolution.failed;
          },
          else => {},
        }
        return Resolution.symRef(rs.ns, rs.sym, null, rs.name_pos);
      },
      .unresolved_access => |*uacc| {
        var res = try self.resolve(uacc.subject);
        switch (res) {
          .runtime_chain => |*rc| {
            if (
              searchAccessible(self.intpr, rc.t, uacc.id)
            ) |sr| switch (sr) {
              .field => |field| {
                try rc.indexes.append(self.intpr.allocator, field.index);
                rc.t = field.t;
                return res;
              },
              .symbol => |sym| {
                if (sym.data == .poison) return Resolution.poison;
                const subject = if (rc.indexes.items.len == 0) rc.base
                  else (try self.intpr.node_gen.raccess(
                    chain.pos, rc.base, rc.indexes.items, rc.last_name_pos
                  )).node();
                return Resolution.symRef(rc.ns, sym, subject, uacc.id_pos);
              },
            } else if (
              self.stage.kind != .intermediate and self.stage.kind != .resolve
            ) {
              // in .resolve stage there may still be unresolved accesses to
              // the current type's namespace, so we don't poison in that case
              // yet.
              self.intpr.ctx.logger.UnknownSymbol(chain.pos, uacc.id);
              return Resolution.poison;
            } else return Resolution.failed;
          },
          .sym_ref => |ref| {
            if (ref.prefix != null) {
              self.intpr.ctx.logger.PrefixedSymbolMustBeCalled(
                uacc.subject.pos);
              return Resolution.poison;
            }
            switch (ref.sym.data) {
              .func => |func| {
                const target = searchAccessible(
                  self.intpr, func.callable.typedef(), uacc.id)
                orelse if (
                  self.stage.kind == .keyword or self.stage.kind == .final
                ) {
                  self.intpr.ctx.logger.UnknownSymbol(chain.pos, uacc.id);
                  return Resolution.poison;
                } else return Resolution.failed;
                switch (target) {
                  .field => unreachable, // TODO: do functions have fields?
                  .symbol => |sym| {
                    if (sym.data == .poison) return .poison;
                    return Resolution.symRef(
                      ref.ns, sym, uacc.subject, uacc.id_pos);
                  },
                }
              },
              .@"type" => |t| {
                const target = searchAccessible(self.intpr, t, uacc.id)
                orelse if (
                  self.stage.kind == .keyword or self.stage.kind == .final
                ) {
                  self.intpr.ctx.logger.UnknownSymbol(chain.pos, uacc.id);
                  return Resolution.poison;
                } else return Resolution.failed;
                switch (target) {
                  .field => {
                    self.intpr.ctx.logger.FieldAccessWithoutInstance(chain.pos);
                    return .poison;
                  },
                  .symbol => |sym| {
                    if (sym.data == .poison) return .poison;
                    return Resolution.symRef(ref.ns, sym, null, ref.name_pos);
                  },
                }
              },
              // TODO: could we get a prototype here?
              .variable, .poison, .prototype => unreachable,
            }
          },
          .failed, .poison => return res,
        }
      },
      .unresolved_symref => |*usym| blk: {
        if (self.stage.resolve) |r| {
          switch (try r.probeSibling(self.intpr.allocator, chain)) {
            .variable => |v| {
              const name_pos = usym.namePos();
              chain.data = .{.resolved_symref = .{
                .sym = v.sym(),
                .ns = usym.ns,
                .name_pos = name_pos,
              }};
              std.debug.assert(!v.t.is(.every));
              return Resolution.chain(usym.ns, chain, .{}, v.t, name_pos);
            },
            .failed => return Resolution.poison,
            else => return Resolution.failed,
              // TODO: support chains for partially resolvable things (?).
          }
        }
        break :blk usym.namePos();
      },
      .resolved_access => |*racc| racc.last_name_pos,
      else => self.intpr.input.at(chain.pos.end),
    };

    if (try self.intpr.tryInterpret(chain, self.stage)) |expr| {
      chain.data = .{.expression = expr};
      return Resolution.chain(
        undefined, chain, .{}, expr.expected_type, last_name_pos);
    } else return @as(Resolution, if (self.stage.kind != .intermediate)
      .poison else .failed);
  }
};

pub const CallContext = union(enum) {
  known: struct {
    target: *model.Node,
    ns: u15,
    signature: *const model.Type.Signature,
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
      .intrinsic => |intr| if (intr == .poison) {
        return CallContext.poison;
      } else null,
      .instantiated => null,
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
        const subject = if (rc.indexes.items.len == 0) rc.base
        else (try intpr.node_gen.raccess(
          node.pos, rc.base, rc.indexes.items, rc.last_name_pos)).node();
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
            switch (intpr.ctx.types().typeType(t)) {
              .intrinsic => |intr| if (intr == .poison) return .poison,
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
              .instantiated => {},
            }
            intpr.ctx.logger.CantBeCalled(node.pos);
            return CallContext.poison;
          },
          .prototype => |pt| {
            return CallContext{.known = .{
              .target = node,
              .ns = undefined,
              .signature = intpr.ctx.types().prototypeConstructor(
                pt).callable.sig,
              .first_arg = null,
            }};
          },
          .poison, .variable => unreachable,
        }
      },
      .failed => return .unknown,
      .poison => return .poison,
    }
  }
};