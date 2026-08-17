/* examples/zplay.p -- play a Z-machine story file.

   Run:   ./poplog target/pop/basepop11 examples/zplay.p <story-file>

   Story files are not shipped with Poplog except the freely-licensed
   test suite; see examples/games/README.md.
*/
uses zmachine;

vars args = poparglist;
unless args and args /== [] then
    npr('usage: zplay.p <story-file> [max-steps]');
    sysexit();
endunless;

;;; keep saves in the current directory rather than beside the story file,
;;; which may be read-only or somebody else's tree
sys_fname_nam(hd(args)) sys_>< '.qzl' -> zm_save_file;

unless tl(args) == [] then
    strnumber(hd(tl(args))) -> zm_max_steps;
endunless;

zm_play(hd(args)) -> ;
