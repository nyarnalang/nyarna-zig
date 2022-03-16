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
  target_type: model.Type = undefined,

  fn setupParameterStackFrame(
    self: *Evaluator,
    sig: *const model.Signature,
    ns_dependent: bool,
    prev_frame: ?[*]model.StackItem,
  ) ![*]model.StackItem {
    const data = self.ctx.data;
    const num_params =
      sig.parameters.len + if (ns_dependent) @as(usize, 1) else 0;
    if (
      (@ptrToInt(data.stack_ptr) - @ptrToInt(data.stack.ptr))
      / @sizeOf(model.StackItem) + num_params > data.stack.len
    ) {
      return nyarna.Error.nyarna_stack_overflow;
    }
    const ret = data.stack_ptr;
    data.stack_ptr += num_params + 1;
    ret.* = .{.frame_ref = prev_frame};
    return ret;
  }

  fn resetParameterStackFrame(
    self: *Evaluator,
    frame_ptr: *?[*]model.StackItem,
    sig: *const model.Signature,
  ) void {
    frame_ptr.* = frame_ptr.*.?[0].frame_ref;
    self.ctx.data.stack_ptr -= sig.parameters.len + 1;
  }

  fn fillParameterStackFrame(
    self: *Evaluator,
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
    defer self.resetParameterStackFrame(&frame, callable.sig);
    return if (try self.fillParameterStackFrame(
        call.exprs, frame.? + 1))
      target_impl(impl_ctx, call.expr().pos, frame.? + 1)
    else poison(impl_ctx, call.expr().pos);
  }

  fn evaluateCall(
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
            defer self.resetParameterStackFrame(
              &fr.func.variables.cur_frame, fr.func.sig());
            return if (try self.fillParameterStackFrame(
                call.exprs, frame_ptr))
              target_impl(impl_ctx, call.expr().pos, fr.func.argStart())
            else poison(impl_ctx, call.expr().pos);
          },
          .ny => |*nf| {
            fr.func.variables.cur_frame = try self.setupParameterStackFrame(
              fr.func.sig(), false, fr.func.variables.cur_frame);
            defer self.resetParameterStackFrame(
              &fr.func.variables.cur_frame, fr.func.sig());
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
        const constr = self.ctx.types().typeConstructor(tv.t);
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
    return self.evaluateCall(intpr, call);
  }

  /// actual evaluation of expressions.
  fn doEvaluate(
    self: *Evaluator,
    expr: *model.Expression,
  ) nyarna.Error!*model.Value {
    switch (expr.data) {
      .access => |*access| {
        var cur = try self.evaluate(access.subject);
        for (access.path) |index| {
          cur = switch (cur.data) {
            .record => |*record| record.fields[index],
            .list   => |*list|   list.content.items[index],
            else    => unreachable,
          };
        }
        return cur;
      },
      .assignment => |*assignment| {
        var cur_ptr = assignment.target.curPtr();
        for (assignment.path) |index| {
          cur_ptr = switch (cur_ptr.*.data) {
            .record => |*record| &record.fields[index],
            .list   => |*list|   &list.content.items[index],
            else => unreachable,
          };
        }
        cur_ptr.* = try self.evaluate(assignment.expr);
        return try model.Value.create(
          self.ctx.global(), expr.pos, .void);
      },
      .branches => |*branches| {
        var condition = try self.evaluate(branches.condition);
        if (self.ctx.types().valueType(condition).isInst(.poison))
          return model.Value.create(
            self.ctx.global(), expr.pos, .poison);
        return self.evaluate(
          branches.branches[condition.data.@"enum".index]);
      },
      .call => |*call| return self.evaluateCall(self, call),
      .concatenation => |concat| {
        var builder = ConcatBuilder.init(
          self.ctx, expr.pos, expr.expected_type);
        for (concat) |item| try builder.push(try self.evaluate(item));
        return try builder.finish();
      },
      .value => |value| return value,
      .paragraphs => |paras| {
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
          var ret: ?*model.Value = null;
          for (paras) |para| {
            const cur = try self.evaluate(para.content);
            if (cur.data != .void and cur.data != .poison) {
              std.debug.assert(ret == null);
              ret = cur;
            }
          }
          return ret orelse try self.ctx.values.void(expr.pos);
        }
      },
      .varargs => |*varargs| {
        const list = try self.ctx.values.list(
          expr.pos, &expr.expected_type.structural.list);
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
      },
      .var_retrieval => |*var_retr| return var_retr.variable.curPtr().*,
      .poison => return self.ctx.values.poison(expr.pos),
      .void => return self.ctx.values.void(expr.pos),
    }
  }

  inline fn toString(self: *Evaluator, input: anytype) ![]u8 {
    return std.fmt.allocPrint(self.ctx.global(), "{}", .{input});
  }

  fn coerce(
    self: *Evaluator,
    value: *model.Value,
    expected_type: model.Type,
  ) std.mem.Allocator.Error!*model.Value {
    const value_type = self.ctx.types().valueType(value);
    if (value_type.eql(expected_type)) return value;
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
        .list, .map => unreachable, // TODO: implement coercion of inner values.
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
      self.ctx.types().valueType(res), expr.expected_type);
    return try self.coerce(res, expected_type);
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
      self.inner_type, self.ctx.types().valueType(item));

    if (self.cur_items) |*content| try content.append(item)
    else self.cur = item;
  }

  fn finishText(self: *ConcatBuilder, more: *const MoreText) !void {
    const scalar_val = try self.ctx.values.textScalar(
      more.pos, self.scalar_type, more.content.items);
    try self.enqueue(scalar_val.value());
  }

  pub fn push(self: *ConcatBuilder, item: *model.Value) !void {
    switch (self.state) {
      .initial => {
        if (item.data == .text) {
          self.state = .{.first_text = item};
        } else try self.enqueue(item);
      },
      .first_text => |start| {
        if (item.data == .text) {
          self.state = .{.more_text = .{.pos = start.origin}};
          try self.state.more_text.content.appendSlice(
            self.ctx.global(), start.data.text.content);
          try self.state.more_text.content.appendSlice(
            self.ctx.global(), item.data.text.content);
          self.state.more_text.pos.end = item.origin.end;
        } else {
          try self.enqueue(start);
          try self.enqueue(item);
          self.state = .initial;
        }
      },
      .more_text => |*more| {
        if (item.data == .text) {
          try more.content.appendSlice(
            self.ctx.global(), item.data.text.content);
          more.pos.end = item.origin.end;
        } else {
          try self.finishText(more);
          try self.enqueue(item);
          self.state = .initial;
        }
      }
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
    const item_type = self.ctx.types().valueType(item.content);
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