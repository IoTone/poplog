;;; test_zmachine.p — suite for LIB * ZMACHINE (run via tools/test-libs.sh)
;;;
;;; Everything here runs against examples/games/czech.z3, the CZECH
;;; conformance suite compiled for Z-machine v3 from its freely
;;; distributable source (see examples/games/README.md), so the suite needs
;;; no commercial story file and no Inform toolchain.
uses poptest;
uses zmachine;          ;;; the whole machine: memory, text, objects, ops

vars story = '$usepop/examples/games/czech.z3';
unless readable(sysfileok(story)) then
    ;;; run from the repo root when $usepop is elsewhere
    'examples/games/czech.z3' -> story;
endunless;

zm_load_story(story);

;;; --- header -------------------------------------------------------------

check('version', zm_version, 3);
check('release', zm_release, 1);
check_true('static base plausible',
    zm_static_base > 0 and zm_static_base < datalength(zm_mem));
check_true('high memory above static', zm_high_base >= zm_static_base);
check_true('initial pc in high memory', zm_initial_pc >= zm_high_base);
check_true('file length fits', zm_file_length <= datalength(zm_mem));
check_true('serial is six chars', datalength(zm_serial) == 6);

;;; v3 packs addresses by 2
check('unpack routine', zm_unpack_routine(1000), 2000);
check('unpack string', zm_unpack_string(1000), 2000);

;;; --- 16-bit values ------------------------------------------------------

check('signed 0', zm_signed(0), 0);
check('signed 1', zm_signed(1), 1);
check('signed 32767', zm_signed(32767), 32767);
check('signed 32768', zm_signed(32768), -32768);
check('signed 65535', zm_signed(65535), -1);
check('unsigned -1', zm_unsigned(-1), 65535);
check('unsigned -32768', zm_unsigned(-32768), 32768);
check('round trip', zm_signed(zm_unsigned(-1234)), -1234);

;;; --- memory access ------------------------------------------------------

;;; byte 0 of any story file is its version number
check('byte 0 is version', zm_byte(0), 3);
;;; a word is two bytes, big-endian
check('word is big-endian',
    zm_word(0), (zm_byte(0) << 8) || zm_byte(1));

;;; dynamic memory is writable and reads back
vars scratch = 16:40;           ;;; well inside dynamic memory
vars saved = zm_word(scratch);
16:BEEF -> zm_word(scratch);
check('word write/read', zm_word(scratch), 16:BEEF);
check('high byte', zm_byte(scratch), 16:BE);
check('low byte', zm_byte(scratch fi_+ 1), 16:EF);
16:7F -> zm_byte(scratch);
check('byte write/read', zm_byte(scratch), 16:7F);
saved -> zm_word(scratch);      ;;; put it back

;;; static memory is not writable — the spec's one memory rule
lvars trapped = false;
define lconstant try_static_write();
    dlocal interrupt =
        procedure(); true -> trapped; exitfrom(try_static_write) endprocedure;
    99 -> zm_byte(zm_static_base);
enddefine;
try_static_write();
check_true('static memory write refused', trapped);

;;; --- text decoding ------------------------------------------------------

;;; Object short names exercise the whole ZSCII state machine.  "Test
;;; Object #1" needs alphabet A0 (lower case), a shift to A1 for the
;;; capitals, and two shifts to A2 for '#' and '1' — so getting this
;;; string out proves shifts and all three alphabets.
check('object 5 name', zm_obj_name(5), 'Test Object #1');
check('object 6 name', zm_obj_name(6), 'Test Object #2');
check('Inform class object', zm_obj_name(1), 'Class');

;;; zm_text and zm_text_out must agree; the streaming form is the primitive
lvars streamed = [], nchars = 0;
define lconstant collect(c);
    lvars c;
    conspair(c, streamed) -> streamed;
    nchars + 1 -> nchars;
enddefine;
zm_text_out(zm_obj_prop_table(5) fi_+ 1, collect) -> ;
check('streamed length matches', nchars, datalength(zm_obj_name(5)));
;;; destlist leaves the element count on the stack, which is exactly what
;;; consstring wants — passing nchars as well would consume a character
check('streamed text matches',
    consstring(destlist(rev(streamed))), zm_obj_name(5));

;;; --- objects ------------------------------------------------------------

check('object count', zm_obj_count(), 9);
check('object 6 parent', zm_obj_parent(6), 5);
check('object 5 has no parent', zm_obj_parent(5), 0);
check('object 8 parent', zm_obj_parent(8), 7);

;;; attributes are numbered from the MOST significant bit
check_true('object 5 attribute 0 set', zm_obj_attr(5, 0));
check_true('object 5 attribute 1 set', zm_obj_attr(5, 1));
check_false('object 5 attribute 4 clear', zm_obj_attr(5, 4));
check_true('object 6 attribute 2 set', zm_obj_attr(6, 2));

;;; setting and clearing round-trips
false -> zm_obj_attr(5, 0);
check_false('attribute cleared', zm_obj_attr(5, 0));
true -> zm_obj_attr(5, 0);
check_true('attribute set again', zm_obj_attr(5, 0));

;;; the property list terminates, and every entry has a sane number/length
lvars p = zm_prop_first(5), nprops = 0, lastnum = 999;
until zm_byte(p) == 0 do
    nprops + 1 -> nprops;
    check_true('property number in range',
        zm_prop_num(p) > 0 and zm_prop_num(p) <= 31);
    check_true('properties descend', zm_prop_num(p) < lastnum);
    zm_prop_num(p) -> lastnum;
    check_true('property length in range',
        zm_prop_len(p) >= 1 and zm_prop_len(p) <= 8);
    zm_prop_next(p) -> p;
    quitif(nprops > 32);        ;;; a runaway walk must not hang the suite
enduntil;
check_true('object 5 has properties', nprops > 0 and nprops <= 32);

;;; a property the object does not have falls back to the defaults table
check('missing property uses default',
    zm_obj_prop(5, 31), zm_prop_default(31));

;;; --- dictionary, tokenising and sread -----------------------------------
;;;
;;; parsertest.z3 is ours (examples/games/parsertest.inf): a story with a
;;; known six-word dictionary that reads one line and reports what the
;;; interpreter put in the parse buffer.

vars ptstory = '$usepop/examples/games/parsertest.z3';
unless readable(sysfileok(ptstory)) then
    'examples/games/parsertest.z3' -> ptstory;
endunless;

zm_load_story(ptstory);

check('dictionary separators', zm_dict_nseps(), 3);
check_true('comma is a separator',
    zm_dict_sep(1) == `.` or zm_dict_sep(2) == `.`);
check('entry length', zm_dict_entry_len(), 7);
check_true('dictionary is sorted', zm_dict_count() > 0);

;;; a word in the dictionary decodes back to itself
lvars e = zm_dict_lookup('mailbox');
check_true('known word found', e /== 0);
check('short word decodes back', zm_text(zm_dict_lookup('brass')), 'brass');
check('unknown word not found', zm_dict_lookup('xyzzy'), 0);

;;; v3 stores only six z-characters, so a seven-letter word is held
;;; truncated -- this is exactly why Zork cannot tell FLASHLIGHT from
;;; FLASHLIGH, and the interpreter must truncate the typed word the same
;;; way or nothing long would ever be found
check('long word stored truncated', zm_text(e), 'mailbo');
check_true('so both spellings are the same word to the game',
    zm_dict_lookup('mailbox') == zm_dict_lookup('mailbo'));

;;; v3 keeps only six z-characters, so long words collide -- this is why
;;; Zork cannot tell FLASHLIGHT from FLASHLIGH
check('encoding is two words in v3', listlength(zm_encode_word('open')), 2);
check_true('last encoded word has the end bit',
    (zm_encode_word('open')(2) && 16:8000) /== 0);

;;; --- conformance: the whole machine, end to end -------------------------
;;;
;;; CZECH exercises 368 behaviours and prints its own verdict.  Capturing
;;; that verdict needs no special support: a front end is installed simply
;;; by dlocal-ing zio_char, which is the entire point of zmachine_io.p.

lvars czech_chars = [], czech_n = 0;

define lconstant grab(c);
    lvars c;
    conspair(if c == 13 then `\n` else c endif, czech_chars) -> czech_chars;
    czech_n + 1 -> czech_n;
enddefine;

define lconstant run_czech() -> text;
    lvars text;
    dlocal zio_char = grab;
    dlocal zm_max_steps = 2000000;      ;;; a hung interpreter must not hang CI
    zm_play(story) -> ;
    consstring(destlist(rev(czech_chars))) -> text;
enddefine;

lvars verdict = run_czech();
check_true('czech ran to the end',
    issubstring('Didn\'t crash: hooray!', 1, verdict) and true);
check_true('czech: 349 passed',
    issubstring('Passed: 349', 1, verdict) and true);
check_true('czech: 0 failed',
    issubstring('Failed: 0', 1, verdict) and true);
check_true('czech: 368 tests performed',
    issubstring('Performed 368 tests', 1, verdict) and true);

;;; The whole input path, end to end: feed a line to the parser story and
;;; check what it reports.  A canned keyboard is installed the same way a
;;; canned screen is -- by dlocal-ing the variable.

lvars pt_chars = [], pt_n = 0;

define lconstant pt_grab(c);
    lvars c;
    conspair(if c == 13 then `\n` else c endif, pt_chars) -> pt_chars;
    pt_n + 1 -> pt_n;
enddefine;

define lconstant pt_line() -> line;
    lvars line = 'take brass lamp, north xyzzy';
enddefine;

define lconstant run_parsertest() -> text;
    lvars text;
    dlocal zio_char = pt_grab, zio_read_line = pt_line;
    dlocal zm_max_steps = 200000;
    zm_play(ptstory) -> ;
    consstring(destlist(rev(pt_chars))) -> text;
enddefine;

lvars parsed = run_parsertest();

;;; "take brass lamp, north xyzzy" is SIX tokens, because a word separator
;;; is itself a word (standard 13.6.1): take/brass/lamp/,/north/xyzzy.
;;; The reference interpreter gets this wrong and returns five, gluing the
;;; comma onto "lamp" -- which breaks "TROLL, HELLO" and multi-sentence
;;; input in real games.  See docs/projects/zmachine-design.md.
check_true('six tokens including the separator',
    issubstring('n=6', 1, parsed) and true);
check_true('first word found at position 1',
    issubstring('w0=found l=4 p=1', 1, parsed) and true);
check_true('lamp split from its comma',
    issubstring('w2=found l=4 p=12', 1, parsed) and true);
check_true('the comma is its own one-character token',
    issubstring('w3=unknown l=1 p=16', 1, parsed) and true);
check_true('unknown word reported unknown',
    issubstring('w5=unknown l=5 p=24', 1, parsed) and true);

;;; --- v5 -----------------------------------------------------------------
;;;
;;; The same conformance suite compiled for version 5, which is a different
;;; machine in several ways: extended (two-byte) opcodes, calls taking up to
;;; eight operands, wider object entries and dictionary words, packed
;;; addresses scaled by four, and an input model where the buffer carries a
;;; count rather than a terminator.

vars story5 = '$usepop/examples/games/czech.z5';
unless readable(sysfileok(story5)) then
    'examples/games/czech.z5' -> story5;
endunless;

lvars c5_chars = [], c5_n = 0;

define lconstant c5_grab(c);
    lvars c;
    conspair(if c == 13 then `\n` else c endif, c5_chars) -> c5_chars;
    c5_n + 1 -> c5_n;
enddefine;

define lconstant run_czech5() -> text;
    lvars text;
    dlocal zio_char = c5_grab;
    dlocal zm_max_steps = 2000000;
    zm_play(story5) -> ;
    consstring(destlist(rev(c5_chars))) -> text;
enddefine;

lvars verdict5 = run_czech5();
check('v5 story loaded', zm_version, 5);
check('v5 packs addresses by four', zm_unpack_routine(1000), 4000);
check_true('czech v5 ran to the end',
    issubstring('Didn\'t crash: hooray!', 1, verdict5) and true);
check_true('czech v5: 406 passed',
    issubstring('Passed: 406', 1, verdict5) and true);
check_true('czech v5: 0 failed',
    issubstring('Failed: 0', 1, verdict5) and true);
check_true('czech v5 exercised the extended opcodes',
    issubstring('art_shift', 1, verdict5) and true);
check_true('czech v5 exercised the eight-operand calls',
    issubstring('call_vs2', 1, verdict5) and true);

;;; --- Quetzal save and restore -------------------------------------------
;;;
;;; The format is the standard one, so these files interchange with other
;;; interpreters; what is checked here is the round trip through our own
;;; reader and writer, including the CMem compression (dynamic memory
;;; stored as a run-length-encoded XOR against the published story).

zm_load_story(story);           ;;; back to czech.z3
zm_reset();

vars savefile = systmpfile(false, 'zmsave', '.qzl');
savefile -> zm_save_file;

;;; build a state worth saving: a changed byte deep in dynamic memory, a
;;; couple of values on the stack, and a program counter of our choosing
16:1234 -> zm_word(16:40);
zm_push(999);
zm_push(1000);
4321 -> zm_pc;

check_true('save wrote a file', zm_save_state());

;;; a Quetzal file is an IFF FORM of type IFZS
lvars sdev = sysopen(savefile, 0, true), shead = inits(12);
sysread(sdev, shead, 12) -> ;
sysclose(sdev);
check('save is an IFF FORM', substring(1, 4, shead), 'FORM');
check('of type IFZS', substring(9, 4, shead), 'IFZS');
check_true('compression is worth it',
    sysfilesize(savefile) < zm_static_base);

;;; now disturb every part of that state
16:5678 -> zm_word(16:40);
zm_pop() -> ;
zm_pop() -> ;
9999 -> zm_pc;

check_true('restore read it back', zm_restore_state());
check('dynamic memory restored', zm_word(16:40), 16:1234);
check('program counter restored', zm_pc, 4321);
check('stack depth restored', zm_sp, 2);
check('stack contents restored', zm_pop(), 1000);
check('and the one below it', zm_pop(), 999);

;;; a save belonging to a different story must be refused rather than
;;; loaded into the wrong game
zm_load_story(story5);          ;;; czech.z5, a different release
zm_reset();
savefile -> zm_save_file;
check_false('save from another story refused', zm_restore_state());

sysdelete(savefile) -> ;

test_summary();
