/* --- Z-machine story memory ---------------------------------------------
 > File:            pop/lib/lib/zmachine_mem.p
 > Purpose:         Story-file loading and memory access for LIB * ZMACHINE
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > The Z-machine's memory is a flat array of bytes, which is exactly what a
 > Pop-11 string is (REF * STRINGS: "each element is an unsigned byte").  So
 > the story file IS the string -- no new datatype, no copying, and
 > -fast_subscrs- gives us the raw byte at machine speed.
 >
 > Z-machine addresses are 0-based and Pop-11 subscripts are 1-based, which
 > is the +1 you will see throughout.  Keeping that conversion in exactly
 > two procedures (-zm_byte- and -zm_word-) is why it never goes wrong
 > anywhere else.
 */
compile_mode :pop11 +strict;

section $-zmachine =>
        zm_mem zm_version zm_load_story zm_story_file
        zm_byte zm_word zm_signed zm_unsigned
        zm_unpack_routine zm_unpack_string
        zm_static_base zm_high_base zm_initial_pc
        zm_dict_addr zm_obj_table zm_globals zm_abbrev_table
        zm_file_length zm_checksum zm_release zm_serial
        zm_header_summary
    ;

vars
    zm_mem          = false,    ;;; the story file, as a byte string
    zm_story_file   = false,    ;;; where it came from
    zm_version      = 0,
    ;;; header fields, all filled in by -zm_load_story-
    zm_static_base  = 0,
    zm_high_base    = 0,
    zm_initial_pc   = 0,
    zm_dict_addr    = 0,
    zm_obj_table    = 0,
    zm_globals      = 0,
    zm_abbrev_table = 0,
    zm_file_length  = 0,
    zm_checksum     = 0,
    zm_release      = 0,
    zm_serial       = false,
    ;;; packed-address unpacking differs by version, so it is decided ONCE
    ;;; at load time and installed here rather than tested per call
    procedure zm_unpack_routine = identfn,
    procedure zm_unpack_string  = identfn,
    ;

;;; --- byte and word access ---------------------------------------------

;;; Both have updaters, so reading and writing look the same at the call
;;; site:   zm_byte(addr) -> b        and       b -> zm_byte(addr)

define zm_byte(addr);
    lvars addr;
    fast_subscrs(addr fi_+ 1, zm_mem)
enddefine;

define updaterof zm_byte(val, addr);
    lvars val, addr;
    ;;; The spec's one memory rule: only dynamic memory (below the static
    ;;; base) may be written.  Enforced here, once, naming the address.
    if addr fi_>= zm_static_base then
        mishap(addr, 1, 'zmachine: write to static memory')
    endif;
    (val fi_&& 16:FF) -> fast_subscrs(addr fi_+ 1, zm_mem)
enddefine;

define zm_word(addr);
    lvars addr;
    (fast_subscrs(addr fi_+ 1, zm_mem) fi_<< 8)
        fi_|| fast_subscrs(addr fi_+ 2, zm_mem)
enddefine;

define updaterof zm_word(val, addr);
    lvars val, addr;
    if addr fi_>= zm_static_base then
        mishap(addr, 1, 'zmachine: write to static memory')
    endif;
    ((val fi_>> 8) fi_&& 16:FF) -> fast_subscrs(addr fi_+ 1, zm_mem);
    (val fi_&& 16:FF)           -> fast_subscrs(addr fi_+ 2, zm_mem);
enddefine;

;;; --- 16-bit values ------------------------------------------------------

;;; Everything in memory is an unsigned 16-bit word; the arithmetic opcodes
;;; read their operands as SIGNED.  Mixing the two up is the classic
;;; Z-machine bug, so the conversion is never written inline.

define zm_signed(v);
    lvars v;
    if v fi_>= 16:8000 then v fi_- 16:10000 else v endif
enddefine;

define zm_unsigned(v);
    lvars v;
    v fi_&& 16:FFFF
enddefine;

;;; --- loading ------------------------------------------------------------

define lconstant read_bytes(path) -> s;
    lvars path, dev, len, n, s;
    unless (readable(path) ->> dev) then
        mishap(path, 1, 'zmachine: cannot open story file')
    endunless;
    sysclose(dev);
    sysfilesize(path) -> len;
    if len fi_< 64 then
        mishap(path, 1, 'zmachine: story file shorter than its header')
    endif;
    ;;; org true = raw bytes, not text (REF * SYSIO)
    sysopen(path, 0, true) -> dev;
    inits(len) -> s;
    sysread(dev, s, len) -> n;
    sysclose(dev);
    unless n == len then
        mishap(path, 1, 'zmachine: short read on story file')
    endunless;
enddefine;

define zm_load_story(path);
    lvars path;

    read_bytes(path) -> zm_mem;
    path -> zm_story_file;

    ;;; The version byte governs every layout decision below, so it is read
    ;;; before anything else trusts the file.
    zm_byte(16:00) -> zm_version;
    unless zm_version == 3 or zm_version == 5 or zm_version == 8 then
        mishap(zm_version, 1,
            'zmachine: unsupported story version (this build does 3, 5, 8)')
    endunless;

    ;;; static base first: the zm_word updater checks against it
    zm_word(16:0E) -> zm_static_base;

    zm_word(16:02) -> zm_release;
    zm_word(16:04) -> zm_high_base;
    zm_word(16:06) -> zm_initial_pc;
    zm_word(16:08) -> zm_dict_addr;
    zm_word(16:0A) -> zm_obj_table;
    zm_word(16:0C) -> zm_globals;
    zm_word(16:18) -> zm_abbrev_table;
    zm_word(16:1C) -> zm_checksum;

    ;;; serial number: six ASCII characters, usually YYMMDD
    substring(16:12 fi_+ 1, 6, zm_mem) -> zm_serial;

    ;;; The stored file length is divided by 2 (v1-3), 4 (v4-5) or 8 (v6-8);
    ;;; the same scale factor unpacks addresses in v1-5.
    if zm_version fi_<= 3 then
        zm_word(16:1A) fi_* 2 -> zm_file_length;
        procedure(p); lvars p; p fi_* 2 endprocedure
    elseif zm_version fi_<= 5 then
        zm_word(16:1A) fi_* 4 -> zm_file_length;
        procedure(p); lvars p; p fi_* 4 endprocedure
    else                            ;;; v8
        zm_word(16:1A) fi_* 8 -> zm_file_length;
        procedure(p); lvars p; p fi_* 8 endprocedure
    endif ->> zm_unpack_routine -> zm_unpack_string;

    ;;; A truncated story file is a common and confusing failure; catch it
    ;;; here rather than as a wild memory read a thousand instructions in.
    if zm_file_length fi_> 0 and zm_file_length fi_> datalength(zm_mem) then
        mishap(zm_file_length, datalength(zm_mem), 2,
            'zmachine: story file shorter than its header says')
    endif;
enddefine;

;;; --- a human-readable header, for bring-up and for TEACH ----------------

define zm_header_summary();
    printf('%p\n', [% 'story    ' sys_>< zm_story_file %]);
    printf('%p\n', [% 'version  ' sys_>< zm_version %]);
    printf('%p\n', [% 'release  ' sys_>< zm_release
                        sys_>< ' / serial ' sys_>< zm_serial %]);
    printf('%p\n', [% 'length   ' sys_>< zm_file_length
                        sys_>< ' bytes (file is '
                        sys_>< datalength(zm_mem) sys_>< ')' %]);
    printf('%p\n', [% 'checksum ' sys_>< zm_checksum %]);
    printf('%p\n', [% 'dynamic  0 .. ' sys_>< (zm_static_base fi_- 1) %]);
    printf('%p\n', [% 'static   ' sys_>< zm_static_base
                        sys_>< ' .. ' sys_>< (zm_high_base fi_- 1) %]);
    printf('%p\n', [% 'high     ' sys_>< zm_high_base sys_>< ' ..' %]);
    printf('%p\n', [% 'initial PC   ' sys_>< zm_initial_pc %]);
    printf('%p\n', [% 'dictionary   ' sys_>< zm_dict_addr %]);
    printf('%p\n', [% 'object table ' sys_>< zm_obj_table %]);
    printf('%p\n', [% 'globals      ' sys_>< zm_globals %]);
    printf('%p\n', [% 'abbreviations ' sys_>< zm_abbrev_table %]);
enddefine;

endsection;
