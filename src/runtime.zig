const std = @import("std");
const nyarna = @import("nyarna.zig");
const model = nyarna.model;
const types = nyarna.types;
const Interpreter = @import("interpret.zig").Interpreter;

/// evaluates expressions and returns values.
pub const Evaluator = struct {
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
    self: *Evaluator,
    num_variables: usize,
    prev_frame: ?[*]model.StackItem
  ) ![*]model.StackItem {
    const data = self.ctx.data;
    if (
      (@ptrToInt(data.stack_ptr) - @ptrToInt(data.stack.ptr))
      / @sizeOf(model.StackItem) + num_variables > data.stack.len
    ) {
      return nyarna.Error.nyarna_stack_overflow;
    }
    const ret = data.stack_ptr;
    //std.debug.print("[stack] {} frame with {} parameters\n",
    //  .{@ptrToInt(ret), sig.parameters.len});
    data.stack_ptr += num_variables + 1;
    ret.* = .{.frame_ref = prev_frame};
    return ret;
  }

  fn setupParameterStackFrame(
    self: *Evaluator,
    sig: *const model.Signature,
    ns_dependent: bool,
    prev_frame: ?[*]model.StackItem,
  ) ![*]model.StackItem {
    const num_params =
      sig.parameters.len + if (ns_dependent) @as(usize, 1) else 0;
    return self.allocateStackFrame(num_params, prev_frame);
  }

  pub fn resetStackFrame(
    self: *Evaluator,
    frame_ptr: *?[*]model.StackItem,
    num_variables: usize,
    ns_dependent: bool,
  ) void {
    //std.debug.print("[stack] {} pop\n", .{@ptrToInt(frame_ptr.*.?)});
    frame_ptr.* = frame_ptr.*.?[0].frame_ref;
    self.ctx.data.stack_ptr -= num_variables + 1;
    if (ns_dependent) self.ctx.data.stack_ptr -= 1;
  }

  pub fn fillParameterStackFrame(
    self: *Evaluator,
    exprs: []*model.Expression,
    frame: [*]model.StackItem,
  ) !bool {
    var seen_poison = false;
    for (exprs) |expr, i| {
      const val = try self.evaluate(expr);
      //std.debug.print(
      //  "[stack] {} <- {s}\n", .{@ptrToInt(&frame[i]), @tagName(val.data)});
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
    self: *Evaluator,
    comptime ImplCtx: type,
    index: usize,
  ) FnTypeForCtx(ImplCtx) {
    return switch (ImplCtx) {
      *Evaluator => self.ctx.data.builtin_registry.items[index],
      *Interpreter => self.ctx.data.keyword_registry.items[index],
      else => unreachable
    };
  }

  fn poison(
    impl_ctx: anytype,
    pos: model.Position,
  ) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    switch (@TypeOf(impl_ctx)) {
      *Evaluator => return try impl_ctx.ctx.values.poison(pos),
      *Interpreter => return impl_ctx.node_gen.poison(pos),
      else => unreachable,
    }
  }

  fn callConstructor(
    self: *Evaluator,
    impl_ctx: anytype,
    call: *model.Expression.Call,
    constr: nyarna.types.Constructor,
  ) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    const callable = constr.callable.?;
    const target_impl =
      self.registeredFnForCtx(@TypeOf(impl_ctx), constr.impl_index);
    std.debug.assert(
      call.exprs.len == callable.sig.parameters.len);
    var frame: ?[*]model.StackItem = try self.setupParameterStackFrame(
      callable.sig, false, null);
    defer self.resetStackFrame(&frame, callable.sig.parameters.len, false);
    return if (try self.fillParameterStackFrame(
        call.exprs, frame.? + 1))
      target_impl(impl_ctx, call.expr().pos, frame.? + 1)
    else poison(impl_ctx, call.expr().pos);
  }

  fn evalCall(
    self: *Evaluator,
    impl_ctx: anytype,
    call: *model.Expression.Call,
  ) nyarna.Error!RetTypeForCtx(@TypeOf(impl_ctx)) {
    const target = try self.evaluate(call.target);
    switch (target.data) {
      .funcref => |fr| {
        switch (fr.func.data) {
          .ext => |*ef| {
            const target_impl =
              self.registeredFnForCtx(@TypeOf(impl_ctx), ef.impl_index);
            std.debug.assert(
              call.exprs.len == fr.func.sig().parameters.len);
            fr.func.variables.cur_frame = try self.setupParameterStackFrame(
              fr.func.sig(), ef.ns_dependent, fr.func.variables.cur_frame);
            var frame_ptr = fr.func.argStart();
            var ns_val: model.Value = undefined;
            if (ef.ns_dependent) {
              ns_val = .{
                .data = .{
                  .number = .{
                    .t = undefined, // not accessed, since the wrapper assumes
                                    // that the value adheres to the target
                                    // type's constraints
                    .content = call.ns,
                  },
                },
                .origin = undefined,
              };
              frame_ptr.* = .{.value = &ns_val};
              frame_ptr += 1;
            }
            defer self.resetStackFrame(
              &fr.func.variables.cur_frame, fr.func.sig().parameters.len,
              ef.ns_dependent);
            if (fr.func.name) |fname| if (fname.parent_type) |ptype| {
              self.target_type = ptype;
            };
            return if (try self.fillParameterStackFrame(
                call.exprs, frame_ptr))
              target_impl(impl_ctx, call.expr().pos, fr.func.argStart())
            else poison(impl_ctx, call.expr().pos);
          },
          .ny => |*nf| {
            fr.func.variables.cur_frame = try self.setupParameterStackFrame(
              fr.func.sig(), false, fr.func.variables.cur_frame);
            defer self.resetStackFrame(
              &fr.func.variables.cur_frame, fr.func.sig().parameters.len, false
            );
            if (try self.fillParameterStackFrame(
                call.exprs, fr.func.argStart())) {
              const val = try self.evaluate(nf.body);
              return switch (@TypeOf(impl_ctx)) {
                *Evaluator => val,
                *Interpreter => val.data.ast.root,
                else => unreachable,
              };
            } else return poison(impl_ctx, call.expr().pos);
          },
        }
      },
      .@"type" => |tv| {
        if (@TypeOf(impl_ctx) == *Evaluator) switch (tv.t) {
          .instantiated => |inst| switch (inst.data) {
            .record => |*rec| {
              std.debug.assert(
                call.exprs.len == rec.constructor.sig.parameters.len);
              var frame: ?[*]model.StackItem =
                try self.setupParameterStackFrame(
                  rec.constructor.sig, false, null);
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
        const constr = try self.ctx.types().typeConstructor(tv.t);
        self.target_type = tv.t;
        return self.callConstructor(impl_ctx, call, constr);
      },
      .prototype => |pv| {
        const constr = self.ctx.types().prototypeConstructor(pv.pt);
        return self.callConstructor(impl_ctx, call, constr);
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
    self: *Evaluator,
    intpr: *Interpreter,
    call: *model.Expression.Call,
  ) !*model.Node {
    return self.evalCall(intpr, call);
  }

  fn evalAccess(
    self: *Evaluator,
    access: *model.Expression.Access,
  ) nyarna.Error!*model.Value {
    var cur = try self.evaluate(access.subject);
    for (access.path) |index| {
      cur = switch (cur.data) {
        .record => |*record| record.fields[index],
        .list   => |*list|   list.content.items[index],
        else    => unreachable,
      };
    }
    return cur;
  }

  fn evalAssignment(
    self: *Evaluator,
    ass: *model.Expression.Assignment,
  ) nyarna.Error!*model.Value {
    var cur_ptr = ass.target.curPtr();
    for (ass.path) |index| {
      cur_ptr = switch (cur_ptr.*.data) {
        .record => |*record| &record.fields[index],
        .list   => |*list|   &list.content.items[index],
        else => unreachable,
      };
    }
    cur_ptr.* = try self.evaluate(ass.rexpr);
    return try model.Value.create(self.ctx.global(), ass.expr().pos, .void);
  }

  fn evalBranches(
    self: *Evaluator,
    br: *model.Expression.Branches,
  ) nyarna.Error!*model.Value {
    var condition = try self.evaluate(br.condition);
    if ((try self.ctx.types().valueType(condition)).isInst(.poison)) {
      return model.Value.create(self.ctx.global(), br.expr().pos, .poison);
    }
    return self.evaluate(br.branches[condition.data.@"enum".index]);
  }

  fn evalConcatenation(
    self: *Evaluator,
    expr: *model.Expression,
    concat: model.Expression.Concatenation,
  ) nyarna.Error!*model.Value {
    var builder = ConcatBuilder.init(
      self.ctx, expr.pos, expr.expected_type);
    for (concat) |item| try builder.push(try self.evaluate(item));
    return try builder.finish();
  }

  fn convertIntoConcat(
    self: *Evaluator,
    value: *model.Value,
    into: *ConcatBuilder,
  ) nyarna.Error!void {
    switch (value.data) {
      .concat => |*vcon| {
        for (vcon.content.items) |item| try self.convertIntoConcat(item, into);
      },
      .text, .number, .float, .@"enum", .record, .void => {
        try into.push(try self.doConvert(value, into.scalar_type));
      },
      .para => |*para| {
        for (para.content.items) |p, index| {
          try self.convertIntoConcat(p.content, into);
          if (index != para.content.items.len - 1) {
            try into.pushSpace(p.lf_after);
          }
        }
      },
      else => unreachable,
    }
  }

  fn doConvert(
    self: *Evaluator,
    value: *model.Value,
    to: model.Type,
  ) nyarna.Error!*model.Value {
    const from = try self.ctx.types().valueType(value);
    if (from.isInst(.poison)) return value;
    if (self.ctx.types().lesserEqual(from, to)) {
      return try self.coerce(value, to);
    }
    switch (to) {
      .instantiated => |inst| switch (inst.data) {
        .literal, .space, .raw => {
          std.debug.assert(from.isInst(.void));
          return (try self.ctx.values.textScalar(value.origin, to, "")).value();
        },
        .textual => |*txt| {
          const input = switch (value.data) {
            .void => "",
            .text => |*intxt| intxt.content,
            .@"enum" => |*e| e.t.values.keys()[e.index],
            else => unreachable,
          };
          return if (
            try self.ctx.textFromString(value.origin, input, txt)
          ) |nv| nv.value() else try self.ctx.values.poison(value.origin);
        },
        else => unreachable,
      },
      .structural => |struc| switch (struc.*) {
        .callable => unreachable,
        .concat => {
          var builder = ConcatBuilder.init(self.ctx, value.origin, to);
          try self.convertIntoConcat(value, &builder);
          return try builder.finish();
        },
        .intersection => unreachable,
        .list => |*lst| {
          const ret = try self.ctx.values.list(value.origin, lst);
          for (value.data.list.content.items) |item| {
            try ret.content.append(try self.doConvert(item, lst.inner));
          }
          return ret.value();
        },
        .map => |*map| {
          const ret = try self.ctx.values.map(value.origin, map);
          var iter = value.data.map.items.iterator();
          while (iter.next()) |entry| {
            const res = try ret.items.getOrPut(
              try self.doConvert(entry.key_ptr.*, map.key));
            std.debug.assert(!res.found_existing);
            res.value_ptr.* = try self.doConvert(entry.value_ptr.*, map.value);
          }
          return ret.value();
        },
        .optional => |*opt| return self.doConvert(value, opt.inner),
        .paragraphs => |*paragraphs| {
          _ = paragraphs;
          unreachable; // TODO
        }
      }
    }
  }

  fn evalConversion(
    self: *Evaluator,
    convert: *model.Expression.Conversion,
  ) nyarna.Error!*model.Value {
    const inner_val = try self.evaluate(convert.inner);
    return self.doConvert(inner_val, convert.target_type);
  }

  fn evalLocation(
    self: *Evaluator,
    loc: *model.Expression.Location,
  ) nyarna.Error!*model.Value {
    const ltype = if (loc.@"type") |t| switch ((try self.evaluate(t)).data) {
      .@"type" => |tv| tv.t,
      .poison => self.ctx.types().poison(),
      else => unreachable
    } else if (loc.default) |default| default.expected_type else blk: {
      self.ctx.logger.MissingSymbolType(loc.expr().pos);
      break :blk self.ctx.types().poison();
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
      if (!ltype.isInst(.poison)) {
        if (add.varmap) |varmap| if (!ltype.isStruc(.map)) {
          self.ctx.logger.VarmapRequiresMap(
            varmap, &[_]model.Type{ltype});
          add.varmap = null;
        };
        if (add.varargs) |varargs| if (!ltype.isStruc(.list)) {
          self.ctx.logger.VarargsRequiresList(
            varargs, &[_]model.Type{ltype});
          add.varargs = null;
        };
        if (add.borrow) |borrow| if (
          !switch (ltype) {
            .structural => |struc| switch (struc.*) {
              .list, .concat, .paragraphs, .callable => true,
              else => false,
            },
            .instantiated => |inst| switch (inst.data) {
              .record, .prototype => true,
              else => false,
            },
          }
        ) {
          self.ctx.logger.BorrowRequiresRef(
            borrow, &[_]model.Type{ltype});
          add.borrow = null;
        };
      }
    }
    const name = switch ((try self.evaluate(loc.name)).data) {
      .text => |*txt| txt,
      .poison => return try self.ctx.values.poison(loc.expr().pos),
      else => unreachable,
    };
    const loc_val = try self.ctx.values.location(loc.expr().pos, name, ltype);
    loc_val.default = loc.default;
    loc_val.primary = if (loc.additionals) |add| add.primary else null;
    loc_val.varargs = if (loc.additionals) |add| add.varargs else null;
    loc_val.varmap  = if (loc.additionals) |add| add.varmap  else null;
    loc_val.borrow =  if (loc.additionals) |add| add.borrow  else null;
    loc_val.header  = if (loc.additionals) |add| add.header  else null;
    return loc_val.value();
  }

  fn evalParagraphs(
    self: *Evaluator,
    expr: *model.Expression,
    paras: model.Expression.Paragraphs,
  ) nyarna.Error!*model.Value {
    const gen_para = switch (expr.expected_type) {
      .structural => |strct| switch (strct.*) {
        .paragraphs => true,
        else => false
      },
      else => false
    };
    if (gen_para) {
      var builder = ParagraphsBuilder.init(self.ctx);
      for (paras) |para| {
        try builder.push(try self.evaluate(para.content), para.lf_after);
      }
      return try builder.finish(expr.pos);
    } else {
      var builder = ConcatBuilder.init(self.ctx, expr.pos, expr.expected_type);
      for (paras) |para, index| {
        const value = try self.evaluate(para.content);
        if (!(try self.ctx.types().valueType(value)).isInst(.void)) {
          try builder.push(value);
          if (
            index != paras.len - 1 and
            !paras[index + 1].content.expected_type.isInst(.void)
          ) try builder.pushSpace(para.lf_after);
        }
      }
      return try builder.finish();
    }
  }

  fn evalVarargs(
    self: *Evaluator,
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

  fn evalGenUnary(
    self: *Evaluator,
    comptime name: []const u8,
    input: anytype,
    comptime error_name: []const u8,
  ) nyarna.Error!*model.Value {
    switch ((try self.evaluate(input.inner)).data) {
      .@"type" => |tv| return try self.ctx.unaryTypeVal(
        name, input.expr().pos, tv.t, input.inner.pos, error_name),
      .poison => return self.ctx.values.poison(input.expr().pos),
      else => unreachable,
    }
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
      .location      => |*loc|        self.evalLocation(loc),
      .value         => |value|       return value,
      .paragraphs    => |paras|       self.evalParagraphs(expr, paras),
      .tg_concat     => |*tgc|
        self.evalGenUnary("concat", tgc, "InvalidInnerConcatType"),
      .tg_list       => |*tgl|
        self.evalGenUnary("list", tgl, "InvalidInnerListType"),
      .tg_optional   => |*tgo|
        self.evalGenUnary("optional", tgo, "InvalidInnerOptionalType"),
      .varargs       => |*varargs|    self.evalVarargs(varargs),
      .var_retrieval => |*var_retr|   var_retr.variable.curPtr().*,
      .poison        =>               return self.ctx.values.poison(expr.pos),
      .void          =>               return self.ctx.values.void(expr.pos),
    };
  }

  inline fn toString(self: *Evaluator, input: anytype) ![]u8 {
    return std.fmt.allocPrint(self.ctx.global(), "{}", .{input});
  }

  fn coerce(
    self: *Evaluator,
    value: *model.Value,
    expected_type: model.Type,
  ) std.mem.Allocator.Error!*model.Value {
    const value_type = try self.ctx.types().valueType(value);
    if (value_type.eql(expected_type) or value_type.isInst(.poison)) {
      return value;
    }
    switch (expected_type) {
      .structural => |strct| switch (strct.*) {
        // these are virtual types and thus can never be the expected type.
        .optional, .intersection => unreachable,
        .concat => |*concat| {
          var cv = try self.ctx.values.concat(value.origin, concat);
          if (!value_type.isInst(.void)) {
            const inner_value = try self.coerce(value, concat.inner);
            try cv.content.append(inner_value);
          }
          return cv.value();
        },
        .paragraphs => |*para| {
          var lv = try self.ctx.values.para(value.origin, para);
          if (!value_type.isInst(.void)) {
            const para_value = for (para.inner) |cur| {
              if (self.ctx.types().lesserEqual(value_type, cur))
                break try self.coerce(value, cur);
            } else unreachable;
            try lv.content.append(.{.content = para_value, .lf_after = 0});
          }
          return lv.value();
        },
        .list => |*list| {
          const coerced = try self.ctx.values.list(value.origin, list);
          for (value.data.list.content.items) |item| {
            try coerced.content.append(try self.coerce(item, list.inner));
          }
          return coerced.value();
        },
        .map => |*map| {
          const coerced = try self.ctx.values.map(value.origin, map);
          var iter = value.data.map.items.iterator();
          while (iter.next()) |entry| {
            const key = try self.coerce(entry.key_ptr.*, map.key);
            const val = try self.coerce(entry.value_ptr.*, map.value);
            try coerced.items.put(key, val);
          }
          return coerced.value();
        },
        .callable => unreachable, // TODO: implement callable wrapper.
      },
      .instantiated => |inst| switch (inst.data) {
        .tenum => unreachable, // TODO: implement enums being coerced to Identifier.
        .poison => return value,
        // for .literal, this can only be a coercion from .space.
        // for .raw, this could be a coercion from any scalar type.
        .literal, .raw => {
          const content = switch (value.data) {
            .text => |*text_val| text_val.content,
            .number => |*num_val| try self.toString(num_val.content),
            .float => |*float_val| try switch (float_val.t.precision) {
              .half => self.toString(float_val.content.half),
              .single => self.toString(float_val.content.single),
              .double => self.toString(float_val.content.double),
              .quadruple, .octuple =>
                self.toString(float_val.content.quadruple),
            },
            .@"enum" => |ev| ev.t.values.entries.items(.key)[ev.index],
            // type checking ensures this never happens
            else => unreachable,
          };
          return model.Value.create(
            self.ctx.global(), value.origin,
            model.Value.TextScalar{.t = expected_type, .content = content});
        },
        // other coercions can never happen.
        else => {
          const v = value_type.formatter();
          const e = expected_type.formatter();
          std.debug.panic("coercion from {} to {} requested, which is illegal",
            .{v, e});
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

  /// evaluates the root module of the current document. Allocates all global
  /// variables on the stack, then evaluates the root expression of the given
  /// module.
  pub fn evaluateRootModule(
    self: *Evaluator,
    module: *model.Module,
  ) nyarna.Error!*model.Value {
    // allocate all global variables
    var num_globals: usize = 0;
    for (self.ctx.data.known_modules.values()) |entry| {
      num_globals += entry.loaded.container.num_values;
    }
    var frame: ?[*]model.StackItem =
      try self.allocateStackFrame(num_globals, null);
    defer self.resetStackFrame(&frame, num_globals, false);
    for (self.ctx.data.known_modules.values()) |entry| {
      const container = entry.loaded.container;
      container.cur_frame = frame;
    }
    return self.evaluate(module.root);
  }
};

const ConcatBuilder = struct {
  const MoreText = struct {
    pos: model.Position,
    content: std.ArrayListUnmanaged(u8) = .{},
  };

  cur: ?*model.Value,
  cur_items: ?std.ArrayList(*model.Value),
  ctx: nyarna.Context,
  pos: model.Position,
  inner_type: model.Type,
  expected_type: model.Type,
  scalar_type: model.Type,
  state: union(enum) {
    initial,
    first_text: *model.Value,
    more_text: MoreText,
  },

  fn init(
    ctx: nyarna.Context,
    pos: model.Position,
    expected_type: model.Type,
  ) ConcatBuilder {
    return .{
      .cur = null,
      .cur_items = null,
      .ctx = ctx,
      .pos = pos,
      .inner_type = ctx.types().every(),
      .expected_type = expected_type,
      .scalar_type =
        nyarna.types.containedScalar(expected_type) orelse undefined,
      .state = .initial,
    };
  }

  fn emptyConcat(self: *ConcatBuilder) !*model.Value.Concat {
    return self.ctx.values.concat(
      self.pos, &self.expected_type.structural.concat);
  }

  fn concatWith(
    self: *ConcatBuilder,
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
    std.debug.assert(item.data != .para); // TODO
    if (self.cur) |first_val| {
      try self.initList(first_val);
      self.cur = null;
    }
    self.inner_type = try self.ctx.types().sup(
      self.inner_type, try self.ctx.types().valueType(item));

    if (self.cur_items) |*content| try content.append(item)
    else self.cur = item;
  }

  fn finishText(self: *ConcatBuilder, more: *const MoreText) !void {
    const scalar_val = try self.ctx.values.textScalar(
      more.pos, self.scalar_type, more.content.items);
    try self.enqueue(scalar_val.value());
  }

  pub fn push(self: *ConcatBuilder, item: *model.Value) !void {
    if (item.data == .void) return;
    const value = switch (item.data) {
      .text, .number, .float, .@"enum" =>
        try self.ctx.evaluator().coerce(item, self.scalar_type),
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
      if (self.inner_type.isInst(.poison)) {
        return try self.ctx.values.poison(self.pos);
      }
      const concat = try self.ctx.global().create(model.Value);
      const t = (try self.ctx.types().concat(self.inner_type)).?;
      std.debug.assert(t.isStruc(.concat));
      concat.* = .{
        .origin = self.pos,
        .data = .{.concat = .{.t = &t.structural.concat, .content = cval}},
      };
      return concat;
    } else if (self.cur) |single| {
      return single;
    } else {
      return if (self.expected_type.isStruc(.concat))
        (try self.ctx.values.concat(
          self.pos, &self.expected_type.structural.concat)).value()
      else if (self.expected_type.isInst(.void)) try
        model.Value.create(self.ctx.global(), self.pos, .void)
      else blk: {
        std.debug.assert(
          nyarna.types.containedScalar(self.expected_type) != null);
        break :blk (try self.ctx.values.textScalar(
          self.pos, self.scalar_type, "")).value();
      };
    }
  }
};

const ParagraphsBuilder = struct {
  content: std.ArrayList(model.Value.Para.Item),
  t_builder: types.ParagraphTypeBuilder,
  ctx: nyarna.Context,
  is_poison: bool,

  pub fn init(ctx: nyarna.Context) ParagraphsBuilder {
    return .{
      .content = std.ArrayList(model.Value.Para.Item).init(ctx.global()),
      .t_builder = types.ParagraphTypeBuilder.init(ctx.types(), true),
      .ctx = ctx, .is_poison = false,
    };
  }

  fn enqueue(self: *@This(), item: model.Value.Para.Item) !void {
    try self.content.append(item);
    const item_type = try self.ctx.types().valueType(item.content);
    try self.t_builder.push(item_type);
  }

  pub fn push(
    self: *@This(),
    value: *model.Value,
    lf_after: usize,
  ) nyarna.Error!void {
    switch (value.data) {
      .para => |*children| {
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
    const ret_t = (try self.t_builder.finish()).resulting_type;
    const ret = try self.ctx.global().create(model.Value);
    ret.* = .{
      .origin = pos,
      .data = if (ret_t.isInst(.poison)) .poison else .{
        .para = .{
          .content = self.content,
          .t = &ret_t.structural.paragraphs,
        },
      },
    };
    return ret;
  }
};