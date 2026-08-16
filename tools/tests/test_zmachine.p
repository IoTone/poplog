;;; test_zmachine.p — suite for LIB * ZMACHINE (run via tools/test-libs.sh)
;;;
;;; Everything here runs against examples/games/czech.z3, the CZECH
;;; conformance suite compiled for Z-machine v3 from its freely
;;; distributable source (see examples/games/README.md), so the suite needs
;;; no commercial story file and no Inform toolchain.
uses poptest;
uses zmachine_mem;
uses zmachine_text;
uses zmachine_obj;

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

test_summary();
