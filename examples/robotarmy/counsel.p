/* examples/robotarmy/counsel.p -- typed judgment for the command post.

   A field report arrives as prose.  Orders leave as structure.  In
   between, ts_eval asks an adviser three typed questions -- which kind of
   unit, whether a human must approve, how urgent -- and the answers come
   back as a choice, a probability and a score, not as prose to parse.

   Two advisers answer the same request (packages/typesafe/README.md,
   packages/laya/README.md):

       hosted Jev:   TYPESAFE_API_KEY=... \
                     ./poplog basepop11 examples/robotarmy/counsel.p 'report'
       local Laya:   ./poplog basepop11 examples/robotarmy/counsel.p \
                     --local 'report'

   Neither library ships in the Poplog release; both live in packages/ in
   this repository, which is why the search lists are extended here.
*/

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;

;;; --local anywhere in the arguments swaps in the on-board adviser
if member('--local', poparglist) then
    uses laya           ;;; loads typesafe too, installs the pipe transport
else
    uses typesafe
endif;

;;; one question set, built once -- the kinds come from fleet.p's roster
lvars kind = ts_choice('Which kind of unit should take this?',
                       [[scout  'look, do not touch']
                        [sapper 'clear obstacles, handle charges']
                        [medic  'casualty care']
                        [hauler 'move supplies or wreckage']]);

lvars human = ts_noul('Must a human approve before any unit moves?',
                      'force, casualties or civilians involved',
                      'routine, within standing orders');

lvars urgency = ts_score('How urgent is this?',
                         ['routine' 'prompt' 'immediate']);

define counsel(report);
    lvars report, a;
    ts_eval(report, [[kind ^kind] [human ^human] [urgency ^urgency]]) -> a;
    printf('report:  %p\n', [^report]);
    printf('send:    %p  (%p)\n',
           [% a('kind')('choice'), a('kind')('confidence') %]);
    printf('human:   %p\n', [% a('human')('noul') %]);
    printf('urgency: %p\n', [% a('urgency')('score') %]);
    printf('adviser: %p\n', [% ts_last_model %]);
enddefine;

lvars report = false, arg;
for arg in poparglist do
    unless arg = '--local' then arg -> report endunless
endfor;
unless report then
    'Culvert on the ridge road is blocked and the drone cannot see past it.'
        -> report
endunless;

counsel(report);
