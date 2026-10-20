# jsonrpc_obj dropped every `false` from every reply

**Status:** fixed on `jsonrpc-false-on-the-wire`, Oct 2026.
**Affected:** `pop/lib/lib/jsonrpc.p` since Aug 2026, and through it
`pop/lsp/pop11_lsp.p` and `pop/mcp/pop11_mcp.p`. Also
`examples/langpop/server.p`, which is where it was found.

## What happened

`jsonrpc_obj` built its object from a property:

```pop11
newmapping([], 8, false, true) -> p;
...
v -> p(k);
```

Assigning a property its **default** value removes the key. The default
here was `false`, so `false -> p('flag')` stored nothing:

```
jsonrpc_obj([% 'a', 1, 'flag', false, 'b', 2 %])   generated   {"b":2,"a":1}
```

Every `false` in every JSON-RPC reply this tree sends was absent from the
wire. A false member and a missing member are different statements, and
the receiver has no way to tell which it got.

## Why nothing caught it

The sender cannot see it either. `p('flag')` is `false` whether the
member is false or was never set, so a test that reads the object back
passes. `json_parse` builds a property as well, so a test that parses the
reply *also* passes. The only place the bug is visible is the generated
text or the bytes on the socket — which is why the new checks in
`tools/tests/test_jsonrpc.p` assert on `json_generate` output and, once,
on bytes read straight off a socketpair.

## What it was actually doing

Three live call sites, reproduced on Poplog 16.02 / Darwin 25.4.0 arm64:

| Call site | Sent | Should have sent |
| --- | --- | --- |
| `pop11_lsp.p:282`, every completion that was not truncated | `{"items":[]}` | `{"isIncomplete":false,"items":[]}` |
| `pop11_lsp.p:305`, `initialize` | `{"completionProvider":{}}` | `{"completionProvider":{"resolveProvider":false}}` |
| `pop11_mcp.p:347`, every **successful** tool call | `{"content":[…]}` | `{"content":[…],"isError":false}` |

The first is a protocol violation, not a cosmetic one: `isIncomplete` is a
**required** member of an LSP `CompletionList`, and it was missing from the
common case — every completion request that returned fewer than
`COMPLETION_LIMIT` items. The other two are fields whose spec default
happens to match what was omitted, so they were wrong without being
broken.

## The fix

`jsonrpc_obj` builds a `json_object()` (LIB * JSON), which keeps its pairs
in a list and so can hold a false. All three call sites became correct
without being touched. Insertion order now survives too, so `jsonrpc`
leads a reply rather than landing wherever the hash put it. Lookup is
linear, which is the right trade for objects of this size.

## A second defect in the same file

`jsonrpc_serve` guarded its dispatch with `nextunless(isproperty(msg))`.
`json_parse` builds `json_object`s rather than properties when
`json_ordered_objects` is on, so a server that turned that flag on had
**every request silently skipped** — no reply, no error, no log. The guard
now accepts either representation.

## What to take from it

Two of these are the same mistake: a sentinel that is also a legal value.
A property's "absent" is `false` and so is a JSON `false`; `isproperty` as
a stand-in for "is a JSON object" stopped being true the moment a second
representation existed. Where a test can only see a value through the API
that conflates the two cases, it has to look at the output instead.
