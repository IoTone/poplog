/* examples/robotarmy/swarm.p -- robots that fall into tick over UDP.

   Each robot carries a phase and a natural rhythm of its own.  Every tick
   it broadcasts its phase to the rest of the fleet, listens for theirs, and
   pulls itself slightly towards them:

       phase' = phase + omega*dt + (K/N) * sum over peers of sin(peer - self)

   Left alone, robots with different natural rhythms drift apart forever.
   Coupled, they pull each other into lockstep -- the fleet ends up marching
   in time without any leader, clock, or central authority.  (Kuramoto's
   model; the same arithmetic describes fireflies and pendulum clocks on a
   shared beam.)

   Each robot writes its own phase history, and `--render` draws all of them
   into one image so the entrainment is visible.

       ;;; four robots, each in its own process
       for i in 0 1 2 3; do
         ./poplog basepop11 examples/robotarmy/swarm.p $i 4 &
       done
       wait
       ./poplog basepop11 examples/robotarmy/swarm.p --render 4

   No graphics build required: the output is a PPM, written by redirecting
   the character sink to a file.
*/
vars robotarmy_lib = true;
load 'examples/robotarmy/fleetnet.p';

true -> popradians;              ;;; TRAP: Poplog trig is in DEGREES by default

lconstant TWO_PI = 6.283185307179586;
lconstant BASE_PORT = 9950;      ;;; robot i listens on BASE_PORT + i
lconstant STEPS  = 240;
lconstant DT     = 0.05;
lconstant K      = 2.2;          ;;; coupling strength; 0 = every robot alone

;;; --------------------------------------------------------------- a robot

define swarm_robot(id, n);
    lvars s = net_open(BASE_PORT + id), i, j, tick, msg, sender;
    lvars phase = (id * 1.7) mod TWO_PI;          ;;; scattered start
    lvars omega = 1.0 + id * 0.35;                ;;; each its own rhythm
    lvars hist = [], peers, sum, seen, text;
    printf('robot %p: omega %p, listening on %p\n',
           [% id, omega, BASE_PORT + id %]);
    sysflush(popdevout);
    for tick from 1 to STEPS do
        ;;; tell the fleet where we are
        for j from 0 to n - 1 do
            nextif(j == id);
            net_send(s, '127.0.0.1', BASE_PORT + j,
                     net_sign('' sys_>< id sys_>< ' ' sys_>< phase));
        endfor;
        ;;; take in whatever has arrived since last tick
        0.0 -> sum; 0 -> seen;
        repeat
            net_poll_signed(s) -> (text, sender);
            quitunless(text);
            lvars sp = locchar(` `, 1, text);
            lvars peer = strnumber(allbutfirst(sp, text));
            if peer then sum + sin(peer - phase) -> sum; seen + 1 -> seen endif;
        endrepeat;
        ;;; drift, plus a nudge towards everyone we heard from
        phase + omega * DT -> phase;
        if seen > 0 then phase + (K / seen) * sum * DT -> phase endif;
        phase mod TWO_PI -> phase;
        conspair(phase, hist) -> hist;
        syssleep(2);                                ;;; ~20 ms a tick
    endfor;
    sysclose(s);
    ;;; leave our history where --render can find it.  Redirecting the
    ;;; character sink is the same trick the renderer and fthwire.p use.
    define lconstant dump();
        lvars h;
        for h in rev(hist) do printf('%p\n', [% h %]) endfor;
    enddefine;
    lvars out = discout('/tmp/swarm-' sys_>< id sys_>< '.txt');
    procedure;
        dlocal cucharout = out;
        dump();
    endprocedure();
    out(termin);
    printf('robot %p done\n', [% id %]);
enddefine;

;;; --------------------------------------------------------------- drawing

define swarm_read(id) -> l;
    lvars dev = sysopen('/tmp/swarm-' sys_>< id sys_>< '.txt', 0, "line");
    lvars rep = line_repeater(dev, inits(64)), line;
    [] -> l;
    repeat
        rep() -> line;
        quitif(line == termin);
        if strnumber(line) then conspair(strnumber(line), l) -> l endif;
    endrepeat;
    ;;; as a vector: the renderer subscripts it heavily
    {% applist(rev(l), identfn) %} -> l;
enddefine;

;;; Time runs left to right; each robot is a horizontal band; colour is
;;; phase.  Scattered bands on the left, matching bands on the right, is
;;; the fleet falling into step.
define swarm_render(n, path);
    lvars i, all = {% for i from 0 to n - 1 do swarm_read(i) endfor %};
    lvars ticks = length(subscrv(1, all));
    lvars W = 720, band = 60, H = n * band;
    define lconstant emit();
        lvars y, x, k, t, ph, r, g, b;
        printf('P3\n%p %p\n255\n', [% W, H %]);
        for y from 1 to H do
            (y - 1) div band -> k;
            for x from 1 to W do
                (((x - 1) * ticks) div W) + 1 -> t;
                subscrv(t, subscrv(k + 1, all)) -> ph;
                intof(127.0 * (1.0 + sin(ph))) -> r;
                intof(127.0 * (1.0 + sin(ph + 2.094))) -> g;
                intof(127.0 * (1.0 + sin(ph + 4.189))) -> b;
                printf('%p %p %p ', [% r, g, b %]);
            endfor;
            printf('\n', []);
        endfor;
    enddefine;
    lvars out = discout(path);
    dlocal cucharout = out;
    emit();
    out(termin);
enddefine;

;;; ------------------------------------------------------------------ main

define swarm_main();
    lvars args = poparglist;
    returnif(args == []);
    if hd(args) = '--render' then
        lvars n = strnumber(hd(tl(args)));
        swarm_render(n, '/tmp/swarm.ppm');
        printf('wrote /tmp/swarm.ppm\n', []);
    else
        swarm_robot(strnumber(hd(args)), strnumber(hd(tl(args))));
    endif;
enddefine;

unless isdefined("swarm_lib") then swarm_main() endunless;
