# This module bootstraps Nyarna's commands and types.
# To facilitate this, it needs pre-defined commands that are only available
# when parsing this file. Those commands are:
#
# \magic
#   establishes symbols that are available in all namespaces.
# \unique
#   declares unique types. Their names define their semantics.
#   The argument defines the parameters of its constructor, if any.
# \prototype
#   declares a prototype. The primary argument is the prototype's parameter(s).
#   an optional secondary argument 'funcs' may define functions that are
#   available for every instance of the prototype. Inside 'funcs', the name of
#   the prototype is available as symbol to denote the instance.
# \This
#   Placeholder symbol for the instance type in a function declared on a
#   prototype. For every instance of the prototype, that function will be
#   available with \This being replaced by the instance type.
#
# Apart from those symbols, several symbols are automatically predefined to be
# able to define symbols. Those are later properly defined, overriding the
# predefined symbols. The predefined symbols are:
# \Ast, \FrameRoot, \Optional, \Type, \keyword

\magic:
  declare = \keyword:
    namespace: \Optional(\Type)
    public   : \Optional(\Ast) {primary}:<syntax definitions>
    private  : \Optional(\Ast) {}:<syntax definitions>
  \end(keyword)

  func, method = \keyword:
    return: \Optional(\Ast)
    params: \Optional(\Ast) {primary}:<syntax locations>
    body  : \FrameRoot
  \end(keyword)

  import = \keyword:
    locator: \Ast
  \end(keyword)

  var = \keyword:
    defs: \Ast {primary}:<syntax locations>
  \end(keyword)
\end(magic)

# These symbols are defined in an initial declare block so that their block
# configurations are available in the following declare block.
\declare:
  Ast = \unique()
  keyword = \keyword:
    params: \Ast {primary}:<syntax locations>
  \end(keyword)

  builtin = \keyword:
    return: \Ast
    params: \Ast {primary}:<syntax locations>
  \end(keyword)
\end(declare)

\declare:
  Type = \unique()
  Void = \unique()

  Raw = \unique:
    input: \Raw
  \end(unique)

  Location = \unique:
    name    : \Literal
    type    : \Type
    primary = \Bool(false)
    varargs = \Bool(false)
    varmap  = \Bool(false)
    mutable = \Bool(false)
    default : \Optional(\Ast) {primary}
  \end(unique)

  Definition = \unique:
    name : \Literal
    root = \Bool(false)
    item : \Ast
  \end(unique)

  Concat, Optional = \prototype:
    inner: \Ast {primary}
  \end(prototype)

  List = \prototype:
    inner: \Ast {primary}
  :funcs:
    length = \builtin(return=\Natural):
      this: \This
    \end(builtin)
  \end(prototype)

  Paragraphs = \prototype:
    inners: \List(\Ast) {varargs, primary}
  \end(prototype)

  Map = \prototype:
    key, value: \Ast
  \end(prototype)

  Record = \prototype:
    fields: \Optional(\Ast) {primary}:<syntax locations>
  \end(prototype)

  Intersection = \prototype:
    types: \List(\Ast) {varargs}
  \end(prototype)

  Textual = \prototype:
    cats, include, exclude: \Optional(\Ast)
  \end(prototype)

  Numeric = \prototype:
    min, max, decimals: \Optional(\Ast)
  \end(prototype)

  Float = \prototype:
    precision: \Ast
  \end(prototype)

  Enum = \prototype:
    values: \List(\Ast) {varargs}
  \end(prototype)

  if = \keyword:
    condition: \Ast
    then: \Optional(\Ast) {primary}
    else: \Optional(\Ast)
  \end(keyword)

  Bool = \Enum(false, true)
  Integer = \Numeric()
  Natural = \Numeric(min=0)
  UnicodeCategory = \Enum(
    Lu, Ll, Lt, Lm, Lo, Lut, LC, L, Mn, Mc, Me, Nd, Nl, No, M,
    Pc, Pd, Ps, Pe, Pi, Pf, Po, P, Sm, Sc, Sk, So, S, MPS,
    Zs, Zl, Zp, Cc, Cf, Co, Cn
  )
:private:
  FrameRoot   = \unique()
  Literal     = \unique()
  BlockHeader = \unique()
  Space       = \unique()
\end(declare)