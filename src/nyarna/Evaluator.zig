//! The Evaluator implements evaluation of expressions, which returns values.

const builtin = @import("builtin");
const std     = @import("std");

const nyarna      = @import("../nyarna.zig");

const Interpreter = nyarna.Interpreter;
const model       = nyarna.model;
const Types       = nyarna.Types;

const Evaluator = @This();

ctx: nyarna.Context,
// current type that is being called. used by type constructors that need to
// behave depending on the target type

/// current context type. This is used for:
/// - type constructors that need to behave depending on the returned type
/// - builtin functions in the namespace of a type, which could result from
///   prototype functions and thus might not know the type they're called on.
target_type: model.Type = undefined,

const line_feeds = "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n";

fn lineFeeds(self: *Evaluator, num: usize) ![]const u8 {
  if (num <= line_feeds.len) return line_feeds[0..num];
  const ret = try self.ctx.global().alloc(u8, num);
  std.mem.set(u8, ret, '\n');
  return ret;
}

pub fn allocateStackFrame(
  self         : *Evaluator,
  num_variables: usize,
  prev_frame   : ?[*]model.StackItem
) ![*]model.StackItem {
  const data = self.ctx.data;
  if (
    (@ptrToInt(data.stack_ptr) - @ptrToInt(data.stack.ptr))
    / @sizeOf(model.StackItem) + num_variables > data.stack.len
  ) {
    return nyarna.Error.nyarna_stack_overflow;
  }
  const ret = data.stack_ptr;
  data.stack_ptr += num_variables + 1;
  ret.* = .{.frame_ref = prev_frame};
  return ret;
}

fn setupParameterStackFrame(
  self        : *Evaluator,
  num_values  : usize,
  ns_dependent: bool,
  prev_frame  : ?[*]model.StackItem,
) ![*]model.StackItem {
  const num_params = num_values + if (ns_dependent) @as(usize, 1) else 0;
  return self.allocateStackFrame(num_params, prev_frame);
}

pub fn resetStackFrame(
  self         : *Evaluator,
  frame_ptr    : *?[*]model.StackItem,
  num_variables: usize,
  ns_dependent : bool,
) void {
  frame_ptr.* = frame_ptr.*.?[0].frame_ref;
  self.ctx.data.stack_ptr -= num_variables + 1;
  if (ns_dependent) self.ctx.data.stack_ptr -= 1;
}

pub fn fillParameterStackFrame(
  self : *Evaluator,
  exprs: []*model.Expression,
  frame: [*]model.StackItem,
) !bool {
  var seen_poison = false;
  for (exprs) |expr, i| {
    const val = try self.evaluate(expr);
    frame[i] = .{.value = val};
    if (val.data == .poison) seen_poison = true;
  }
  return !seen_poison;
}

fn RetTypeForCtx(comptime ImplCtx: type) type {
  return switch (ImplCtx) {
    *Evaluator => *model.Value,
    *Interpreter => *model.Node,
    else => unreachable
  };
}

fn FnTypeForCtx(comptime ImplCtx: type) type {
  return switch (ImplCtx) {
    *Evaluator => nyarna.lib.Provider.BuiltinWrapper,
    *Interpreter => nyarna.lib.Provider.KeywordWrapper,
    else => unreachable
  };
}

fn registeredFnForCtx(
           self   : *Evaluator,
  comptime ImplCtx: type,
           index  : usize,
) FnTypeForCtx(ImplCtx) {
  return switch (ImplCtx) {
    *Evaluator => self.ctx.data.builtin_registry.items[index],
    *Interpreter => self.ctx.data.keyword_registry.items[index],
    else => unreachable
  };
}

fn poison(
  impl_ctx: anytype,
  pos     : model.Position,
) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
  switch (@TypeOf(impl_ctx)) {
    *Evaluator => return try impl_ctx.ctx.values.poison(pos),
    *Interpreter => return impl_ctx.node_gen.poison(pos),
    else => unreachable,
  }
}

fn callConstructor(
  self    : *Evaluator,
  impl_ctx: anytype,
  pos     : model.Position,
  args    : []*model.Expression,
  constr  : Types.Constructor,
  t       : model.Type,
) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
  const callable = constr.callable.?;
  const target_impl =
    self.registeredFnForCtx(@TypeOf(impl_ctx), constr.impl_index);
  std.debug.assert(args.len == callable.sig.parameters.len);
  var frame: ?[*]model.StackItem = try self.setupParameterStackFrame(
    callable.sig.parameters.len, false, null);
  defer self.resetStackFrame(&frame, callable.sig.parameters.len, false);
  if (try self.fillParameterStackFrame(args, frame.? + 1)) {
    self.target_type = t;
    return target_impl(impl_ctx, pos, frame.? + 1);
   } else {
    return poison(impl_ctx, pos);
   }
}

fn evalExtFuncCall(
  self    : *Evaluator,
  impl_ctx: anytype,
  pos     : model.Position,
  func    : *model.Function,
  ns      : u15,
  args    : []*model.Expression,
) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
  const ef = &func.data.ext;
  const target_impl =
    self.registeredFnForCtx(@TypeOf(impl_ctx), ef.impl_index);
  std.debug.assert(args.len == func.sig().parameters.len);
  const target_frame = try self.setupParameterStackFrame(
    func.variables.num_values, ef.ns_dependent, func.variables.cur_frame);
  var frame_ptr = func.argStart(target_frame);
  var ns_val: model.Value = undefined;
  if (ef.ns_dependent) {
    ns_val = .{
      .data = .{
        .int = .{
          .t = undefined, // not accessed, since the wrapper assumes
                          // that the value adheres to the target
                          // type's constraints
          .content = ns,
          .cur_unit = undefined,
        },
      },
      .origin = undefined,
    };
    frame_ptr.* = .{.value = &ns_val};
    frame_ptr += 1;
  }
  defer self.resetStackFrame(
    &func.variables.cur_frame, func.variables.num_values, ef.ns_dependent);
  if (func.name) |fname| if (fname.parent_type) |ptype| {
    self.target_type = ptype;
  };
  if (
    try self.fillParameterStackFrame(args, frame_ptr)
  ) {
    func.variables.cur_frame = target_frame;
    return target_impl(impl_ctx, pos, func.argStart(target_frame));
  } else {
    // required for resetStackFrame to work properly
    func.variables.cur_frame = target_frame;
    return poison(impl_ctx, pos);
  }
}

fn evalCall(
  self    : *Evaluator,
  impl_ctx: anytype,
  call    : *model.Expression.Call,
) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
  const target = try self.evaluate(call.target);
  switch (target.data) {
    .funcref => |fr| {
      switch (fr.func.data) {
        .ext => return self.evalExtFuncCall(
          impl_ctx, call.expr().pos, fr.func, call.ns, call.exprs),
        .ny => |*nf| {
          const target_frame = try self.setupParameterStackFrame(
            fr.func.variables.num_values, false, fr.func.variables.cur_frame);
          defer self.resetStackFrame(
            &fr.func.variables.cur_frame, fr.func.variables.num_values, false
          );
          if (try self.fillParameterStackFrame(
              call.exprs, fr.func.argStart(target_frame))) {
            fr.func.variables.cur_frame = target_frame;
            const val = try self.evaluate(nf.body);
            return switch (@TypeOf(impl_ctx)) {
              *Evaluator => val,
              *Interpreter => val.data.ast.root,
              else => unreachable,
            };
          } else {
            // required for resetStackFrame to work correctly
            fr.func.variables.cur_frame = target_frame;
            return poison(impl_ctx, call.expr().pos);
          }
        },
      }
    },
    .@"type" => |tv| {
      if (@TypeOf(impl_ctx) == *Evaluator) switch (tv.t) {
        .named => |named| switch (named.data) {
          .record => |*rec| {
            std.debug.assert(
              call.exprs.len == rec.constructor.sig.parameters.len);
            var frame: ?[*]model.StackItem =
              try self.setupParameterStackFrame(
                rec.constructor.sig.parameters.len, false, null);
            defer self.resetStackFrame(
              &frame, rec.constructor.sig.parameters.len, false);
            if (
              try self.fillParameterStackFrame(call.exprs, frame.? + 1)
            ) {
              const ret = try self.ctx.values.record(call.expr().pos, rec);
              const first_value = frame.? + 1;
              for (ret.fields) |*field, index| {
                field.* = first_value[index].value;
              }
              return ret.value();
            } else return poison(impl_ctx, call.expr().pos);
          },
          else => {},
        },
        else => {},
      } else unreachable;
      return self.callConstructor(
        impl_ctx, call.expr().pos, call.exprs,
        try self.ctx.types().typeConstructor(tv.t), tv.t);
    },
    .poison => return switch (@TypeOf(impl_ctx)) {
      *Evaluator => self.ctx.values.poison(call.expr().pos),
      *Interpreter => impl_ctx.node_gen.poison(call.expr().pos),
      else => unreachable,
    },
    else => unreachable
  }
}

pub fn evaluateKeywordCall(
  self  : *Evaluator,
  intpr : *Interpreter,
  pos   : model.Position,
  ns    : u15,
  target: *model.Symbol,
  args  : []*model.Expression,
) !*model.Node {
  switch (target.data) {
    .func => |func| {
      return self.evalExtFuncCall(intpr, pos, func, ns, args);
    },
    .prototype => |pt| {
      return self.callConstructor(
        intpr, pos, args, self.ctx.types().prototypeConstructor(pt),
        undefined); // self.target_type unused for prototype constructors
    },
    .@"type" => |t| {
      const constr = try self.ctx.types().typeConstructor(t);
      if (constr.callable.?.sig.isKeyword()) {
        return self.callConstructor(intpr, pos, args, constr, t);
      } else {
        std.debug.panic("type {s} is not called as keyword!", .{t.formatter()});
      }
    },
    else => std.debug.panic("{s} is not a keyword!", .{@tagName(target.data)})
  }
}

fn checkRange(
  self   : *Evaluator,
  value  : *model.Value,
  subject: anytype,
) !bool {
  if (
    value.data.int.content <= 0 or
    value.data.int.content > subject.content.items.len
  ) {
    const str = try std.fmt.allocPrint(
      self.ctx.global(), "{}", .{value.data.int.content});
    self.ctx.logger.OutOfRange(
      value.origin, subject.t.typedef(), str);
    return false;
  } else return true;
}

fn walkPath(
  self: *Evaluator,
  base: **model.Value,
  path: []const model.Expression.Access.PathItem,
) !?**model.Value {
  var cur = base;
  for (path) |item| switch (item) {
    .field     => |field| {
      const rval = &cur.*.data.record;
      cur = if (rval.t == field.t) (
        &rval.fields[rval.t.first_own + field.index]
      ) else for (rval.t.embeds) |embed| {
        if (embed.t == field.t) {
          break &rval.fields[embed.first_field + field.index];
        }
      } else unreachable;
    },
    .subscript => |expr| {
      const value = try self.evaluate(expr);
      if (value.data == .poison) return null;
      switch (cur.*.data) {
        .concat => |*con| if (try self.checkRange(value, con)) {
          cur = &con.content.items[@intCast(usize, value.data.int.content) - 1];
        } else return null,
        .list => |*lst| if (try self.checkRange(value, lst)) {
          cur = &lst.content.items[@intCast(usize, value.data.int.content) - 1];
        } else return null,
        .seq => |*seq| if (try self.checkRange(value, seq)) {
          cur = &seq.content.items[
            @intCast(usize, value.data.int.content) - 1].content;
        } else return null,
        else => unreachable,
      }
    }
  };
  return cur;
}

fn evalAccess(
  self  : *Evaluator,
  access: *model.Expression.Access,
) nyarna.Error!*model.Value {
  var cur = try self.evaluate(access.subject);
  const res = (
    try self.walkPath(&cur, access.path)
  ) orelse return try self.ctx.values.poison(access.expr().pos);
  return res.*;
}

fn evalAssignment(
  self: *Evaluator,
  ass : *model.Expression.Assignment,
) nyarna.Error!*model.Value {
  var cur_ptr = ass.target.curPtr();
  cur_ptr = (
    try self.walkPath(cur_ptr, ass.path)
  ) orelse return try self.ctx.values.poison(ass.expr().pos);
  cur_ptr.* = try self.evaluate(ass.rexpr);
  return self.ctx.values.@"void"(ass.expr().pos);
}

fn evalBranches(
  self: *Evaluator,
  br  : *model.Expression.Branches,
) nyarna.Error!*model.Value {
  var condition = try self.evaluate(br.condition);
  if ((try self.ctx.types().valueType(condition)).isNamed(.poison)) {
    return self.ctx.values.poison(br.expr().pos);
  }
  return self.evaluate(br.branches[condition.data.@"enum".index]);
}

fn evalConcatenation(
  self  : *Evaluator,
  expr  : *model.Expression,
  concat: model.Expression.Concatenation,
) nyarna.Error!*model.Value {
  var builder = ConcatBuilder.init(
    self.ctx, expr.pos, expr.expected_type);
  for (concat) |item| try builder.push(try self.evaluate(item));
  return try builder.finish();
}

fn convertIntoConcat(
  self : *Evaluator,
  value: *model.Value,
  into : *ConcatBuilder,
) nyarna.Error!void {
  switch (value.data) {
    .concat => |*vcon| {
      for (vcon.content.items) |item| try self.convertIntoConcat(item, into);
    },
    .text, .int, .float, .@"enum", .void => {
      if (into.scalar_type) |stype| {
        try into.push(try self.doConvert(value, stype));
      } else {
        std.debug.assert(value.data.text.t.isNamed(.space));
      }
    },
    .record => try into.push(value),
    .seq => |*seq| {
      for (seq.content.items) |p, index| {
        try self.convertIntoConcat(p.content, into);
        if (index != seq.content.items.len - 1) {
          try into.pushSpace(p.lf_after);
        }
      }
    },
    else => unreachable,
  }
}

const NonRecordTarget = union(enum) {
  direct: model.Type,
  auto  : u21,
};

fn convertIntoSequence(
  self    : *Evaluator,
  value   : *model.Value,
  lf_after: usize,
  into    : *SequenceBuilder,
  non_rec : NonRecordTarget,
  others  : []*model.Type.Record,
) nyarna.Error!void {
  switch (value.data) {
    .seq => |*seq| {
      for (seq.content.items) |item| {
        try self.convertIntoSequence(
          item.content, item.lf_after, into, non_rec, others);
      }
      return;
    },
    .record => |*rec| for (others) |other_rec| if (rec.t == other_rec) {
      try into.push(value, lf_after);
      return;
    },
    .poison, .void => return,
    else => {},
  }
  const t = try self.ctx.types().valueType(value);
  switch (non_rec) {
    .direct => |direct| {
      if (self.ctx.types().lesserEqual(t, direct)) {
        try into.push(value, lf_after);
        return;
      }
      try into.push(try self.doConvert(value, direct), lf_after);
    },
    .auto => |index| {
      const rec = others[index];
      const rec_val = try self.ctx.values.record(value.origin, rec);
      for (rec_val.fields) |*field, i| {
        const param = rec.constructor.sig.parameters[i];
        field.* = if (i == rec.constructor.sig.primary.?) (
          try self.doConvert(value, param.spec.t)
        ) else if (param.default) |expr| (
          try self.evaluate(expr)
        ) else switch (param.spec.t) {
          .structural => |strct| switch (strct.*) {
            .concat, .optional, .sequence => (
              try self.ctx.values.@"void"(param.spec.pos)
            ),
            .hashmap => |*hm| (
              try self.ctx.values.hashMap(param.spec.pos, hm)
            ).value(),
            .list    => |*lst| (
              try self.ctx.values.list(param.spec.pos, lst)
            ).value(),
            else => unreachable,
          },
          .named => |named| switch (named.data) {
            .void => try self.ctx.values.@"void"(param.spec.pos),
            else  => unreachable,
          }
        };
      }
      try into.push(rec_val.value(), lf_after);
    }
  }
}

fn doConvert(
  self : *Evaluator,
  value: *model.Value,
  to   : model.Type,
) nyarna.Error!*model.Value {
  const from = try self.ctx.types().valueType(value);
  if (from.isNamed(.poison)) return value;
  if (self.ctx.types().lesserEqual(from, to)) {
    return try self.coerce(value, to);
  }
  switch (to) {
    .named => |named| switch (named.data) {
      .literal, .space => {
        std.debug.assert(from.isNamed(.void));
        return (try self.ctx.values.textScalar(value.origin, to, "")).value();
      },
      // this is a conversion from a record to one of its embeds. We *will* need
      // the original value for accessing it since fields may be reordered.
      .record => return value,
      .schema  => {
        std.debug.assert(from.isNamed(.schema_def));
        const sd = &value.data.schema_def;
        const backend_name = if (sd.backends.len == 1) (
          try self.ctx.values.textScalar(
            model.Position.intrinsic(), self.ctx.types().text(),
            sd.backends[0].name.content)
        ) else null;
        var builder = try nyarna.Loader.SchemaBuilder.create(
          &value.data.schema_def, self.ctx.data, backend_name);
        const schema = (
          try builder.finalize(value.origin)
        ) orelse return try self.ctx.values.poison(value.origin);
        return schema.value();
      },
      .textual => |*txt| {
        const input = switch (value.data) {
          .void => "",
          .text => |*intxt| intxt.content,
          .@"enum" => |*e| e.t.values.keys()[e.index],
          .seq => |*seq| blk: {
            var builder = std.ArrayListUnmanaged(u8){};
            for (seq.content.items) |item, i| {
              switch (item.content.data) {
                .void => {},
                .text => |*intxt| {
                  try builder.appendSlice(self.ctx.global(), intxt.content);
                },
                .@"enum" => |*e| try builder.appendSlice(
                  self.ctx.global(), e.t.values.keys()[e.index]),
                else => unreachable,
              }
              if (i < seq.content.items.len) {
                try builder.appendNTimes(
                  self.ctx.global(), '\n', item.lf_after);
              }
            }
            break :blk builder.items;
          },
          // TODO: convert between numeric types directly
          .int   => |*int_val| try self.toString(int_val),
          .float => |*float_val| try self.toString(float_val),
          else   => unreachable,
        };
        return if (
          try self.ctx.textFromString(value.origin, input, txt)
        ) |nv| nv.value() else try self.ctx.values.poison(value.origin);
      },
      else => unreachable,
    },
    .structural => |struc| switch (struc.*) {
      .callable => unreachable,
      .concat   => {
        var builder = ConcatBuilder.init(self.ctx, value.origin, to);
        try self.convertIntoConcat(value, &builder);
        return try builder.finish();
      },
      .hashmap => |*map| {
        const ret = try self.ctx.values.hashMap(value.origin, map);
        var iter = value.data.hashmap.items.iterator();
        while (iter.next()) |entry| {
          const res = try ret.items.getOrPut(
            try self.doConvert(entry.key_ptr.*, map.key));
          std.debug.assert(!res.found_existing);
          res.value_ptr.* = try self.doConvert(entry.value_ptr.*, map.value);
        }
        return ret.value();
      },
      .intersection => unreachable,
      .list         => |*lst| {
        const ret = try self.ctx.values.list(value.origin, lst);
        for (value.data.list.content.items) |item| {
          try ret.content.append(try self.doConvert(item, lst.inner));
        }
        return ret.value();
      },
      .optional => |*opt| return self.doConvert(value, opt.inner),
      .sequence => |*seq| {
        var builder = SequenceBuilder.init(self.ctx);
        try self.convertIntoSequence(
          value, 0, &builder,
          if (seq.direct) |d| .{.direct = d} else .{.auto = seq.auto.?.index},
          seq.inner);
        return try builder.finish(value.origin);
      }
    }
  }
}

fn evalConversion(
  self   : *Evaluator,
  convert: *model.Expression.Conversion,
) nyarna.Error!*model.Value {
  const inner_val = try self.evaluate(convert.inner);
  return self.doConvert(inner_val, convert.target_type);
}

fn evalIfOpt(
  self : *Evaluator,
  ifopt: *model.Expression.IfOpt,
) nyarna.Error!*model.Value {
  const cond = try self.evaluate(ifopt.condition);
  switch (cond.data) {
    .void   => if (ifopt.@"else") |en| {
      return try self.evaluate(en);
    } else return try self.ctx.values.void(ifopt.expr().pos),
    .poison => return cond,
    else    => {
      if (ifopt.variable) |v| {
        const frame = try self.allocateStackFrame(1, v.container.cur_frame);
        v.container.cur_frame = frame;
        (frame + 1).* = .{.value = cond};
      }
      defer if (ifopt.variable) |v| {
        self.resetStackFrame(&v.container.cur_frame, 1, false);
      };
      return try self.evaluate(ifopt.then);
    }
  }
}

fn evalLocation(
  self: *Evaluator,
  loc : *model.Expression.Location,
) nyarna.Error!*model.Value {
  const spec: model.SpecType = if (loc.@"type") |t| blk: {
    const eval_t = switch ((try self.evaluate(t)).data) {
      .@"type" => |tv| tv.t,
      .poison => self.ctx.types().poison(),
      else => unreachable
    };
    break :blk eval_t.at(t.pos);
  } else if (loc.default) |default| default.expected_type.at(default.pos)
  else blk: {
    self.ctx.logger.MissingSymbolType(loc.expr().pos);
    break :blk self.ctx.types().poison().predef();
  };
  if (loc.additionals) |add| {
    if (add.varmap) |varmap| {
      if (add.varargs) |varargs| {
        self.ctx.logger.IncompatibleFlag("varmap", varmap, varargs);
        add.varmap = null;
      } else if (add.borrow) |borrow| {
        self.ctx.logger.IncompatibleFlag("varmap", varmap, borrow);
        add.varmap = null;
      }
    } else if (add.varargs) |varargs| if (add.borrow) |borrow| {
      self.ctx.logger.IncompatibleFlag("borrow", borrow, varargs);
      add.borrow = null;
    };
    if (!spec.t.isNamed(.poison)) {
      if (add.varmap != null) if (!spec.t.isStruc(.hashmap)) {
        self.ctx.logger.VarmapRequiresMap(&[_]model.SpecType{spec});
        add.varmap = null;
      };
      if (add.varargs != null) if (!spec.t.isStruc(.list)) {
        self.ctx.logger.VarargsRequiresList(&[_]model.SpecType{spec});
        add.varargs = null;
      };
      if (add.borrow != null) if (
        !switch (spec.t) {
          .structural => |struc| switch (struc.*) {
            .list, .concat, .sequence, .callable => true,
            else => false,
          },
          .named => |named| switch (named.data) {
            .record, .prototype => true,
            else => false,
          },
        }
      ) {
        self.ctx.logger.BorrowRequiresRef(&[_]model.SpecType{spec});
        add.borrow = null;
      };
    }
  }
  const name = switch ((try self.evaluate(loc.name)).data) {
    .text => |*txt| txt,
    .poison => return try self.ctx.values.poison(loc.expr().pos),
    else => unreachable,
  };
  const loc_val = try self.ctx.values.location(loc.expr().pos, name, spec);
  loc_val.default = loc.default;
  loc_val.primary = if (loc.additionals) |add| add.primary else null;
  loc_val.varargs = if (loc.additionals) |add| add.varargs else null;
  loc_val.varmap  = if (loc.additionals) |add| add.varmap  else null;
  loc_val.borrow  = if (loc.additionals) |add| add.borrow  else null;
  loc_val.header  = if (loc.additionals) |add| add.header  else null;
  return loc_val.value();
}

// helper for calling a given target multiple times with one arg
const Caller = struct {
  call_expr  : ?*model.Expression.Call,
  eval       : *Evaluator,
  tmp_expr   : ?*model.Expression = null,
  takes_index: bool,

  fn init(
    eval    : *Evaluator,
    func    : ?*model.Expression,
    pos     : model.Position,
    ret_type: model.Type,
  ) !?Caller {
    if (func) |target| {
      var t_val     : *model.Value      = undefined;
      var t_val_expr: *model.Expression = undefined;
      switch (target.data) {
        .value => |val| {
          t_val = val;
          t_val_expr = target;
        },
        else => {
          t_val = try eval.evaluate(target);
          t_val_expr = try eval.ctx.createValueExpr(t_val);
        }
      }
      const t_type = try eval.ctx.types().valueType(t_val);
      const has_index = switch (t_type) {
        .structural => |strct| switch (strct.*) {
          .callable => |*c| c.sig.parameters.len == 2,
          else => unreachable,
        },
        .named => |named| switch (named.data) {
          .poison => return null,
          else => unreachable,
        },
      };

      const expr = try eval.ctx.global().create(model.Expression);
      expr.* = .{
        .pos  = pos,
        .data = .{.call = .{
          .ns     = undefined,
          .target = t_val_expr,
          .exprs  = undefined,
        }},
        .expected_type = ret_type,
      };
      return Caller{
        .eval        = eval,
        .call_expr   = &expr.data.call,
        .takes_index = has_index,
      };
    } else return Caller{
      .eval        = eval,
      .call_expr   = null,
      .takes_index = false,
    };
  }

  fn call(self: @This(), input: *model.Expression, index: usize) !*model.Value {
    if (self.call_expr) |expr| {
      expr.exprs = if (self.takes_index) blk: {
        const index_val = try self.eval.ctx.intAsValue(
          input.pos, @intCast(i64, index + 1), undefined,
          &self.eval.ctx.types().system.positive.named.data.int);
        break :blk &.{input, try self.eval.ctx.createValueExpr(index_val)};
      } else &.{input};
      return try self.eval.evalCall(self.eval, expr);
    } else return try self.eval.evaluate(input);
  }

  fn map(
             self  : *@This(),
             input : *model.Value,
             index : usize,
             target: anytype,
    comptime pusher: anytype,
  ) !void {
    const expr = if (self.tmp_expr) |existing| existing else blk: {
      const new = try self.eval.ctx.global().create(model.Expression);
      self.tmp_expr = new;
      break :blk new;
    };
    expr.* = .{
      .pos = input.origin,
      .data = .{.value = input},
      .expected_type = try self.eval.ctx.types().valueType(input),
    };
    try pusher(target, try self.call(expr, index));
  }

  fn mapEach(
             self  : *@This(),
             input : *model.Value,
             target: anytype,
    comptime pusher: anytype,
  ) !void {
    // when mapping a concat, the input may be a single value already (?).
    switch (input.data) {
      .concat => |*con| {
        for (con.content.items) |item, index| {
          try self.map(item, index, target, pusher);
        }
      },
      .list => |*lst| {
        for (lst.content.items) |item, index| {
          try self.map(item, index, target, pusher);
        }
      },
      .poison => {},
      .seq => |*seq| {
        for (seq.content.items) |item, index| {
          try self.map(item.content, index, target, pusher);
        }
      },
      else => try self.map(input, 0, target, pusher),
    }
  }
};

fn pushIntoSeq(
  arr : *std.ArrayList(model.Value.Seq.Item),
  item: *model.Value,
) std.mem.Allocator.Error!void {
  return arr.append(.{.content = item, .lf_after = 2});
}

fn evalMap(
  self: *Evaluator,
  map : *model.Expression.Map,
) nyarna.Error!*model.Value {
  const input = try self.evaluate(map.input);
  if (input.data == .poison) {
    return try self.ctx.values.poison(map.expr().pos);
  }
  var ret_inner_type: model.Type = undefined;
  var gen: enum{concat, list, sequence} = undefined;
  switch (map.expr().expected_type) {
    .structural => |strct| switch (strct.*) {
      .concat   => |con| {
        ret_inner_type = con.inner;
        gen = .concat;
      },
      .list     => |lst| {
        ret_inner_type = lst.inner;
        gen = .list;
      },
      .sequence => |seq| {
        // map always generates a sequence with only a direct type.
        std.debug.assert(seq.inner.len == 0);
        ret_inner_type = seq.direct.?;
        gen = .sequence;
      },
      else      => {
        ret_inner_type = map.expr().expected_type;
        gen = .concat;
      },
    },
    .named => {
      ret_inner_type = map.expr().expected_type;
      gen = .concat;
    }
  }
  var caller = (
    try Caller.init(self, map.func, map.expr().pos, ret_inner_type)
  ) orelse return try self.ctx.values.poison(map.expr().pos);
  switch (gen) {
    .concat => {
      var builder =
        ConcatBuilder.init(self.ctx, map.expr().pos, map.expr().expected_type);
      try caller.mapEach(input, &builder, ConcatBuilder.push);
      return try builder.finish();
    },
    .list => {
      const target = try self.ctx.values.list(
        map.expr().pos, &map.expr().expected_type.structural.list);
      try caller.mapEach(
        input, &target.content, std.ArrayList(*model.Value).append);
      return target.value();
    },
    .sequence => {
      const target = try self.ctx.values.seq(
        map.expr().pos, &map.expr().expected_type.structural.sequence);
      try caller.mapEach(
        input, &target.content, pushIntoSeq);
      return target.value();
    },
  }
}

fn evalMatch(
  self : *Evaluator,
  match: *model.Expression.Match,
) nyarna.Error!*model.Value {
  const subject = try self.evaluate(match.subject);
  const s_type = try self.ctx.types().valueType(subject);
  if (s_type.isNamed(.poison)) {
    subject.origin = match.expr().pos;
    return subject;
  }
  if (match.cases.get(s_type.predef())) |case| {
    const frame = try self.setupParameterStackFrame(
      case.container.num_values, case.has_var, case.container.cur_frame);
    case.container.cur_frame = frame;
    defer self.resetStackFrame(
      &case.container.cur_frame, case.container.num_values, case.has_var);
    if (case.has_var) {
      (frame + 1 + case.container.num_values).* = .{.value = subject};
    }
    return self.evaluate(case.expr);
  } else {
    std.debug.panic(
      "unexpected type for match subject: {s}", .{s_type.formatter()});
  }
}

fn evalOutput(
  self: *Evaluator,
  out : *model.Expression.Output,
) nyarna.Error!*model.Value {
  const name = try self.evaluate(out.name);
  const value = try self.evaluate(out.body);
  if (name.data == .poison or value.data == .poison) {
    return try self.ctx.values.poison(out.expr().pos);
  }
  return (
    try self.ctx.values.output(
      out.expr().pos, &name.data.text, out.schema, value)
  ).value();
}

fn evalSequence(
  self : *Evaluator,
  expr : *model.Expression,
  paras: model.Expression.Sequence,
) nyarna.Error!*model.Value {
  const gen_para = switch (expr.expected_type) {
    .structural => |strct| switch (strct.*) {
      .sequence => true,
      else      => false
    },
    else => false
  };
  if (gen_para) {
    var builder = SequenceBuilder.init(self.ctx);
    for (paras) |para| {
      try builder.push(try self.evaluate(para.content), para.lf_after);
    }
    return try builder.finish(expr.pos);
  } else {
    var builder = ConcatBuilder.init(self.ctx, expr.pos, expr.expected_type);
    for (paras) |para, index| {
      const value = try self.evaluate(para.content);
      if (!(try self.ctx.types().valueType(value)).isNamed(.void)) {
        try builder.push(value);
        if (
          index != paras.len - 1 and
          !paras[index + 1].content.expected_type.isNamed(.void)
        ) try builder.pushSpace(para.lf_after);
      }
    }
    return try builder.finish();
  }
}

fn evalVarargs(
  self   : *Evaluator,
  varargs: *model.Expression.Varargs,
) nyarna.Error!*model.Value {
  const list = try self.ctx.values.list(
    varargs.expr().pos, &varargs.expr().expected_type.structural.list);
  for (varargs.items) |*item| {
    const val = try self.evaluate(item.expr);
    if (item.direct) {
      switch (val.data) {
        .poison => {},
        .list => |*inner| {
          for (inner.content.items) |inner_item| {
            try list.content.append(inner_item);
          }
        },
        else => unreachable,
      }
    } else switch (val.data) {
      .poison => {},
      else => try list.content.append(val),
    }
  }
  return list.value();
}

fn pushIntoMap(
  self : *Evaluator,
  map  : *model.Value.HashMap,
  key  : *model.Value,
  value: *model.Value,
) !void {
  const res = try map.items.getOrPut(key);
  if (res.found_existing) {
    var buffer: [64]u8 = undefined;
    const repr = switch (key.data) {
      .text => |*txt| txt.content,
      .int  => |*int| blk: {
        const fmt = int.formatter();
        break :blk std.fmt.bufPrint(&buffer, "{}", .{fmt}) catch unreachable;
      },
      .float => |*fl| blk: {
        const fmt = fl.formatter();
        break :blk std.fmt.bufPrint(&buffer, "{}", .{fmt}) catch unreachable;
      },
      .@"enum" => |*en| en.t.values.entries.items(.key)[en.index],
      else => unreachable,
    };
    self.ctx.logger.DuplicateMappingKey(
      repr, key.origin, res.key_ptr.*.origin);
  } else {
    res.value_ptr.* = value;
  }
}

fn evalVarmap(
  self  : *Evaluator,
  varmap: *model.Expression.Varmap,
) nyarna.Error!*model.Value {
  const map = try self.ctx.values.hashMap(
    varmap.expr().pos, &varmap.expr().expected_type.structural.hashmap);
  for (varmap.items) |item| {
    const val = try self.evaluate(item.value);
    if (val.data == .poison) continue;
    switch (item.key) {
      .direct => {
        var iter = val.data.hashmap.items.iterator();
        while (iter.next()) |entry| {
          try self.pushIntoMap(map, entry.key_ptr.*, entry.value_ptr.*);
        }
      },
      .expr => |key_expr| {
        try self.pushIntoMap(map, try self.evaluate(key_expr), val);
      },
    }
  }
  return map.value();
}

fn evalVarRetr(
  self: *Evaluator,
  retr: *model.Expression.VarRetrieval,
) nyarna.Error!*model.Value {
  const ret = retr.variable.curPtr().*;
  const v_type = try self.ctx.types().valueType(ret);
  if (
    !self.ctx.types().lesserEqual(v_type, retr.variable.spec.t) and
    (!v_type.isNamed(.record) or !retr.variable.spec.t.isNamed(.record) or
     !for (v_type.named.data.record.embeds) |embed| {
      if (embed.t == &retr.variable.spec.t.named.data.record) break true;
     } else false)
  ) {
    if (comptime builtin.cpu.arch != .wasm32 and builtin.cpu.arch != .wasm64) {
      std.debug.print("{}: corrupted stack at {}! stack contents:\n", .{
        retr.expr().pos.formatter(),
        @ptrToInt(retr.variable.container.cur_frame.?) + 1 +
        retr.variable.offset - @ptrToInt(self.ctx.data.stack.ptr)
      });
      const stack_len = (
        @ptrToInt(self.ctx.data.stack_ptr) - @ptrToInt(self.ctx.data.stack.ptr)
      ) / @sizeOf(model.StackItem);
      for (self.ctx.data.stack[0..stack_len]) |item, index| {
        std.debug.print("{}: ", .{index});
        if (
          if (item.frame_ref) |ptr| (
            @ptrToInt(ptr) >= @ptrToInt(self.ctx.data.stack.ptr) and
            @ptrToInt(ptr) < @ptrToInt(self.ctx.data.stack_ptr)
          ) else true
        ) {
          if (item.frame_ref) |ptr| {
            std.debug.print("[ header -> {} ]\n", .{
              @divExact(
                @ptrToInt(ptr) - @ptrToInt(self.ctx.data.stack.ptr),
                @sizeOf(model.StackItem)
              )
            });
          } else {
            std.debug.print("[ header -> null ]\n", .{});
          }
        } else {
          const pos = item.value.origin.formatter();
          const fmt = (try self.ctx.types().valueType(item.value)).formatter();
          std.debug.print("[ {}: {} ]\n", .{pos, fmt});
        }
      }
    }
    std.debug.panic("aborting due to stack corruption", .{});
  }
  return ret;
}

fn evalGenUnary(
           self      : *Evaluator,
  comptime name      : []const u8,
           input     : anytype,
  comptime error_name: []const u8,
) nyarna.Error!*model.Value {
  switch ((try self.evaluate(input.inner)).data) {
    .@"type" => |tv| return try self.ctx.unaryTypeVal(
      name, input.expr().pos, tv.t, input.inner.pos, error_name),
    .poison => return self.ctx.values.poison(input.expr().pos),
    else => unreachable,
  }
}

fn evalGenMap(
  self : *Evaluator,
  input: *model.Expression.tg.HashMap,
) nyarna.Error!*model.Value {
  var t: [2]model.Type = undefined;
  var seen_poison = false;
  for ([_]*model.Expression{input.key, input.value}) |item, index| {
    switch ((try self.evaluate(item)).data) {
      .@"type" => |tv| t[index] = tv.t,
      .poison => seen_poison = true,
      else => unreachable,
    }
  }
  if (!seen_poison) if (try self.ctx.types().hashMap(t[0], t[1])) |mt| {
    return (try self.ctx.values.@"type"(input.expr().pos, mt)).value();
  } else {
    self.ctx.logger.InvalidMappingKeyType(&.{t[0].at(input.key.pos)});
  };
  return self.ctx.values.poison(input.expr().pos);
}

fn evalGenSequence(
  self : *Evaluator,
  input: *model.Expression.tg.Sequence,
) nyarna.Error!*model.Value {
  var builder = Types.SequenceBuilder.init(
    self.ctx.types(), self.ctx.global(), true);
  if (input.direct) |direct| {
    switch ((try self.evaluate(direct)).data) {
      .@"type" => |tv| {
        const st = tv.t.at(direct.pos);
        const res = try builder.push(st, true);
        res.report(st, self.ctx.logger);
      },
      .poison => {},
      else => unreachable,
    }
  }
  for (input.inner) |item| {
    const value = try self.evaluate(item.expr);
    switch (value.data) {
      .poison => {},
      .@"type" => |tv| {
        std.debug.assert(!item.direct);
        const st = tv.t.at(item.expr.pos);
        const res = try builder.push(st, false);
        res.report(st, self.ctx.logger);
      },
      .list => |*lst| {
        std.debug.assert(item.direct);
        for (lst.content.items) |li| {
          const st = li.data.@"type".t.at(li.origin);
          const res = try builder.push(st, false);
          res.report(st, self.ctx.logger);
        }
      },
      else => unreachable,
    }
  }
  const auto_type = if (input.auto) |auto| switch (
    (try self.evaluate(auto)).data
  ) {
    .@"type" => |tv| tv.t.at(auto.pos),
    .poison => null,
    else => unreachable,
  } else null;
  const res = try builder.finish(auto_type, null);
  res.report(auto_type, self.ctx.logger);
  return (try self.ctx.values.@"type"(input.expr().pos, res.t)).value();
}

/// actual evaluation of expressions.
fn doEvaluate(
  self: *Evaluator,
  expr: *model.Expression,
) nyarna.Error!*model.Value {
  return switch (expr.data) {
    .access        => |*access|     self.evalAccess(access),
    .assignment    => |*assignment| self.evalAssignment(assignment),
    .branches      => |*branches|   self.evalBranches(branches),
    .call          => |*call|       return self.evalCall(self, call),
    .concatenation => |concat|      self.evalConcatenation(expr, concat),
    .conversion    => |*convert|    self.evalConversion(convert),
    .ifopt         => |*ifopt|      self.evalIfOpt(ifopt),
    .location      => |*loc|        self.evalLocation(loc),
    .map           => |*map|        self.evalMap(map),
    .match         => |*match|      self.evalMatch(match),
    .output        => |*output|     self.evalOutput(output),
    .sequence      => |seq|         self.evalSequence(expr, seq),
    .tg_concat     => |*tgc|
      self.evalGenUnary("concat", tgc, "InvalidInnerConcatType"),
    .tg_list       => |*tgl|
      self.evalGenUnary("list", tgl, "InvalidInnerListType"),
    .tg_map        => |*tgm| self.evalGenMap(tgm),
    .tg_optional   => |*tgo|
      self.evalGenUnary("optional", tgo, "InvalidInnerOptionalType"),
    .tg_sequence   => |*tsq|        self.evalGenSequence(tsq),
    .value         => |value|       return value,
    .varargs       => |*varargs|    self.evalVarargs(varargs),
    .varmap        => |*varmap|     self.evalVarmap(varmap),
    .var_retrieval => |*var_retr|   self.evalVarRetr(var_retr),
    .void          =>               return self.ctx.values.void(expr.pos),
    .poison        =>               return self.ctx.values.poison(expr.pos),
  };
}

fn toString(self: *Evaluator, input: anytype) ![]u8 {
  const fmt = input.formatter();
  return std.fmt.allocPrint(self.ctx.global(), "{}", .{fmt});
}

fn coerce(
  self         : *Evaluator,
  value        : *model.Value,
  expected_type: model.Type,
) nyarna.Error!*model.Value {
  const value_type = try self.ctx.types().valueType(value);
  if (
    value_type.eql(expected_type) or value_type.isNamed(.poison) or
    Types.containsAst(expected_type)
  ) return value;
  switch (expected_type) {
    .structural => |strct| switch (strct.*) {
      .callable => unreachable, // TODO: implement callable wrapper.
      .concat => |*concat| {
        var cv = try self.ctx.values.concat(value.origin, concat);
        switch (value.data) {
          .void   => {},
          .concat => |*con| for (con.content.items) |item| {
            try cv.content.append(try self.coerce(item, concat.inner));
          },
          .definition, .location, .output, .record, .text, .@"type" => {
            try cv.content.append(try self.coerce(value, concat.inner));
          },
          else => unreachable,
        }
        return cv.value();
      },
      .hashmap => |*map| {
        const coerced = try self.ctx.values.hashMap(value.origin, map);
        var iter = value.data.hashmap.items.iterator();
        while (iter.next()) |entry| {
          const key = try self.coerce(entry.key_ptr.*, map.key);
          const val = try self.coerce(entry.value_ptr.*, map.value);
          try coerced.items.put(key, val);
        }
        return coerced.value();
      },
      // can never directly be the expected type but can exist as inner type.
      .intersection => |*inter| {
        if (value_type.isScalar()) {
          return try self.coerce(value, inter.scalar.?);
        }
        std.debug.assert(
          for (inter.types) |t| {
            if (value_type.eql(t)) break true;
          } else false
        );
        return value;
      },
      // can never be the expected type of a coercion.
      .optional => unreachable,
      .list => |*list| {
        const coerced = try self.ctx.values.list(value.origin, list);
        for (value.data.list.content.items) |item| {
          try coerced.content.append(try self.coerce(item, list.inner));
        }
        return coerced.value();
      },
      .sequence => |*seq| {
        var lv = try self.ctx.values.seq(value.origin, seq);
        if (!value_type.isNamed(.void)) {
          switch (value.data) {
            .seq => |input_seq| {
              for (input_seq.content.items) |item| {
                const item_type = try self.ctx.types().valueType(item.content);
                if (seq.direct) |direct| if (
                  self.ctx.types().lesserEqual(item_type, direct)
                ) {
                  try lv.content.append(.{
                    .content  = try self.coerce(item.content, direct),
                    .lf_after = item.lf_after,
                  });
                  continue;
                };
                std.debug.assert(for (seq.inner) |cur| {
                  if (cur.typedef().eql(item_type)) break true;
                } else false);
                try lv.content.append(item);
              }
            },
            else => {
              const seq_value = blk: {
                if (seq.direct) |direct| {
                  if (self.ctx.types().lesserEqual(value_type, direct)) {
                    break :blk try self.coerce(value, direct);
                  }
                }
                std.debug.assert(for (seq.inner) |cur| {
                  if (cur.typedef().eql(value_type)) break true;
                } else false);
                break :blk value;
              };
              try lv.content.append(.{.content = seq_value, .lf_after = 0});
            }
          }
        }
        return lv.value();
      },
    },
    .named => |named| switch (named.data) {
      .poison => return value,
      // for .literal, this can only be a coercion from .space.
      // for .textual, this could be a coercion from any scalar type.
      .literal, .textual => {
        const content = switch (value.data) {
          .text    => |*text_val|  text_val.content,
          .int     => |*int_val|   try self.toString(int_val),
          .float   => |*float_val| try self.toString(float_val),
          .@"enum" => |ev|         ev.t.values.entries.items(.key)[ev.index],
          .void    => "",
          // type checking ensures this never happens
          else => unreachable,
        };
        return (
          switch (named.data) {
            .textual => |*txt| (
              try self.ctx.textFromString(value.origin, content, txt)
            ) orelse return self.ctx.values.poison(value.origin),
            else =>
              try self.ctx.values.textScalar(
                value.origin, expected_type, content)
          }
        ).value();
      },
      .record => |*rec| {
        std.debug.assert(for (value_type.named.data.record.embeds) |embed| {
          if (embed.t == rec) break true;
        } else false);
        return value;
      },
      // other coercions can never happen.
      else => {
        const p = value.origin.formatter();
        const v = value_type.formatter();
        const e = expected_type.formatter();
        std.debug.panic("{}: coercion from {} to {} requested, which is illegal",
          .{p, v, e});
      }
    },
  }
}

/// evaluate the expression, and coerce the resulting value according to the
/// expression's expected type [8.3].
pub fn evaluate(
  self: *Evaluator,
  expr: *model.Expression,
) nyarna.Error!*model.Value {
  const res = try self.doEvaluate(expr);
  const expected_type = self.ctx.types().expectedType(
    try self.ctx.types().valueType(res), expr.expected_type);
  return try self.coerce(res, expected_type);
}

pub fn processBackends(
  self     : *Evaluator,
  container: *nyarna.DocumentContainer,
) !void {
  const call_expr = try self.ctx.global().create(model.Expression);
  call_expr.* = .{
    .pos = model.Position.intrinsic(),
    .data = .{.call = .{
      .ns = 0,
      .target = undefined,
      .exprs = undefined,
    }},
    .expected_type = undefined,
  };
  const call = &call_expr.data.call;
  var i: usize = 0;
  while (i < container.documents.items.len) : (i += 1) {
    const doc = container.documents.items[i];
    if (doc.schema) |schema| if (schema.backend) |backend| {
      // generate the record value holding the input document's content and
      // metadata.
      const doc_val = try self.ctx.values.record(model.Position.intrinsic(),
        &backend.callable.sig.parameters[0].spec.t.named.data.record);
      doc_val.fields[0] = doc.name.value();
      doc_val.fields[1] = doc.body;

      // now, call the backend
      call.target = try self.ctx.createValueExpr((
        try self.ctx.values.funcRef(model.Position.intrinsic(), backend)
      ).value());
      call.exprs = &.{try self.ctx.createValueExpr(doc_val.value())};
      call_expr.expected_type = backend.callable.sig.returns;
      const outputs = try self.evalCall(self, call);

      switch (outputs.data) {
        .concat => |*con| for (con.content.items) |item| {
          try container.documents.append(self.ctx.global(), &item.data.output);
        },
        .poison => {},
        else    => unreachable,
      }
    };
  }
}

const ConcatBuilder = struct {
  const MoreText = struct {
    pos    : model.Position,
    content: std.ArrayListUnmanaged(u8) = .{},
  };

  cur          : ?*model.Value                = null,
  cur_items    : ?std.ArrayList(*model.Value) = null,
  ctx          : nyarna.Context,
  pos          : model.Position,
  inner_type   : model.Type,
  expected_type: model.Type,
  scalar_type  : ?model.Type,
  state: union(enum) {
    initial,
    first_text: *model.Value,
    more_text: MoreText,
  },

  fn init(
    ctx          : nyarna.Context,
    pos          : model.Position,
    expected_type: model.Type,
  ) ConcatBuilder {
    return .{
      .ctx           = ctx,
      .pos           = pos,
      .inner_type    = ctx.types().every(),
      .expected_type = expected_type,
      .scalar_type   = nyarna.Types.containedScalar(expected_type) orelse null,
      .state = .initial,
    };
  }

  fn emptyConcat(self: *ConcatBuilder) !*model.Value.Concat {
    return self.ctx.values.concat(
      self.pos, &self.expected_type.structural.concat);
  }

  fn concatWith(
    self     : *ConcatBuilder,
    first_val: *model.Value,
  ) !*model.Value.Concat {
    const cval = try self.emptyConcat();
    try cval.content.append(first_val);
    return cval;
  }

  fn initList(self: *ConcatBuilder, first_val: *model.Value) !void {
    self.cur_items = blk: {
      var list = std.ArrayList(*model.Value).init(self.ctx.global());
      try list.append(first_val);
      break :blk list;
    };
  }

  fn enqueue(self: *ConcatBuilder, item: *model.Value) !void {
    std.debug.assert(item.data != .seq);
    if (self.cur) |first_val| {
      try self.initList(first_val);
      self.cur = null;
    }
    const vt = try self.ctx.types().valueType(item);
    const new_type = try self.ctx.types().sup(self.inner_type, vt);
    self.inner_type = new_type;

    if (self.cur_items) |*content| try content.append(item)
    else self.cur = item;
  }

  fn finishText(self: *ConcatBuilder, more: *const MoreText) !void {
    const scalar_val = try self.ctx.values.textScalar(
      more.pos, self.scalar_type.?, more.content.items);
    try self.enqueue(scalar_val.value());
  }

  pub fn push(self: *ConcatBuilder, item: *model.Value) !void {
    if (item.data == .void) return;
    const value = switch (item.data) {
      .text => |*txt| if (self.scalar_type) |stype| (
        try self.ctx.evaluator().coerce(item, stype)
      ) else {
        std.debug.assert(txt.t.isNamed(.space));
        return;
      },
      .int, .float, .@"enum" =>
        try self.ctx.evaluator().coerce(item, self.scalar_type.?),
      else => item,
    };
    switch (self.state) {
      .initial => {
        if (value.data == .text) {
          self.state = .{.first_text = value};
        } else try self.enqueue(value);
      },
      .first_text => |start| {
        if (value.data == .text) {
          self.state = .{.more_text = .{.pos = start.origin}};
          try self.state.more_text.content.appendSlice(
            self.ctx.global(), start.data.text.content);
          try self.state.more_text.content.appendSlice(
            self.ctx.global(), value.data.text.content);
          self.state.more_text.pos.end = value.origin.end;
        } else {
          try self.enqueue(start);
          try self.enqueue(value);
          self.state = .initial;
        }
      },
      .more_text => |*more| {
        if (value.data == .text) {
          try more.content.appendSlice(
            self.ctx.global(), value.data.text.content);
          more.pos.end = value.origin.end;
        } else {
          try self.finishText(more);
          try self.enqueue(value);
          self.state = .initial;
        }
      }
    }
  }

  pub fn pushSpace(self: *ConcatBuilder, lf_count: usize) !void {
    if (self.scalar_type == null) return;
    switch (self.state) {
      .initial => {
        const content = try self.ctx.evaluator().lineFeeds(lf_count);
        self.state = .{.first_text = (
          try self.ctx.values.textScalar(
            model.Position.intrinsic(), self.ctx.types().space(), content
          )).value()
        };
      },
      .first_text => |start| {
        self.state = .{.more_text = .{.pos = start.origin}};
        const content = &self.state.more_text.content;
        try content.appendSlice(self.ctx.global(), start.data.text.content);
        try content.resize(self.ctx.global(), content.items.len + lf_count);
        std.mem.set(u8, content.items[content.items.len - lf_count..], '\n');
      },
      .more_text => |*more| {
        const content = &more.content;
        try content.resize(self.ctx.global(), content.items.len + lf_count);
        std.mem.set(u8, content.items[content.items.len - lf_count..], '\n');
      },
    }
  }

  fn finish(self: *ConcatBuilder) !*model.Value {
    switch (self.state) {
      .initial => {},
      .first_text => |first| try self.enqueue(first),
      .more_text => |*more| try self.finishText(more),
    }
    if (self.cur) |single| if (self.expected_type.isStruc(.concat)) {
      try self.initList(single);
    };
    if (self.cur_items) |cval| {
      if (self.inner_type.isNamed(.poison)) {
        return try self.ctx.values.poison(self.pos);
      }
      const concat = try self.ctx.global().create(model.Value);
      const t = (try self.ctx.types().concat(self.inner_type)).?;
      std.debug.assert(t.isStruc(.concat));
      concat.* = .{
        .origin = self.pos,
        .data   = .{.concat = .{
          .t       = &t.structural.concat,
          .content = cval,
        }},
      };
      return concat;
    } else if (self.cur) |single| {
      return single;
    } else {
      return if (self.expected_type.isStruc(.concat)) (
        try self.ctx.values.concat(
          self.pos, &self.expected_type.structural.concat)
      ).value() else if (self.expected_type.isNamed(.void)) (
        try self.ctx.values.void(self.pos)
      ) else (
        try self.ctx.values.textScalar(self.pos, self.scalar_type.?, "")
      ).value();
    }
  }
};

const SequenceBuilder = struct {
  content  : std.ArrayList(model.Value.Seq.Item),
  t_builder: Types.SequenceBuilder,
  ctx      : nyarna.Context,
  is_poison: bool = false,

  pub fn init(ctx: nyarna.Context) SequenceBuilder {
    return .{
      .content   = std.ArrayList(model.Value.Seq.Item).init(ctx.global()),
      .t_builder = Types.SequenceBuilder.init(ctx.types(), ctx.global(), true),
      .ctx       = ctx,
    };
  }

  fn enqueue(self: *@This(), item: model.Value.Seq.Item) !void {
    try self.content.append(item);
    const item_type = try self.ctx.types().valueType(item.content);
    const res =
      try self.t_builder.push(item_type.at(item.content.origin), false);
    std.debug.assert(res == .success);
  }

  pub fn push(
    self: *@This(),
    value: *model.Value,
    lf_after: usize,
  ) nyarna.Error!void {
    switch (value.data) {
      .seq => |*children| {
        for (children.content.items) |*item| {
          try self.push(item.content, item.lf_after);
        }
      },
      .void => {},
      .poison => self.is_poison = true,
      else => try self.enqueue(.{.content = value, .lf_after = lf_after})
    }
  }

  pub fn finish(self: *@This(), pos: model.Position) !*model.Value {
    const res = try self.t_builder.finish(null, null);
    const ret = try self.ctx.global().create(model.Value);
    ret.* = .{
      .origin = pos,
      .data = if (res.t.isNamed(.poison)) .poison else .{
        .seq = .{
          .content = self.content,
          .t = &res.t.structural.sequence,
        },
      },
    };
    return ret;
  }
};