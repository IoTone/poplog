/* examples/zdump.p -- look inside a Z-machine story file.

   Milestone M1 of the Z-machine project (docs/projects/zmachine-design.md):
   prove that story memory, ZSCII text decoding and the object tree all
   work, by printing what is in a real game.

   Run:   ./poplog target/pop/basepop11 examples/zdump.p examples/games/czech.z3
          ./poplog target/pop/basepop11 examples/zdump.p ~/games/minizork.z3

   With a second argument 'objects' it prints the whole object tree; the
   default is a summary.  Story files are not shipped with Poplog except
   for the freely-licensed test suite -- see examples/games/README.md.
*/

uses zmachine_mem;
uses zmachine_text;
uses zmachine_obj;

vars args = poparglist;
unless args and args /== [] then
    npr('usage: zdump.p <story-file> [objects]');
    sysexit();
endunless;

vars story = hd(args), mode = if tl(args) == [] then 'summary' else hd(tl(args)) endif;

zm_load_story(story);

npr('--- header ------------------------------------------------------');
zm_header_summary();

;;; --- the abbreviations table ------------------------------------------
;;; 96 common phrases the story text refers to by number.  Decoding these
;;; exercises the whole text machine, because abbreviations are themselves
;;; ordinary packed strings.
npr('');
npr('--- abbreviations (first 12 of 96) ------------------------------');
vars i;
for i from 0 to 11 do
    printf('%p\n', [% '  ' sys_>< i sys_>< ':  "' sys_>< zm_text(zm_abbrev(i))
                        sys_>< '"' %]);
endfor;

;;; --- the object tree ----------------------------------------------------
npr('');
printf('%p\n', [% '--- objects (' sys_>< zm_obj_count()
                    sys_>< ' of them) -------------------------------' %]);

define show_object(n);
    lvars n, parent = zm_obj_parent(n), a, attrs = [], count = 0;
    ;;; which attributes are set, as a list of numbers
    for a from 0 to (if zm_version fi_<= 3 then 31 else 47 endif) do
        if zm_obj_attr(n, a) then a; count fi_+ 1 -> count endif;
    endfor;
    conslist(count) -> attrs;
    printf('%p\n', [% '  ' sys_>< n sys_>< '. "' sys_>< zm_obj_name(n) sys_>< '"'
            sys_>< (if parent /== 0 then '  in ' sys_>< parent else '' endif)
            sys_>< (if attrs /== [] then '  attrs ' sys_>< attrs else '' endif)
            %]);
enddefine;

if mode = 'objects' then
    for i from 1 to zm_obj_count() do show_object(i) endfor;
else
    for i from 1 to min(12, zm_obj_count()) do show_object(i) endfor;
    if zm_obj_count() fi_> 12 then
        printf('%p\n', [% '  ... ' sys_>< (zm_obj_count() fi_- 12)
                            sys_>< ' more (pass "objects" to see them all)' %]);
    endif;
endif;

npr('');
npr('zdump: ok');
