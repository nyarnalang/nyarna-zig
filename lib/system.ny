
# special keyword to establish symbols that are present in all namespaces.
# takes care of making the used types available even though they are only
# declared later. \magic is not available outside of system.ny.
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

# \unique declares unique types. not available outside of system.ny.
# If the unique type has a constructor, its parameters are given as argument.
#
# \prototype declares a prototype. not available outside of system.ny.
# The primary argument is the prototype's parameter(s).
\declare:
  Ast = \unique()
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

  Concat, Optional, List = \prototype:
    inner: \Ast {primary}
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

  keyword = \keyword:
    params: \Ast {primary}:<syntax locations>
  \end(keyword)

  builtin = \keyword:
    return: \Ast
    params: \Ast {primary}:<syntax locations>
  \end(keyword)

  if = \keyword:
    condition: \Ast
    then: \Optional(\Ast) {primary}
    else: \Optional(\Ast)
  \end(keyword)

  #Bool = \Enum(false, true)
:private:
  FrameRoot   = \unique()
  Literal     = \unique()
  BlockHeader = \unique()
  Space       = \unique()
\end(declare)