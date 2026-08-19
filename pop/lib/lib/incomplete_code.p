/* --- Structural precheck for Pop-11 source ------------------------------
 > File:            pop/lib/lib/incomplete_code.p
 > Purpose:         Refuse source that would leave the itemiser mid-token
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   HELP * INCOMPLETE_CODE
 > Related Files:   pop/mcp/pop11_mcp.p, pop/lsp/pop11_lsp.p,
 >                  pop/lib/lib/jsonrpc.p, tools/tests/test_jsonrpc.p
 >
 > The compiler recovers cleanly from a mishap INSIDE a complete stream:
 > the interrupt trap fires, the stack is repaired, and the session
 > carries on.  A stream that ENDS mid-token is a different matter --
 > an unclosed string, bracket or comment leaves shared itemiser state
 > that no trap can repair, and every later chunk is read as part of the
 > unfinished one.
 >
 > So any server that feeds a session code from elsewhere -- an agent
 > over MCP, an editor over LSP, a REPL over a socket -- has to refuse
 > that case up front.  This was written three times before it was
 > written once.
 >
 > Note what is deliberately NOT checked: an unfinished `define' is
 > fine.  It leaves the compiler waiting for the rest, which is exactly
 > how one builds a procedure interactively.
 */
compile_mode :pop11 +strict;

section $-incomplete => incomplete_code;

;;; -> false when the code is structurally complete, else a short
;;; description of what is unclosed.
define incomplete_code(s) -> why;
    lvars i = 1, len = length(s), c, depth = 0, cdepth, j, k;
    false -> why;
    while i <= len do
        s(i) -> c;
        if c == `;` and i + 2 <= len
        and s(i+1) == `;` and s(i+2) == `;` then
            ;;; line comment: to end of line
            while i <= len and s(i) /== `\n` do i + 1 -> i endwhile;
        elseif c == `/` and i < len and s(i+1) == `*` then
            ;;; nesting block comment
            1 -> cdepth; i + 2 -> i;
            while i <= len and cdepth > 0 do
                if s(i) == `/` and i < len and s(i+1) == `*` then
                    cdepth + 1 -> cdepth; i + 2 -> i;
                elseif s(i) == `*` and i < len and s(i+1) == `/` then
                    cdepth - 1 -> cdepth; i + 2 -> i;
                else
                    i + 1 -> i;
                endif;
            endwhile;
            if cdepth > 0 then 'unclosed /* comment' -> why; return endif;
            nextloop;
        elseif c == `'` then
            i + 1 -> i;
            while i <= len and s(i) /== `'` do
                if s(i) == `\\` then i + 1 -> i endif;
                i + 1 -> i;
            endwhile;
            if i > len then 'unterminated string' -> why; return endif;
        elseif c == `"` then
            ;;; a word: the closing quote is optional, and a newline
            ;;; ends it either way
            i + 1 -> i;
            while i <= len and s(i) /== `"` and s(i) /== `\n` do
                i + 1 -> i
            endwhile;
        elseif c == `\`` then
            ;;; a character literal, likewise closable or not; scan a
            ;;; short way for the closing backquote and give up if it
            ;;; is not there rather than swallowing the line
            false -> j;
            i + 1 -> k;
            while k <= len and s(k) /== `\n` and k <= i + 8 do
                if s(k) == `\`` then k -> j; quitloop endif;
                k + 1 -> k;
            endwhile;
            if j then j -> i else i + 1 -> i endif;
        elseif c == `(` or c == `[` or c == `{` then
            depth + 1 -> depth;
        elseif c == `)` or c == `]` or c == `}` then
            depth - 1 -> depth;
        endif;
        i + 1 -> i;
    endwhile;
    if depth > 0 then 'unclosed bracket' -> why endif;
enddefine;

endsection;
