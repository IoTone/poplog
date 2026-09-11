/* examples/robotarmy/fleet.p -- the Robot Army core.

   A fleet of robots, a registry, and an order interpreter.  Everything
   later in the Robot Army examples builds on this file:

       uses objectclass;
       load 'examples/robotarmy/fleet.p';
       muster() =>

   Run it directly for a short demonstration:

       ./poplog basepop11 examples/robotarmy/fleet.p </dev/null
*/
uses objectclass;

;;; --- a unit ------------------------------------------------------------

define :class Robot;
    slot rb_id     = "unknown";
    slot rb_kind   = "scout";      ;;; scout | sapper | medic | hauler
    slot rb_charge = 100;          ;;; percent
    slot rb_place  = "base";
enddefine;

define :method print_instance(r:Robot);
    printf('<%p %p  %p%%  at %p>\n',
           [% rb_kind(r), rb_id(r), rb_charge(r), rb_place(r) %]);
enddefine;

;;; --- the registry ------------------------------------------------------
;;; keyed by WORD: newproperty matches keys by identity, and words are
;;; interned, so "r2" is the same key every time -- a string would not be.

vars fleet = newproperty([], 64, false, true);

define enlist(id, kind) -> r;
    newRobot() -> r;
    id   -> rb_id(r);
    kind -> rb_kind(r);
    r    -> fleet(id);
enddefine;

;;; leaves every unit on the open stack -- so callers choose the container
define units();
    appproperty(fleet, procedure(k, v); v endprocedure);
enddefine;

define muster();
    [% units() %]
enddefine;

define fit_for_duty();
    lvars r;
    [% for r in muster() do
           if rb_charge(r) >= 25 then r endif
       endfor %]
enddefine;

;;; --- orders ------------------------------------------------------------
;;; An order is a list, and the matcher takes it apart.  Pattern variables
;;; must be permanent (vars): with lvars they are silently left undefined.

vars id, place, n, kind;

define obey(order) -> reply;
    lvars r;
    'unintelligible' -> reply;
    if order matches [unit ?id advance to ?place] then
        fleet(id) -> r;
        if r then
            place -> rb_place(r);
            rb_charge(r) - 10 -> rb_charge(r);
            'unit ' sys_>< id sys_>< ' advancing to ' sys_>< place -> reply
        else
            'no such unit: ' sys_>< id -> reply
        endif
    elseif order matches [unit ?id recharge ?n] then
        fleet(id) -> r;
        if r then
            min(100, rb_charge(r) + n) -> rb_charge(r);
            'unit ' sys_>< id sys_>< ' at ' sys_>< rb_charge(r) sys_>< '%' -> reply
        endif
    elseif order matches [all ?kind hold] then
        lvars held = 0;
        for r in muster() do
            if rb_kind(r) == kind then
                "base" -> rb_place(r); held + 1 -> held
            endif
        endfor;
        '' sys_>< held sys_>< ' ' sys_>< kind sys_>< ' units holding' -> reply
    elseif order matches [report] then
        '' sys_>< length(fit_for_duty()) sys_>< ' of ' sys_><
        length(muster()) sys_>< ' units fit for duty' -> reply
    endif;
enddefine;

;;; --- demonstration -----------------------------------------------------

define muster_demo();
    lvars o, r;
    enlist("r1", "scout")  -> _;
    enlist("r2", "sapper") -> _;
    enlist("r3", "medic")  -> _;
    enlist("r4", "scout")  -> _;
    20 -> rb_charge(fleet("r4"));           ;;; one unit is nearly flat

    for o in [[report]
              [unit r1 advance to ridge]
              [unit r4 recharge 60]
              [all scout hold]
              [unit r9 advance to ridge]
              [report]] do
        npr(o sys_>< '  ->  ' sys_>< obey(o));
    endfor;

    npr('');
    for r in muster() do print_instance(r) endfor;
enddefine;

;;; run the demonstration when this file is the program, not when it is
;;; loaded as a library by the other examples
unless isdefined("robotarmy_lib") then muster_demo() endunless;
