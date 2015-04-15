#
#
#    Lexim - The Lexer Generator for Nim
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Translates the DFA into a bytecode and then runs the bytecode.
import unsigned, nfa, strutils, intsets, regexprs

type
  Instr* = distinct uint32

  Opcode* = enum
    opcRet,         # return with some literal
    opcTestSet,     # test current character against bitset in data section
    opcTestChar,    # test current character against char embedded in instr
    opcTJmp,        # jump if comparison was true
    opcBegin,       # \A match
    opcEnd,         # \Z match
    opcWordBound,   # \b match
    opcCaptureBegin # begin of capture '('
    opcCaptureEnd   # end of capture ')'
    opcBackref      # \\1 match

  Bytecode* {.shallow.} = object
    code*: seq[Instr]
    data*: seq[set[char]]
    startAt*, captures*: int

template opcode*(x: Instr): Opcode {.immediate.} = Opcode(x.uint32 and 0xff'u32)
template regBx*(x: Instr): int {.immediate.} = (x.uint32 shr 16'u32).int

proc codeListing(c: Bytecode, result: var string, start=0; last = -1) =
  # first iteration: compute all necessary labels:
  var jumpTargets = initIntSet()
  let last = if last < 0: c.code.len-1 else: min(last, c.code.len-1)
  jumpTargets.incl(c.startAt)
  for i in start..last:
    let x = c.code[i]
    if x.opcode == opcTJmp:
      jumpTargets.incl(x.regBx)
  result.addf("goto L$1:\n", c.startAt)
  var i = start
  while i <= last:
    if i in jumpTargets: result.addf("L$1:\n", i)
    let x = c.code[i]
    result.add($i)
    let opc = opcode(x)
    case opc
    of opcRet:
      result.addf("\t$#\t$#\n", ($opc).substr(3), x.regBx)
    of opcTestSet:
      result.addf("\t$#\t$#\n", ($opc).substr(3), $c.data[x.regBx])
    of opcTestChar:
      result.addf("\t$#\t$#\n", ($opc).substr(3), $chr(x.regBx))
    of opcTJmp:
      result.addf("\t$#\tL$#\n", ($opc).substr(3), x.regBx)
    of opcCaptureBegin, opcCaptureEnd, opcBackref:
      result.addf("\t$#\tC$#\n", ($opc).substr(3), x.regBx)
    of opcBegin, opcEnd, opcWordBound:
      result.addf("\t$#\n", ($opc).substr(3))
    inc i

proc echoCode*(c: Bytecode; start=0; last = -1) {.deprecated.} =
  var buf = ""
  codeListing(c, buf, start, last)
  echo buf

proc genInstr(opc: Opcode; bx: int): Instr =
  # `bx` must be signed and in the range [-32767, 32768]
  const a = 0
  doAssert bx >= -32767 and bx <= 32768
  result = (opc.uint32 or a.uint32 shl 8'u32 or
            bx.uint32 shl 16'u32).Instr

proc gABx(c: var Bytecode; opc: Opcode; bx: int) =
  c.code.add(genInstr(opc, bx))

proc genData(c: var Bytecode; data: set[char]): int =
  assert '\0' notin data
  for i in 0 .. c.data.high:
    if c.data[i] == data: return i
  result = c.data.len
  c.data.add data

proc genTest(res: var Bytecode; cs: set[Alphabet]; dest: int) =
  var elem = -1
  var card = 0
  var cc: set[char] = {}
  for x in 0..255:
    if x in cs:
      if elem == -1: elem = x
      inc card
      cc.incl char(x)
  if card == 1:
    gABx(res, opcTestChar, elem)
    gABx(res, opcTJmp, dest)
  elif card > 0:
    gABx(res, opcTestSet, genData(res, cc))
    gABx(res, opcTJmp, dest)
  if alBegin in cs:
    gABx(res, opcBegin, 0)
    gABx(res, opcTJmp, dest)
  if alEnd in cs:
    gABx(res, opcEnd, 0)
    gABx(res, opcTJmp, dest)
  if alWordBoundary in cs:
    gABx(res, opcWordBound, genData(res, wordChars))
    gABx(res, opcTJmp, dest)
  if alWordBoundaryNot in cs:
    gABx(res, opcWordBound, genData(res, {'\1'..'\255'} - wordChars))
    gABx(res, opcTJmp, dest)

proc genCapture(res: var Bytecode; cs: set[Alphabet]; dest: int;
                rule: var int) =
  if alCaptureBegin in cs:
    assert rule > 0
    gABx(res, opcCaptureBegin, rule-1)
    gABx(res, opcTJmp, dest)
    inc res.captures
    rule = 0
  elif alCaptureEnd in cs:
    assert rule > 0
    gABx(res, opcCaptureEnd, rule-1)
    gABx(res, opcTJmp, dest)
    rule = 0
  elif alBackref in cs:
    assert rule > 0
    gABx(res, opcBackref, rule-1)
    gABx(res, opcTJmp, dest)
    rule = 0

proc genBytecode*(a: DFA; res: var Bytecode) =
  var stateToLabel = newSeq[int](a.stateCount)

  for src in countup(1, a.stateCount):
    stateToLabel[src-1] = res.code.len
    var rule = getRule(a, src)
    for dest in countup(1, a.stateCount):
      let cs = getTransCC(a, src, dest)
      genCapture(res, cs, dest, rule)
      # this implements the rather strange
      # "match longest but only sometimes" rule that regexes seem to have:
      if rule == 0 or rule == getRule(a, dest): genTest(res, cs, dest)
    gABx(res, opcRet, rule)
  # Fixup the TJmp instructions:
  for i in 0 .. res.code.high:
    let instr = res.code[i]
    if opcode(instr) == opcTJmp:
      res.code[i] = genInstr(opcTJmp, stateToLabel[regBx(instr)-1])
  res.startAt = stateToLabel[a.startState-1]

type Action* = int #distinct range[1..32_000]

proc backrefMatch(input: string; sp: int; capture: (int, int)): bool =
  var i = capture[0]
  var k = 0
  while true:
    if i > capture[1]: return true
    if k >= input.len or input[k] != input[i]: return false
    inc k
    inc i

proc execBytecode*(m: Bytecode; input: string;
                   captures: var seq[(int, int)],
                   start=0): tuple[a: Action, endPos: int] =
  var pc = m.startAt
  var sp = start
  while true:
    let instr = m.code[pc]
    let opc = instr.opcode
    let arg = instr.regBx
    if opc == opcTestSet:
      # we *know* the next instruction is a TJmp:
      let next = m.code[pc+1]
      assert next.opcode == opcTJmp
      if input[sp] in m.data[arg]:
        pc = next.regBx
        inc sp
      else:
        inc pc, 2
    elif opc == opcTestChar:
      # we *know* the next instruction is a TJmp:
      let next = m.code[pc+1]
      assert next.opcode == opcTJmp
      if input[sp] == chr(arg):
        pc = next.regBx
        inc sp
      else:
        inc pc, 2
    elif opc == opcRet:
      return (Action(arg), sp)
    else:
      case opc
      of opcBegin:
        if sp == start:
          pc = m.code[pc+1].regBx
        else:
          inc pc, 2
      of opcEnd:
        if sp >= input.len:
          pc = m.code[pc+1].regBx
        else:
          inc pc, 2
      of opcWordBound:
        if sp >= input.len or sp == start or input[sp] notin m.data[arg]:
          pc = m.code[pc+1].regBx
        else:
          inc pc, 2
      of opcCaptureBegin:
        setLen(captures, arg+1)
        captures[arg][0] = sp
        pc = m.code[pc+1].regBx
      of opcCaptureEnd:
        captures[arg][1] = sp-1
        pc = m.code[pc+1].regBx
      of opcBackref:
        if arg < captures.len and backrefMatch(input, sp, captures[arg]):
          pc = m.code[pc+1].regBx
          inc sp, captures[arg][1] - captures[arg][0] + 1
        else:
          inc pc, 2
      else: assert false

proc findMacro(s: string): PRegExpr = nil

proc re*(regex: string; flags: set[RegexFlag] = {reExtended}): Bytecode =
  let r = parseRegExpr(regex, findMacro, flags)
  r.rule = 10
  var n: NFA
  regExprToNFA(r, n)

  var d, o: DFA
  NFA_to_DFA(n, d)
  optimizeDFA(d, o)

  result.code = @[]
  result.data = @[]
  genBytecode(o, result)

proc matchLen*(input: string; r: Bytecode;
               captures: var seq[(int, int)], start=0): int =
  let (isMatch, len) = execBytecode(r, input, captures, start)
  result = if isMatch <= 0: -1 else: len

proc match*(input: string; r: Bytecode;
            captures: var seq[(int, int)]; start=0): bool =
  let (isMatch, len) = execBytecode(r, input, captures, start)
  result = isMatch > 0

proc matchLen*(input: string; r: Bytecode, start=0): int =
  var captures: seq[(int, int)] = @[]
  let (isMatch, len) = execBytecode(r, input, captures, start)
  result = if isMatch <= 0: -1 else: len

proc match*(input: string; r: Bytecode; start=0): bool =
  var captures: seq[(int, int)] = @[]
  let (isMatch, len) = execBytecode(r, input, captures, start)
  result = isMatch > 0

template `=~` *(s: string, pattern: Bytecode): expr =
  ## This calls ``match`` with an implicit declared ``matches`` seq that
  ## can be used in the scope of the ``=~`` call:
  ##
  ## .. code-block:: nim
  ##
  ##   if line =~ re"\s*(\w+)\s*\=\s*(\w+)":
  ##     # matches a key=value pair:
  ##     echo("Key: ", matches[0])
  ##     echo("Value: ", matches[1])
  ##   elif line =~ re"\s*(\#.*)":
  ##     # matches a comment
  ##     # note that the implicit ``matches`` array is different from the
  ##     # ``matches`` array of the first branch
  ##     echo("comment: ", matches[0])
  ##   else:
  ##     echo("syntax error")
  ##
  var captures: seq[(int, int)] = @[]
  when not declaredInScope(matches):
    var matches {.inject.}: seq[string] = @[]
  let m = match(s, pattern, captures)
  for i in 0..high(captures):
    matches.add substr(s, captures[i][0], captures[i][1])
  m
