# Reverse engineering with ReVa

You are driving Ghidra through the ReVa MCP server. ReVa acts on whichever program
Ghidra currently has open — you cannot switch programs, and its tools are not a
filesystem interface.

The binary in Ghidra is the ground truth. Your job is to explain it, not to build or
change software, so the usual coding-agent reflexes — run the tests, fix the build, make
the edit — do not apply unless asked for directly.

## Reference source, when there is any

You may be started inside a source tree that is *related* to the binary: the upstream
project it was built from, an SDK, a vendor drop, a different version of the same
component. When that happens the source is a **hint, not an answer**, and it is there
because it was deliberately provided — read it.

Use it for what it is good at: naming, struct and enum layouts, constants, protocol and
algorithm shape, and the intent behind a function. Those transfer even across versions,
and recovering them from the binary alone is expensive.

Do not trust it for anything you can check in the binary:

- **It may be a different version.** Functions get added, reordered, inlined away, or
  changed outright between the source you have and the build you are looking at.
- **The compiler rewrites things.** Inlining, unrolling, vectorisation, tail merging,
  layout and padding, dead-code removal and constant folding all mean the shape of the
  disassembly may not match the shape of the source even when they correspond.
- **Build configuration matters.** Ifdefs, feature flags, target architecture and
  optimisation level can mean whole branches in the source were never compiled in.

So: form a hypothesis from the source, then confirm it against the binary through ReVa
before you rely on it. Say which of the two a claim came from — "the source calls this
`aes_expand_key`, and the constant table at 0x… matches" is a finding; "the source calls
this `aes_expand_key`" alone is a guess. When the two genuinely disagree, the binary wins,
and the disagreement is itself worth reporting.

Treat the tree as read-only evidence. Do not modify, build, test or "fix" it unless you
are explicitly asked to.

## Context budget

Retrieve functions **individually**. Never request bulk decompilation of a binary:
a single large function can consume tens of thousands of tokens, and decompiler
output is by far the dominant consumer of the context window. Locate first
(symbol/xref/string search), then decompile only the specific function you need.

If you catch yourself about to iterate over a function list decompiling each entry,
stop and narrow the search instead.

Where a reference source tree is available, grepping it is far cheaper than decompiling
to find your bearings. Use it to work out *what to look for* — the function name, the
constant, the string, the struct — then go to the binary for that one thing.

## Arithmetic and bit twiddling: shell out, never compute in your head

You are bad at this and you will get it wrong silently. Shell out to python3 — one shell
call is vastly cheaper than a wrong value that sends you down a dead branch:

    python3 -c 'print(hex(0x40000000 + 0x1a2b8))'

That form is pre-approved and will not prompt. Use it freely, including with imports
(`python3 -c 'import struct; ...'`), which is also pre-approved.

**Never** compute any of the following mentally or by "reasoning through" them:

- **Hex/decimal conversion**, address offsets, page boundaries, alignment and rounding.
- **Struct field offsets.** Never hand-sum field sizes.
- **Masks, flag tests and bit extraction** — AND/OR/XOR/NOT, "is bit N set", extracting a
  field from a packed word.
- **Shifts and rotates**, especially rotates, which have no Python operator and which you
  will approximate wrongly if you improvise them.
- **Signed/unsigned reinterpretation** — two's complement, sign extension from a narrower
  width, "what is this 32-bit value as a signed int".
- **Endianness swaps.** Byte order is a frequent source of silent error on firmware images.
- **Float/int bit reinterpretation** — reading a word as an IEEE-754 float or vice versa.

These are more dangerous than plain addition, not less. A wrong sum usually produces an
address that is obviously out of range and gets caught. A wrong sign extension, mask test
or byte swap produces a *plausible* value that survives review and quietly corrupts every
conclusion built on top of it.

Worked forms for the ones that are easiest to fake convincingly:

    # signed interpretation of a 32-bit word, and sign extension from 12 bits
    python3 -c 'import struct; print(struct.unpack("<i", struct.pack("<I", 0xfffffff6))[0])'
    python3 -c 'v=0xa5c; print((v ^ 0x800) - 0x800)'

    # is bit 12 set; extract bits 20:16
    python3 -c 'print(bool(0x1a2b8 & (1 << 12)))'
    python3 -c 'print((0xdeadbeef >> 16) & 0x1f)'

    # rotate right, 32-bit
    python3 -c 'v,n=0xdeadbeef,8; print(hex(((v >> n) | (v << (32-n))) & 0xffffffff))'

    # endianness swap, 32-bit
    python3 -c 'import struct; print(hex(struct.unpack("<I", struct.pack(">I", 0xdeadbeef))[0]))'

    # word as IEEE-754 float
    python3 -c 'import struct; print(struct.unpack("<f", struct.pack("<I", 0x40490fdb))[0])'

If you find yourself about to write out any of this in prose, that is the signal to call
python3 instead.

ReVa itself has **no calculator tool**, and its `run-script` tool cannot help: it
requires Ghidra to have been launched via PyGhidra, and this install uses the stock
launcher, so every call returns "Python is not available". Do not keep retrying it.

## Prefer the tools that make arithmetic unnecessary

Much of the address arithmetic in this workflow is avoidable — ReVa will compute it for you
and be right. Reach for these before doing any math at all:

- Struct field offsets — `get-structure-info`, `parse-c-structure`, `list-structures`.
  Never hand-sum field sizes to find an offset. `get-structure-info` also resolves
  **bitfield** positions, which is the one bit-manipulation case ReVa can do for you.
- Vtable slots — `analyze-vtable`, `find-vtables-containing-function`,
  `find-vtable-callers`. Never multiply an index by pointer size yourself.
- Branch and call targets — `find-cross-references`, `get-call-graph`, `get-call-tree`,
  `get-callers-decompiled`, `get-referencers-decompiled`, `resolve-thunk`. Never decode
  a relative branch displacement by hand.
- Where a value comes from or goes — `trace-data-flow-backward`,
  `trace-data-flow-forward`, `find-variable-accesses`.
- Load addresses and segment bounds — `get-memory-blocks`. Never assume an image base;
  on AArch64 firmware images it is frequently not what you would guess.
- A specific constant — `find-constant-uses`, `find-constants-in-range`,
  `list-common-constants`. Search for it rather than deriving it.
- Bytes or data at an address — `read-memory`, `get-data`.

Note the limit: ReVa has no bit-manipulation tools beyond bitfield layout. For masks, sign
extension, rotates and byte swaps, python3 is genuinely the right answer — reach for it
directly rather than hunting for a ReVa tool that does not exist.

## Write operations

ReVa can comment, label, retype, rename locals, create and delete structures and write
scripts in the **live** program. These are real edits to the analyst's database, not a
scratch buffer, and **nothing will stop you** — every ReVa tool executes without asking for
confirmation, including all the destructive ones. You are the only check on this.

So: before any batch of edits, confirm with the analyst that the open project is a copy
rather than the primary one. Prefer one edit at a time with a stated justification over
speculative bulk changes. If you are unsure whether an edit is right, say so and leave it —
an un-renamed function costs a minute; a database full of confident wrong names costs the
analyst their trust in everything else in it, including the parts you got right.

A reference source tree is the best source of names there is, and porting them in is one
of the most valuable things you can do — but it is also the easiest way to write a
confident lie into the database. Rename from source only once you have matched the
function to the binary on evidence (constants, call graph, string references, structure),
not on plausibility of name or position. A wrong name is worse than no name: it will be
believed later, by you and by the analyst.

## Single-program scope

Multi-binary work needs a separate session per binary (or headless Ghidra). Do not
assume symbols from one binary are visible while another is open.

## Malformed tool calls

If your tool calls come back rejected, that is an inference-side problem (tool-call
parser or quantization on the vLLM host), not something to work around by pasting
JSON into prose. Report it and stop.
