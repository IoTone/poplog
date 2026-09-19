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
uses strutils;

true -> popradians;              ;;; TRAP: Poplog trig is in DEGREES by default

lconstant TWO_PI = 6.283185307179586;
lconstant BASE_PORT = 9950;      ;;; robot i listens on BASE_PORT + i

;;; Where the other robots are.  All on one machine by default; pass a
;;; comma-separated host list as the third argument to spread the fleet
;;; across real machines -- the coupling does not care which, a peer being
;;; just a host and a port.
vars swarm_hosts = false;        ;;; false => everyone on 127.0.0.1
vars swarm_watch = false;        ;;; 'host:port' of a passive observer, or false
;;; Defaults reproduce the figure in the book.  The environment overrides
;;; them so a live demo can run long and couple gently enough to watch the
;;; fleet actually fall into step, rather than locking in the first second.
;;;
;;;     SWARM_STEPS   ticks to run          (default 240)
;;;     SWARM_K       coupling strength     (default 2.2, 0 = every robot alone)
;;;     SWARM_TICK    milliseconds a tick   (default 20, real time only)
;;;     SWARM_DT      model timestep        (default 0.05, fallback only)
;;;     SWARM_SECONDS run for this many seconds instead of a tick count
;;;
;;; DT is the model's timestep and TICK_MS is wall-clock pacing; they are
;;; deliberately independent, so slowing the demo down to watch it does not
;;; change the dynamics being watched.

define lconstant envnum(name, dflt) -> v;
    lvars e = systranslate(name);
    if e and strnumber(e) then strnumber(e) else dflt endif -> v;
enddefine;

lconstant STEPS   = envnum('SWARM_STEPS', 240);
lconstant TICK_MS = envnum('SWARM_TICK', 20);
lconstant DT      = envnum('SWARM_DT', 0.05);
lconstant K       = envnum('SWARM_K', 2.2);
lconstant PEER_STALE = 2.0;      ;;; seconds before a silent peer is dropped
lconstant CLOCK_JUMP = 1.0;      ;;; a dt larger than this is a clock step
;;; Once a tick is no longer a fixed length, a tick COUNT is not a duration:
;;; 1200 ticks is 30s on a machine that ticks at 25ms and 24s on one that
;;; ticks at 20ms, so the fleet stops in pieces.  Ending on the clock instead
;;; keeps the fleet together -- the same reason the dynamics now run on it.
lconstant RUN_SECS = envnum('SWARM_SECONDS', 0);

;;; Pop-11 printf has no %5.3f, and '\033' is not a Pop-11 string escape.
;;; Build the escape from its character code and round by hand.
lconstant ESC = consstring(27, 1);

define lconstant d3(x) -> s;
    intof(x * 1000.0) / 1000.0 -> s;
enddefine;


;;; --------------------------------------------------------------- a robot

define swarm_peer(j) -> host;
    if swarm_hosts then
        lvars l = swarm_hosts;
        until j == 0 or tl(l) == [] do tl(l) -> l; j - 1 -> j enduntil;
        hd(l) -> host;
    else
        '127.0.0.1' -> host;
    endif;
enddefine;

define swarm_robot(id, n);
    lvars s = net_open(BASE_PORT + id), i, j, tick, sender;
    lvars phase = (id * 1.7) mod TWO_PI;          ;;; scattered start
    lvars omega = 1.0 + id * 0.35;                ;;; each its own rhythm
    lvars hist = [], sum, seen, text, heard = 0;
    ;;; What we last heard from each peer, and WHEN WE HEARD IT by our own
    ;;; clock.  Stamping on arrival rather than carrying the sender's clock
    ;;; is the whole point: extrapolating from a local receipt time needs
    ;;; the two machines to agree on the length of a second, but never on
    ;;; what time it is.  No NTP, no offset estimation, no shared epoch.
    lvars p_phase = initv(n), p_omega = initv(n), p_at = initv(n);
    for i from 1 to n do
        false -> subscrv(i, p_phase);
        0.0   -> subscrv(i, p_omega);
        0     -> subscrv(i, p_at);
    endfor;
    lvars last = sys_microtime(), now, dt, age;
    printf('robot %p: omega %p, listening on %p\n',
           [% id, omega, BASE_PORT + id %]);
    sysflush(popdevout);
    lvars started = last, running = true;
    1 -> tick;
    while running do
        ;;; Say where we are AND how fast we run, so a listener can carry
        ;;; our phase forward instead of treating a stale number as current.
        lvars wire = net_sign('' sys_>< id sys_>< ' ' sys_>< phase
                                 sys_>< ' ' sys_>< omega);
        for j from 0 to n - 1 do
            nextif(j == id);
            net_send(s, swarm_peer(j), BASE_PORT + j, wire);
        endfor;
        ;;; A watcher is a passive observer: robots copy their phase to it,
        ;;; it never sends anything back, so it cannot perturb the dynamics.
        if swarm_watch then
            lvars c = locchar(`:`, 1, swarm_watch);
            net_send(s, substring(1, c - 1, swarm_watch),
                     strnumber(allbutfirst(c, swarm_watch)), wire);
        endif;
        ;;; take in whatever has arrived, and remember it per peer
        repeat
            net_poll_signed(s) -> (text, sender);
            quitunless(text);
            lvars f = str_split(text, ` `);
            nextunless(length(f) >= 3);
            lvars who = strnumber(hd(f)),
                 ph  = strnumber(hd(tl(f))),
                 om  = strnumber(hd(tl(tl(f))));
            nextunless(who and ph and om and who >= 0 and who < n);
            ph  -> subscrv(who + 1, p_phase);
            om  -> subscrv(who + 1, p_omega);
            sys_microtime() -> subscrv(who + 1, p_at);
            heard + 1 -> heard;
        endrepeat;
        ;;; Couple to every peer we have ever heard from, carrying its last
        ;;; known phase forward by its own omega over the time since it
        ;;; arrived.  A peer that has gone quiet for PEER_STALE seconds is
        ;;; dropped: extrapolating indefinitely is inventing data.
        sys_microtime() -> now;
        0.0 -> sum; 0 -> seen;
        for j from 0 to n - 1 do
            nextif(j == id);
            nextunless(subscrv(j + 1, p_phase));
            (now - subscrv(j + 1, p_at)) / 1000000.0 -> age;
            nextif(age > PEER_STALE);
            sum + sin(subscrv(j + 1, p_phase)
                      + subscrv(j + 1, p_omega) * age - phase) -> sum;
            seen + 1 -> seen;
        endfor;
        ;;; Advance by the time that ACTUALLY passed, not by a nominal tick.
        ;;; A machine whose loop is slower simply takes a bigger step, so a
        ;;; 25ms tick and a 20ms tick describe the same trajectory.
        (now - last) / 1000000.0 -> dt;
        if dt < 0.0 or dt > CLOCK_JUMP then DT -> dt endif;   ;;; clock step
        now -> last;
        phase + omega * dt -> phase;
        if seen > 0 then phase + (K / seen) * sum * dt -> phase endif;
        phase mod TWO_PI -> phase;
        ;;; history is (time, phase): with real timesteps, tick number is no
        ;;; longer a common axis between machines -- only the clock is.
        conspair([% now, phase %], hist) -> hist;
        syssleep(max(1, TICK_MS div 10));           ;;; TICK_MS per tick
        tick + 1 -> tick;
        if RUN_SECS > 0 then
            ((sys_microtime() - started) / 1000000.0) < RUN_SECS -> running
        else
            tick <= STEPS -> running
        endif;
    endwhile;
    sysclose(s);
    ;;; leave our history where --render can find it.  Redirecting the
    ;;; character sink is the same trick the renderer and fthwire.p use.
    define lconstant dump();
        lvars h;
        for h in rev(hist) do
            printf('%p %p\n', [% hd(h), hd(tl(h)) %])
        endfor;
    enddefine;
    lvars out = discout('/tmp/swarm-' sys_>< id sys_>< '.txt');
    procedure;
        dlocal cucharout = out;
        dump();
    endprocedure();
    out(termin);
    printf('robot %p done -- heard %p peer messages over %p ticks (%p s), %p sends dropped\n',
           [% id, heard, tick - 1,
              d3((sys_microtime() - started) / 1000000.0), net_send_errors %]);
enddefine;

;;; --------------------------------------------------------------- drawing

define swarm_read(id) -> l;
    lvars dev = sysopen('/tmp/swarm-' sys_>< id sys_>< '.txt', 0, "line");
    lvars rep = line_repeater(dev, inits(64)), line;
    [] -> l;
    repeat
        rep() -> line;
        quitif(line == termin);
        ;;; each line is "<microtime> <phase>"
        lvars f = str_split(line, ` `);
        if length(f) >= 2 and strnumber(hd(tl(f))) then
            conspair(strnumber(hd(tl(f))), l) -> l
        endif;
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

define swarm_watcher(n, port);
    lvars s = net_open(port), phase = initv(n), i, text, sender, seen = 0;
    ;;; One observer, one clock: R measured here needs no agreement between
    ;;; the nodes about what time it is, only about how fast they run.
    lvars logf = systranslate('SWARM_WATCH_LOG'), logdev = false;
    if logf then discout(logf) -> logdev endif;
    for i from 1 to n do false -> subscrv(i, phase) endfor;
    printf('watching %p robots on port %p -- ctrl-C to stop\n\n', [% n, port %]);
    define lconstant bar(ph);
        ;;; one robot's phase as a position on a 2pi track
        lvars col = intof((ph / TWO_PI) * 40) + 1, x;
        for x from 1 to 40 do
            cucharout(if x == col then `#` else `.` endif)
        endfor;
    enddefine;
    define lconstant draw();
        lvars i, ph, c = 0.0, sn = 0.0, live = 0, R;
        for i from 1 to n do
            subscrv(i, phase) -> ph;
            if ph then
                c + cos(ph) -> c; sn + sin(ph) -> sn; live + 1 -> live
            endif;
        endfor;
        if live > 0 then sqrt(c*c + sn*sn) / live else 0.0 endif -> R;
        printf(ESC >< '[H' >< ESC >< '[2J', []);   ;;; home + clear
        printf('robot   phase track (0 .. 2pi)                    phase\n', []);
        for i from 1 to n do
            subscrv(i, phase) -> ph;
            printf('  %p     ', [% i - 1 %]);
            if ph then bar(ph); printf('  %p\n', [% d3(ph) %])
            else printf('(silent)                                  --\n', []) endif;
        endfor;
        printf('\nsync R = %p   ', [% d3(R) %]);
        lvars k;
        for k from 1 to intof(R * 40) do cucharout(`=`) endfor;
        printf('\n%p robots reporting, %p messages seen\n', [% live, seen %]);
        sysflush(popdevout);
        if logdev and live == n then
            procedure;
                dlocal cucharout = logdev;
                printf('%p %p\n', [% sys_microtime(), d3(R) %]);
            endprocedure();
        endif;
    enddefine;
    repeat
        ;;; drain everything that has arrived, then redraw once
        repeat
            net_poll_signed(s) -> (text, sender);
            quitunless(text);
            lvars f = str_split(text, ` `);
            nextunless(length(f) >= 2);
            lvars who = strnumber(hd(f)), ph = strnumber(hd(tl(f)));
            if who and ph and who >= 0 and who < n then
                ph -> subscrv(who + 1, phase); seen + 1 -> seen
            endif;
        endrepeat;
        draw();
        syssleep(10);                          ;;; ~10 frames a second
    endrepeat;
enddefine;

define swarm_main();
    lvars args = poparglist;
    returnif(args == []);
    if hd(args) = '--render' then
        lvars n = strnumber(hd(tl(args)));
        swarm_render(n, '/tmp/swarm.ppm');
        printf('wrote /tmp/swarm.ppm\n', []);
    elseif hd(args) = '--watch' then
        swarm_watcher(strnumber(hd(tl(args))), strnumber(hd(tl(tl(args)))));
    else
        if tl(tl(args)) /== [] then
            str_split(hd(tl(tl(args))), `,`) -> swarm_hosts
        endif;
        if tl(tl(args)) /== [] and tl(tl(tl(args))) /== [] then
            hd(tl(tl(tl(args)))) -> swarm_watch
        endif;
        swarm_robot(strnumber(hd(args)), strnumber(hd(tl(args))));
    endif;
enddefine;

unless isdefined("swarm_lib") then swarm_main() endunless;
