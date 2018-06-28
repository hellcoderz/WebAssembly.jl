# Converts a module to its bytecode representation.

# The bytecode layout is somewhat different to the structure of the wasm IR. It
# therefore makes sense to restructure the IR into an intermediary format and
# then make a short hop to bytecode. The length of each section needs to be
# saved alongside it which would require a second pass anyway.

const magic   = 0x6d736100 # \0asm
const version = 0x00000001 # Targeting version 1
const preamble = reinterpret(UInt8, [magic, version])

# Converts any Integer type to Leb128 format as an array of bytes.
function toLeb128(x :: Integer)
  len = sizeof(x) * 8
  bytes = Vector{UInt8}()

  # do while.
  byte = UInt8(x & 0x7F) | 0x80 # Set the continuation bit.
  x >>= 7
  push!(bytes, byte)
  while !(x == 0 && (byte & 0x40 == 0)) && !(x == -1 && (byte & 0x40 != 0))
    byte = UInt8(x & 0x7F) | 0x80 # Set the continuation bit.
    x >>= 7
    push!(bytes, byte)
  end
  bytes[end] &= 0x7F # Unset the final continuation bit.
  return bytes
end

# Converts array of bytes to Integer type. Assumes the array is of only the
# relevant bytes and thus ignores continuation bits.
function fromLeb128(bs, typ=BigInt)
  result = typ(0)
  shift = 0
  for i in eachindex(bs)
    result |= typ(bs[i] & 0x7F) << shift
    shift += 7
  end
  if bs[end] & 0x40 != 0
    result |= (typ(-1) << shift)
  end
  return result
end

# Get the raw utf8 bytes of a string.
utf8(x :: String) = Vector{UInt8}(x)
utf8(x) = x |> string |> utf8

# Take a module and return an Array of function types and an Array of the types
# that each function uses.

# In the binary representation each function is allowed multiple types, as all
# types are being added to the type section they will each only be given one.
function getTypes(m)
  tys = [(f.params, f.returns) for f in m.funcs]
  types = collect(Set(tys))
  dict = Dict(zip(types, 0:length(types)))
  return (length(types), [(-32, length(t[1]), t[1], length(t[2]), t[2]) for t in types]), (length(tys), [[dict[t]] for t in tys]) # -32 == -0x20 :: int7
end

# Get all of the code bodies
getFunctionBodies(m, f_ids) = length(m.funcs), [addLength(vcat(toBytes((length(f.locals), [(1,l) for l in f.locals], bodyToBytes(f.body.body, f_ids))), 0x0b)) for f in m.funcs]

bodyToBytes(is, f_ids) = Vector{UInt8}(vcat([byte_op(i, f_ids) for i in is]...)) :: Vector{UInt8}

byte_op(i :: Local, f_ids) = UInt8[0x20, i.id]
byte_op(i :: SetLocal, f_ids) = UInt8[i.tee ? 0x22 : 0x21, i.id]
byte_op(i :: Const, f_ids) = UInt8[opcodes[Const, i.typ], toLeb128(i.val)...]
# byte_op(i :: Op, f_ids) = opcodes[i.typ][i.name]
byte_op(i :: If, f_ids) = vcat(0x04, 0x40, bodyToBytes(i.t, f_ids), 0x05, bodyToBytes(i.f, f_ids), 0x0b)
byte_op(i :: Block, f_ids) = vcat(0x02, 0x40, bodyToBytes(i.body, f_ids), 0x0b)
byte_op(i :: Loop, f_ids) = vcat(0x03, 0x40, bodyToBytes(i.body, f_ids), 0x0b)
byte_op(i :: Branch, f_ids) = vcat(i.cond ? 0x0d : 0x0c, toLeb128(i.level))
byte_op(i :: Return, f_ids) = 0x0f
byte_op(i :: Select, f_ids) = 0x1b
byte_op(i :: Unreachable, f_ids) = 0x00
byte_op(i :: Nop, f_ids) = 0x01
byte_op(i :: Call, f_ids) = vcat(0x10, toLeb128(f_ids[i.name]))
byte_op(i :: Union{Op, Convert}, f_ids) = opcodes[i]#conversions[i.to, i.name, i.from]

const external_kind =
  Dict(
    :func   => 0,
    :table  => 1,
    :memory => 2,
    :global => 3
  )

const external_kind_r =
  Dict(
    0x00 => :func,
    0x01 => :table,
    0x02 => :memory,
    0x03 => :global
  )

# Construct dictionaries from names to index for each index space, and then
# use them to construct the exports.

# Currently just memory and functions.
function getExports(m, space)
  return length(m.exports), [(e.name, external_kind[e.typ], space[e.typ][e.internalname]) for e in m.exports]
end

function getModule(m)
  f_ids = Dict(zip([f.name for f in m.funcs], 0:length(m.funcs)))
  m_ids  = Dict(zip([mem.name for mem in m.mems], 0:length(m.mems)))
  space = Dict(:memory => m_ids, :func => f_ids)

  types, funcs = getTypes(m)
  exports = getExports(m, space)
  code = getFunctionBodies(m, f_ids)
  # types_, funcs_, exports_, code_ = map(toBytes, (types, funcs, exports, code))
  # sections = vcat([vcat(toBytes(s[1]),addLength(toBytes(s[2]))) for s in [(1, types), (3, funcs), (7, exports), (10, code)]]...)
  sections = vcat([vcat(toBytes(s[1]),addLength(toBytes(s[2]))) for s in [(1, types), (3, funcs), (7, exports), (10, code)]]...)
  # sections = toBytes([(1, types), (3, funcs), (7, exports)])

  return vcat(preamble, sections)
end

# Currently assuming the arrays always have the form length of array followed by
# the array, same for strings.
addLength(xs :: Vector{UInt8}) = vcat(toBytes(length(xs)), xs) :: Vector{UInt8}

toBytes(xs :: Vector{UInt8}) = xs
toBytes(xs :: Union{Array, Tuple}) = Vector{UInt8}(vcat(map(toBytes, xs)...))
# toBytes(xs :: Tuple) = unshift!(collect(Iterators.flatten([toBytes(x) for x in xs])), toBytes(length(xs))...)
toBytes(xs :: Union{String, Symbol}) = addLength(utf8(xs)) :: Vector{UInt8}
toBytes(x :: Integer) = toLeb128(x) :: Vector{UInt8}
toBytes(x :: WType) = types[x] :: UInt8
# toBytes(i :: Local) =

#### Read a bytecode file

function getByteFile(filename)
  f = open(filename, "r")
  bs = read(f)
  close(f)
  return bs
end

function readModule(filename)
  bs = getByteFile(filename)
  if bs[1:length(preamble)] != preamble
    error("Something wrong with preamble. Version 1 only.")
  end
  i = length(preamble) + 1
  id = id_ = -1

  types = Vector{Tuple{Vector{WType}, Vector{WType}}}()
  func_types = Vector{UInt32}()
  exports = Vector{Tuple{Symbol, Symbol, Int}}()
  memory = Vector{Tuple{UInt32, Union{UInt32, Void}}}()
  while id < 7
    i, id = readLeb128(i, bs)
    id > id_ || error("Sections must be in increasing order.")
    i, payload_len = readLeb128(i, bs)

    @show id
    if id == 1 # Types
      i, count = readLeb128(i, bs)
      for j in 1:count
        i, form = readLeb128(i, bs, Int8)
        @show form
        form == -32 || error("Not a valid function")
        i, params = getRegisters(i, bs)
        i, returns = getRegisters(i, bs)
        push!(types, (params, returns))
      end
    elseif id == 3 # Functions
      i, func_types = getArray(i, bs, UInt32)
    elseif id == 5
      i, count = readLeb128(i, bs, UInt32)
      i, flag = readLeb128(i, bs, UInt8)
      i, initial = readLeb128(i, bs, UInt32)
      maximum = Void()
      if flag == 0x01
        i, maximum = readLeb128(i,bs,UInt32)
      end
      push!(memory, (initial, maximum))
    elseif id == 7 # Exports
      i, count = readLeb128(i, bs, UInt32)
      for j in 1:count
        i, name = readsymbol(i, bs)
        i, kind = i + 1, external_kind_r[bs[i]]
        i, index = readLeb128(i, bs, UInt32)
        push!(exports, (name, kind, index))
      end
    # elseif id == 10
      # i, cound = readLeb
    end





  end
  return types, func_types, exports, memory
end

function getRegisters(i, bs)
  i, regs = getBytes(i, bs)
  @show regs
  return i, map(b -> types_r[b], regs)
end

function getArray(i, bs, typ)
  i, count = readLeb128(i, bs, UInt32)
  values = Vector{typ}()
  for j in 1:count
    i, val = readLeb128(i, bs, typ)
    push!(values, val)
  end
  return i, values
end

function readLeb128(i, bs, typ=Int32)
  j = i
  while (bs[j] & 0x80 != 0)
    j = j + 1
  end
  return j + 1, fromLeb128(bs[i:j], typ)
end

function readutf8(i, bs)
  i, s = getBytes(i, bs)
  return i, String(s)
end

function readsymbol(i, bs)
  i, s = getBytes(i, bs)
  return i, Symbol(s)
end

function getBytes(i, bs)
  i, len = readLeb128(i, bs, UInt32)
  j = i + len
  return j, bs[i:j-1]
end

const types =
  Dict(
    i32 => 0x7f,
    i64 => 0x7e,
    f32 => 0x7d,
    f64 => 0x7c
  )

const types_r = map(reverse, types)

opcodes =
  Dict(
    (Const, i32)  =>  0x41,
    (Const, i64)  =>	0x42,
    (Const, f32)  =>  0x43,
    (Const, f64)  =>  0x44,

    Op(i32, :eqz)	   =>  0x45,
    Op(i32, :eq)	   =>  0x46,
    Op(i32, :ne)	   =>  0x47,
    Op(i32, :lt_s)	 =>  0x48,
    Op(i32, :lt_u)	 =>  0x49,
    Op(i32, :gt_s)	 =>  0x4a,
    Op(i32, :gt_u)	 =>  0x4b,
    Op(i32, :le_s)	 =>  0x4c,
    Op(i32, :le_u)	 =>  0x4d,
    Op(i32, :ge_s)	 =>  0x4e,
    Op(i32, :ge_u)	 =>  0x4f,
    Op(i32, :clz)    =>  0x67,
    Op(i32, :ctz)    =>  0x68,
    Op(i32, :popcnt) =>  0x69,
    Op(i32, :add)    =>  0x6a,
    Op(i32, :sub)    =>  0x6b,
    Op(i32, :mul)    =>  0x6c,
    Op(i32, :div_s)  =>  0x6d,
    Op(i32, :div_u)  =>  0x6e,
    Op(i32, :rem_s)  =>  0x6f,
    Op(i32, :rem_u)  =>  0x70,
    Op(i32, :and)    =>  0x71,
    Op(i32, :or)     =>  0x72,
    Op(i32, :xor)    =>  0x73,
    Op(i32, :shl)    =>  0x74,
    Op(i32, :shr_s)  =>  0x75,
    Op(i32, :shr_u)  =>  0x76,
    Op(i32, :rotl)   =>  0x77,
    Op(i32, :rotr)   =>  0x78,

    Op(i64, :eqz)	   =>  0x50,
    Op(i64, :eq)	   =>  0x51,
    Op(i64, :ne)	   =>  0x52,
    Op(i64, :lt_s)	 =>  0x53,
    Op(i64, :lt_u)	 =>  0x54,
    Op(i64, :gt_s)	 =>  0x55,
    Op(i64, :gt_u)	 =>  0x56,
    Op(i64, :le_s)	 =>  0x57,
    Op(i64, :le_u)	 =>  0x58,
    Op(i64, :ge_s)	 =>  0x59,
    Op(i64, :ge_u)	 =>  0x5a,
    Op(i64, :clz)    =>	 0x79,
    Op(i64, :ctz)    =>	 0x7a,
    Op(i64, :popcnt) =>	 0x7b,
    Op(i64, :add)    =>	 0x7c,
    Op(i64, :sub)    =>	 0x7d,
    Op(i64, :mul)    =>	 0x7e,
    Op(i64, :div_s)  =>	 0x7f,
    Op(i64, :div_u)  =>	 0x80,
    Op(i64, :rem_s)  =>	 0x81,
    Op(i64, :rem_u)  =>	 0x82,
    Op(i64, :and)    =>	 0x83,
    Op(i64, :or)     =>	 0x84,
    Op(i64, :xor)    =>	 0x85,
    Op(i64, :shl)    =>	 0x86,
    Op(i64, :shr_s)  =>	 0x87,
    Op(i64, :shr_u)  =>	 0x88,
    Op(i64, :rotl)   =>	 0x89,
    Op(i64, :rotr)   =>	 0x8a,

    Op(f32, :eq)       =>  0x5b,
    Op(f32, :ne)       =>  0x5c,
    Op(f32, :lt)       =>  0x5d,
    Op(f32, :gt)       =>  0x5e,
    Op(f32, :le)       =>  0x5f,
    Op(f32, :ge)       =>  0x60,
    Op(f32, :abs)      =>  0x8b,
    Op(f32, :neg)      =>  0x8c,
    Op(f32, :ceil)     =>  0x8d,
    Op(f32, :floor)    =>  0x8e,
    Op(f32, :trunc)    =>  0x8f,
    Op(f32, :nearest)  =>  0x90,
    Op(f32, :sqrt)     =>  0x91,
    Op(f32, :add)      =>  0x92,
    Op(f32, :sub)      =>  0x93,
    Op(f32, :mul)      =>  0x94,
    Op(f32, :div)      =>  0x95,
    Op(f32, :min)      =>  0x96,
    Op(f32, :max)      =>  0x97,
    Op(f32, :copysign) =>  0x98,

    Op(f64, :eq)       =>  0x61,
    Op(f64, :ne)       =>  0x62,
    Op(f64, :lt)       =>  0x63,
    Op(f64, :gt)       =>  0x64,
    Op(f64, :le)       =>  0x65,
    Op(f64, :ge)       =>  0x66,
    Op(f64, :abs)      =>  0x99,
    Op(f64, :neg)      =>  0x9a,
    Op(f64, :ceil)     =>  0x9b,
    Op(f64, :floor)    =>  0x9c,
    Op(f64, :trunc)    =>  0x9d,
    Op(f64, :nearest)  =>  0x9e,
    Op(f64, :sqrt)     =>  0x9f,
    Op(f64, :add)      =>  0xa0,
    Op(f64, :sub)      =>  0xa1,
    Op(f64, :mul)      =>  0xa2,
    Op(f64, :div)      =>  0xa3,
    Op(f64, :min)      =>  0xa4,
    Op(f64, :max)      =>  0xa5,
    Op(f64, :copysign) =>  0xa6,

    Convert(i32, i64, :wrap)         =>	0xa7,
    Convert(i32, f32, :trunc_s)      =>	0xa8,
    Convert(i32, f32, :trunc_u)      =>	0xa9,
    Convert(i32, f64, :trunc_s)      =>	0xaa,
    Convert(i32, f64, :trunc_u)      =>	0xab,
    Convert(i64, i32, :extend_s)     =>	0xac,
    Convert(i64, i32, :extend_u)     =>	0xad,
    Convert(i64, f32, :trunc_s)      =>	0xae,
    Convert(i64, f32, :trunc_u)      =>	0xaf,
    Convert(i64, f64, :trunc_s)      =>	0xb0,
    Convert(i64, f64, :trunc_u)      =>	0xb1,
    Convert(f32, i32, :convert_s)    =>	0xb2,
    Convert(f32, i32, :convert_u)    =>	0xb3,
    Convert(f32, i64, :convert_s)    =>	0xb4,
    Convert(f32, i64, :convert_u)    =>	0xb5,
    Convert(f32, f64, :demote)       =>	0xb6,
    Convert(f64, i32, :convert_s)    =>	0xb7,
    Convert(f64, i32, :convert_u)    =>	0xb8,
    Convert(f64, i64, :convert_s)    =>	0xb9,
    Convert(f64, i64, :convert_u)    =>	0xba,
    Convert(f64, f32, :promote)      =>	0xbb,
    Convert(i32, f32, :reinterpret)  =>	0xbc,
    Convert(i64, f64, :reinterpret)  =>	0xbd,
    Convert(f32, i32, :reinterpret)  =>	0xbe,
    Convert(f64, i64, :reinterpret)  =>	0xbf
  )

# Reverse dictionary of all opcodes including conversions.
const opcodes_r = map(reverse, opcodes)