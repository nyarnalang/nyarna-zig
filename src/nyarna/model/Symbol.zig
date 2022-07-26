//! a symbol that can be referenced by name.

const model = @import("../model.zig");

const Type  = model.Type;
const Value = model.Value;

const offset = @import("../helpers.zig").offset;

const Symbol = @This();

/// A variable defined in Nyarna code.
pub const Variable = struct {
  spec: model.SpecType,
  /// the container owning this variable
  container: *model.VariableContainer,
  /// the offset of this variable inside the container in StackItems.
  /// `container.cur_frame + offset + 1` is the location of this variable's
  /// current value. The 1 skips the current frame's header.
  offset: u15,
  kind: enum {
    /// actual variable. can be assigned to and has no restrictions.
    assignable,
    /// mutable argument. cannot be assigned to but can be associated with
    /// mutable parameters in calls.
    mutable,
    /// non-mutable argument. must be copied to get a mutable value.
    given,
    /// static option. references to this variable will be immediately replaced
    /// by the value it points to.
    static,
  },

  pub fn sym(self: *Variable) *Symbol {
    return Symbol.parent(self);
  }

  /// returns a pointer into the stack referencing the current position of
  /// this variable. precondition: variable is currently named on the
  /// stack.
  pub fn curPtr(self: *Variable) **Value {
    return &self.container.cur_frame.?[1 + self.offset].value;
  }
};

pub const Data = union(enum) {
  func     : *model.Function,
  variable : Variable,
  @"type"  : Type,
  prototype: model.Prototype,
  poison,
};

defined_at: model.Position,
name: []const u8,
data: Data,
/// the type in whose namespace this symbol is declared. null if the symbol is
/// not declared in the namespace of a type.
parent_type: ?Type = null,

fn parent(it: anytype) *Symbol {
  const t = @typeInfo(@TypeOf(it)).Pointer.child;
  const addr = @ptrToInt(it) - switch (t) {
    *model.Function => offset(Data, "func"),
    Variable => offset(Data, "variable"),
    Type => offset(Data, "type"),
    model.Prototype => offset(Data, "prototype"),
    else => unreachable
  };
  return @fieldParentPtr(Symbol, "data", @intToPtr(*Data, addr));
}

/// definition of a symbol in the currently parsed module
pub const Definition = struct {
  /// symbol's namespace
  ns   : u15,
  sym  : *model.Symbol,
  /// true if the symbol is currently alive.
  alive: bool,
};