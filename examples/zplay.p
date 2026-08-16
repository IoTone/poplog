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

unless tl(args) == [] then
    strnumber(hd(tl(args))) -> zm_max_steps;
endunless;

zm_play(hd(args)) -> ;
