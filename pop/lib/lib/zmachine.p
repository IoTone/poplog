/* --- LIB ZMACHINE -------------------------------------------------------
 > File:            pop/lib/lib/zmachine.p
 > Purpose:         A Z-machine interpreter in Pop-11 -- play interactive fiction
 > Author:          D.Kordsmeier (@truedat101) and Claude (@claude), Aug 2026
 > Documentation:   TEACH * ZMACHINE, docs/projects/zmachine-design.md
 >
 > Loading this pulls in the whole machine:
 >
 >     zmachine_mem     the story file as byte memory
 >     zmachine_text    ZSCII decoding
 >     zmachine_obj     the object tree
 >     zmachine_dict    the dictionary and input parsing
 >     zmachine_save    save and restore
 >     zmachine_io      pluggable screen and keyboard
 >     zmachine_core    stack, frames, decoder, execution loop
 >     zmachine_ops     the instruction set
 >
 > Then:    zm_play('games/story.z3');
 */
compile_mode :pop11 +strict;

uses zmachine_mem;
uses zmachine_text;
uses zmachine_obj;
uses zmachine_io;
uses zmachine_dict;
uses zmachine_save;
uses zmachine_core;
uses zmachine_ops;
