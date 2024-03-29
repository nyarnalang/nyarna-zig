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

  func = \keyword:
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
  # the following two definitions must come first to make the implementation
  # happy. There are some circular references in our type definitions here and
  # the order of types tells the interpreter in which order to resolve them so
  # that everything works.

  Enum = \prototype:
    values: \List(\Ast) {varargs}
  :constructor:
    input: \Literal {primary}
  \end(prototype)

  Numeric = \prototype:
    backend : \Ast
    min, max: \Optional(\Ast)
    suffixes: \HashMap(\Literal, \Ast) {varmap}
  :constructor:
    input: \Literal {primary}
  :funcs:
    add = \builtin(return=\This):
      values: \List(\This) {varargs}
    \end(builtin)
    sub = \builtin(return=\This):
      minuend, subtrahend: \This
    \end(builtin)
    mult = \builtin(return=\This):
      values: \List(\This) {varargs}
    \end(builtin)
    lt = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
    gt = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
    lte = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
    gte = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
    eq = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
    neq = \builtin(return=\Bool):
      left, right: \This
    \end(builtin)
  \end(prototype)

  Type = \unique()
  Void = \unique:
    # has a constructor that takes no parameters
  \end(unique)

  Location = \unique:
    name    : \Literal
    type    : \Type
    primary = \Bool(false)
    varargs = \Bool(false)
    varmap  = \Bool(false)
    borrow  = \Bool(false)
    default : \Optional(\Ast) {primary}
  \end(unique)

  Definition = \unique:
    name  : \Literal
    merge = \Bool(false)
    item  : \Ast {primary}
  \end(unique)

  Schema = \unique()

  SchemaDef = \unique:
    root    : \Ast
    public  : \Optional(\Ast) {primary}:<syntax definitions, fullast>
    private : \Optional(\Ast) {}:<syntax definitions, fullast>
    backends: \Optional(\Ast) {}:<syntax definitions>
  \end(unique)

  SchemaExt = \unique:
    public  : \Optional(\Ast) {primary}:<syntax definitions, fullast>
    private : \Optional(\Ast) {}:<syntax definitions, fullast>
    backends: \Optional(\Ast) {}:<syntax definitions>
  \end(unique)

  backend = \keyword:
    vars    : \Optional(\Ast) {primary}:<syntax locations>
    funcs   : \Optional(\Ast) {}:<syntax definitions, fullast>
    body    : \Optional(\FrameRoot)
  \end(keyword)

  Output = \unique:
    name  : \Ast
    schema: \Optional(\Ast)
    body  : \Ast {primary}
  \end(unique)

  Concat = \prototype:
    inner: \Ast {primary}
  :funcs:
    len = \builtin(return=\Natural):
      this: \This {borrow}
    \end(builtin)
    item = \builtin(return=\Inner):
      this : \This     {borrow}
      index: \Positive
    \end(builtin)
  \end(prototype)

  Optional = \prototype:
    inner: \Ast {primary}
  \end(prototype)

  List = \prototype:
    Inner: \Ast {primary}
  :constructor:
    items: \List(\Inner) {varargs}
  :funcs:
    len = \builtin(return=\Natural):
      this: \This {borrow}
    \end(builtin)
    item = \builtin(return=\Inner):
      this : \This     {borrow}
      index: \Positive
    \end(builtin)
  \end(prototype)

  Sequence = \prototype:
    inner: \List(\Ast) {varargs}
    direct, auto: \Optional(\Ast)
  \end(prototype)

  HashMap = \prototype:
    key, value: \Ast
  \end(prototype)

  Record = \prototype:
    embed    : \List(\Ast) {varargs}
    abstract : \Optional(\Ast)
    fields   : \Optional(\Ast) {primary}:<syntax locations>
  \end(prototype)

  Intersection = \prototype:
    types: \List(\Ast) {varargs}
  \end(prototype)

  Textual = \prototype:
    cats: \List(\Ast) {varargs}
    include, exclude: \Optional(\Ast)
  :constructor:
    input: \Literal {primary}
  :funcs:
    len = \builtin(return=\Natural):
      self: \This
    \end(builtin)
    eq = \builtin(return=\Bool):
      self, other: \This
    \end(builtin)
    slice = \builtin(return=\This):
      self: \This
      start, end: \Optional(\Positive)
    \end(builtin)
  \end(prototype)

  library    = \keyword:
    options: \Optional(\Ast) {primary}:<syntax locations>
  \end(keyword)

  standalone = \keyword:
    options: \Optional(\Ast) {primary}:<syntax locations>
    params : \Optional(\Ast) {}:<syntax locations>
    schema : \Optional(\Ast)
  \end(keyword)

  fragment = \keyword:
    root   : \Ast
    options: \Optional(\Ast) {primary}:<syntax locations>
    params : \Optional(\Ast) {}:<syntax locations>
  \end(keyword)

  if = \keyword:
    condition: \Ast
    then     : \Ast            {primary}
    else     : \Optional(\Ast)
  \end(keyword)

  map = \keyword:
    input    : \Ast            {primary}
    func     : \Optional(\Ast)
    collector: \Optional(\Ast)
  \end(keyword)

  for = \keyword:
    input    : \Ast
    collector: \Optional(\Ast)
    body     : \FrameRoot      {primary}
  \end(keyword)

  unroll = \keyword:
    input    : \Ast
    collector: \Optional(\Ast)
    body     : \Ast {primary}:<fullast>
  \end(keyword)

  match = \keyword:
    subject: \Ast
    cases: \HashMap(\Type, \FrameRoot) {primary, varmap}
  \end(keyword)

  matcher = \keyword:
    cases: \HashMap(\Type, \FrameRoot) {primary, varmap}
  \end(keyword)

  Bool = \Enum(false, true)
  NumericImpl = \Enum(int, float)
  Integer = \Numeric(int)
  Natural = \Numeric(int, min=0)
  Positive = \Numeric(int, min=1)
  UnicodeCategory = \Enum(
    Lu, Ll, Lt, Lm, Lo, Lut, LC, L, Mn, Mc, Me, Nd, Nl, No, M,
    Pc, Pd, Ps, Pe, Pi, Pf, Po, P, Sm, Sc, Sk, So, S, MPS,
    Zs, Zl, Zp, Cc, Cf, Co, Cn
  )
  Text = \Textual()
  Identifier = \Textual(cats = L, Nd, include = _)
  OutputName = \Textual(cats = L, Nd, include = \ /-_.!~*'\(\))

  block = \keyword:
    content: \Ast {primary}
  \end(keyword)

  # Returns a callable that can syntax highlight input of the given syntax.
  # The returned callable has the following signature:
  #   content: \Text            {primary}:<off>
  #   before : \Optional(\Text) {       }:<off>
  # `content` is the text to be highlighted, `before` can be additional text
  # that should be parsed before `content` to set up the correct syntax context.
  # the return type is inferred from the given renderers.
  highlighter = \keyword:
    # name of the syntax to highlight.
    syntax    : \Ast
    # Renderers for each of the items occurring in the syntax.
    # These are defined by the syntax. Each renderer may have a capture that
    # will contain the rendered content of the entity that should be rendered.
    # The type of this capture will be the inferred return type of the
    # whole highlighting function.
    renderers : \HashMap(\Literal, \Ast) {varmap}
  \end(keyword)
:private:
  FrameRoot   = \unique()
  Literal     = \unique()
  BlockHeader = \unique()
  Space       = \unique()
\end(declare)

\library()

\declare(\SchemaDef):
  use = \keyword:
    base      : \SchemaDef
    backend   : \Optional(\Identifier)
    extensions: \List(\SchemaExt)      {varargs}
  \end(keyword)
\end(declare)

\declare(\Location):
  name = \builtin(return=\Identifier):
    this: \Location
  \end(builtin)
  type = \builtin(return=\Type):
    this: \Location
  \end(builtin)
\end(declare)