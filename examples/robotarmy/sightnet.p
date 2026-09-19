/* examples/robotarmy/sightnet.p -- what the fleet has seen lately.

   chainnet.p distributes a relation that never changes.  This distributes
   one that is always changing: each robot records what its camera saw,
   the record expires, and any robot can ask the fleet "what has anyone
   seen in the last five minutes that I do not already know about?"

   Three design decisions worth stating, because each is a trap avoided:

   1. THE WIRE CARRIES AGES, NOT TIMESTAMPS.  These machines do not agree
      about what time it is -- the Pi runs with NTP inactive -- so a
      timestamp from another node is not comparable with ours.  An age is
      a duration: it needs the two machines to agree on the length of a
      second, which they do, and not on an epoch, which they do not.  The
      asking node converts an age back to its own clock on arrival.  This
      is the same correction swarm.p needed (see docs/book ch.8).

   2. EXPIRY IS THE OWNER'S JOB.  A node prunes its own store; nobody
      prunes anyone else's.  A sighting nobody asked for still expires.

   3. DEDUP IS BY (ROBOT, SEQUENCE), NOT BY CONTENT.  Each robot numbers
      its own sightings.  A requestor remembers the highest sequence it
      has seen from each robot and sends those marks with the query, so
      the answer carries only what is new -- which also keeps a reply
      inside one datagram.  Content hashing would collide the moment two
      frames of the same quiet corridor looked alike.

       ;;; a robot with canned sightings, serving them
       ./poplog basepop11 examples/robotarmy/sightnet.p --serve r1 9830 --seed

       ;;; ask the fleet what it has seen in the last 5 minutes
       ./poplog basepop11 examples/robotarmy/sightnet.p \
           --ask r0 10.0.0.5:9830,10.0.0.6:9831 \
           '(recently(Id, R, L, C, A), write(R-L-C-A), nl, fail ; true)'

       ;;; stand watch: poll, and shout about anything alarming and new
       ./poplog basepop11 examples/robotarmy/sightnet.p \
           --watch r0 10.0.0.5:9830 300
*/
vars robotarmy_lib = true;
load 'examples/robotarmy/fleetnet.p';
uses strutils;
uses prolog;
uses define_prolog;

;;; The classifier is optional: without weights a node still serves, it just
;;; has nothing of its own to see.  With them, the reel becomes real -- a
;;; frame is rendered, classified, and the label that enters the knowledge
;;; base is the network's answer rather than a canned string.
vars vision_lib = true;
vars sight_vision = false;
;;; Declared up front because the load below happens at run time, after this
;;; file is compiled -- without this the compiler invents them and warns.
vars procedure (vis_load, vis_classify, vis_render);
unless readable('examples/robotarmy/vision-weights.txt') == false then
    load 'examples/robotarmy/vision.p';
    vis_load('examples/robotarmy/vision-weights.txt');
    true -> sight_vision;
endunless;

define lconstant envnum(name, dflt) -> v;
    lvars e = systranslate(name);
    if e and strnumber(e) then strnumber(e) else dflt endif -> v;
enddefine;

vars sight_me    = 'r0';        ;;; this node's name; sequence numbers are its
vars sight_peers = [];          ;;; list of 'host:port'
vars sight_seq   = 0;           ;;; our own sighting counter
vars sightings   = [];          ;;; newest first: {seq label conf microtime frameseed}
vars sight_seen  = [];          ;;; dedup marks: [robot maxseq] we have received

;;; Seconds a sighting survives.  Overridable so the expiry can actually be
;;; demonstrated without waiting a day.
lconstant SIGHT_TTL  = envnum('SIGHT_TTL', 86400);
lconstant SIGHT_CAP  = envnum('SIGHT_CAP', 400);    ;;; hard ceiling on store
lconstant SIGHT_WAIT = envnum('SIGHT_WAIT', 60);    ;;; centisecs to await peers
;;; fleetnet's NET_MTU is file-local, so keep our own ceiling well under it.
;;; A reply that would exceed it is truncated to the NEWEST rows -- the asker
;;; keeps its marks, so the rest arrive on the next query rather than being
;;; lost.  Silently dropping the oldest is the right trade for a feed.
lconstant SIGHT_REPLY_MAX = 1000;
;;; Seconds between canned "frames" when serving with --reel.  This stands in
;;; for the camera: a real node would classify whatever appeared in the common
;;; image directory instead of inventing a label.
lconstant SIGHT_REEL = envnum('SIGHT_REEL', 0);
;;; which shape the watcher shouts about (circle means cat, see sight-rules.pl)
lvars _a = systranslate('SIGHT_ALERT');
lconstant SIGHT_ALERT = if _a then consword(_a) else "circle" endif;

;;; A disciplined clock can STEP, forwards or back, and ages are differences
;;; of wall-clock readings.  A backward step makes an age negative, which
;;; sails straight through an "older than the window?" test and reports a
;;; sighting from the future; a forward step ages the whole store out at
;;; once.  Neither is hypothetical now that the fleet runs NTP.  Clamp at
;;; zero and treat an implausible age as "just now" rather than inventing
;;; either a prophecy or a mass expiry.
define lconstant sane_age(secs) -> a;
    if secs < 0.0 then 0.0 elseif secs > SIGHT_TTL * 2 then 0.0
    else secs endif -> a;
enddefine;

;;; ------------------------------------------------------- the frame itself
;;; Canned stand-in for a camera frame: a 32x32 ASCII PGM, deterministic from
;;; the sequence number so a fetch can be checked byte for byte.  It is about
;;; 4 KB, which is the point -- it does NOT fit in one datagram, so fetching
;;; it exercises the chunked path (net_send_big / net_collect) rather than
;;; the single-datagram path everything else here uses.
;;;
;;; A real node would read the newest file out of the common image directory
;;; instead.  Nothing below cares which it was.

define sight_frame(seq) -> text;
    lvars r, fseed = false, img, x, y, v;
    for r in sightings do
        if subscrv(1, r) == seq then subscrv(5, r) -> fseed; quitloop endif
    endfor;
    if fseed and sight_vision then
        ;;; the actual 16x16 frame this sighting was classified from
        vis_render(subscrv(2, r), fseed) -> img;
        'P2\n16 16\n255\n' -> text;
        for y from 0 to 15 do
            for x from 0 to 15 do
                intof(subscrv(y * 16 + x + 1, img) * 255) -> v;
                text <> (v sys_>< '') <> ' ' -> text;
            endfor;
            text <> '\n' -> text;
        endfor;
    else
        ;;; no classifier: a deterministic stand-in, still big enough to chunk
        'P2\n32 32\n255\n' -> text;
        for y from 0 to 31 do
            for x from 0 to 31 do
                ((x * 8 + y * 4 + seq * 16) mod 256) -> v;
                text <> (v sys_>< '') <> ' ' -> text;
            endfor;
            text <> '\n' -> text;
        endfor;
    endif;
enddefine;

;;; ------------------------------------------------------------ local store

define sight_prune();
    lvars now = sys_microtime(), keep = [], r, n = 0;
    for r in sightings do
        quitif(n >= SIGHT_CAP);
        nextif(sane_age((now - subscrv(4, r)) / 1000000.0) > SIGHT_TTL);
        conspair(r, keep) -> keep;
        n + 1 -> n;
    endfor;
    rev(keep) -> sightings;         ;;; sightings stay newest-first
enddefine;

define sight_record(label, conf, frameseed);
    sight_seq + 1 -> sight_seq;
    conspair({% sight_seq, label, conf, sys_microtime(), frameseed %}, sightings)
        -> sightings;
    sight_prune();
enddefine;

;;; Rows are [id label conf age_seconds], newest first, filtered by age and
;;; by what the asker says it already has.
define sight_local(max_age, since_seq) -> rows;
    lvars now = sys_microtime(), r, age;
    sight_prune();
    [] -> rows;
    for r in sightings do
        sane_age((now - subscrv(4, r)) / 1000000.0) -> age;
        nextif(age > max_age);
        nextif(subscrv(1, r) <= since_seq);
        conspair({% sight_me sys_>< '-' sys_>< subscrv(1, r),
                    subscrv(2, r), subscrv(3, r), age %}, rows) -> rows;
    endfor;
    rev(rows) -> rows;
enddefine;

;;; --------------------------------------------------------- the wire format
;;; query:  's <max_age> <robot>:<seq>,<robot>:<seq>'   ('-' for no marks)
;;; answer: 'o <id>|<label>|<conf>|<age> <id>|<label>|<conf>|<age> ...'
;;;
;;; Age is computed at send time.  The gap between that and the asker
;;; reading it is one network hop, which is small next to the windows this
;;; is asked about (minutes and hours) -- but it is a real bias, and the
;;; asker adds its own elapsed time on top when it stores a row.

define sight_pack(rows) -> text;
    lvars r;
    'o' -> text;
    for r in rows do
        text <> ' ' <> subscrv(1, r) <> '|' <> (subscrv(2, r) sys_>< '')
             <> '|' <> (intof(subscrv(3, r) * 100) / 100.0 sys_>< '')
             <> '|' <> (intof(subscrv(4, r) * 10) / 10.0 sys_>< '') -> text;
    endfor;
enddefine;

define sight_unpack(text) -> rows;
    lvars w, f;
    [] -> rows;
    for w in str_split(text, ` `) do
        nextif(w = 'o' or w = '');
        str_split(w, `|`) -> f;
        nextunless(length(f) >= 4);
        conspair({% hd(f), consword(hd(tl(f))),
                    strnumber(hd(tl(tl(f)))) or 0.0,
                    strnumber(hd(tl(tl(tl(f))))) or 0.0 %}, rows) -> rows;
    endfor;
    rev(rows) -> rows;
enddefine;

;;; The marks we send with a query, so peers omit what we already hold.
define sight_marks() -> text;
    lvars m;
    if sight_seen == [] then '-' -> text; return endif;
    '' -> text;
    for m in sight_seen do
        if text = '' then '' else text <> ',' endif
            <> subscrv(1, m) <> ':' <> (subscrv(2, m) sys_>< '') -> text;
    endfor;
enddefine;

define sight_mark_for(robot) -> n;
    lvars m;
    0 -> n;
    for m in sight_seen do
        if subscrv(1, m) = robot then subscrv(2, m) -> n; return endif
    endfor;
enddefine;

define sight_note(id);
    ;;; id is '<robot>-<seq>'; remember the high-water mark per robot
    lvars d = locchar(`-`, 1, id), robot, seq, m;
    returnunless(d);
    substring(1, d - 1, id) -> robot;
    strnumber(allbutfirst(d, id)) -> seq;
    returnunless(seq);
    for m in sight_seen do
        if subscrv(1, m) = robot then
            if seq > subscrv(2, m) then seq -> subscrv(2, m) endif;
            return;
        endif;
    endfor;
    conspair({% robot, seq %}, sight_seen) -> sight_seen;
enddefine;

;;; ---------------------------------------------------------------- serving

define sight_serve(port);
    lvars s = net_open(port), text, sender, f, max_age, marks, rows, reply;
    printf('sight node %p on %p, %p sightings held, ttl %p s\n',
           [% sight_me, port, length(sightings), SIGHT_TTL %]);
    sysflush(popdevout);
    lvars reel_at = sys_microtime(), reel = [cat dog car cat car dog], reel_i = 0;
    repeat
        ;;; A reel node keeps seeing things while it serves, so the store is a
        ;;; moving window rather than a fixture -- which is what makes dedup
        ;;; and the time windows mean anything.
        if SIGHT_REEL > 0
        and (sys_microtime() - reel_at) / 1000000.0 >= SIGHT_REEL then
            sys_microtime() -> reel_at;
            reel_i + 1 -> reel_i;
            lvars fseed = 90000 + reel_i * 7919;
            if sight_vision then
                ;;; a real frame, a real classification
                lvars shown = subscrv(((reel_i - 1) mod 4) + 1,
                                      {circle square triangle cross});
                lvars lbl, cf;
                vis_classify(vis_render(shown, fseed)) -> (lbl, cf);
                sight_record(lbl, cf, fseed);
                printf('  [reel] %p saw %p (drawn %p, %p confidence), %p held\n',
                       [% sight_me, lbl, shown, intof(cf * 100) / 100.0,
                          length(sightings) %]);
            else
                sight_record(subscrv(((reel_i - 1) mod 4) + 1,
                                     {circle square triangle cross}),
                             0.7, fseed);
                printf('  [reel] %p now holds %p sightings (no classifier)\n',
                       [% sight_me, length(sightings) %]);
            endif;
            sysflush(popdevout);
        endif;
        unless net_ready(s) then syssleep(10); nextloop endunless;
        net_recv_signed(s) -> (text, sender);
        nextunless(text);
        str_split(text, ` `) -> f;
        ;;; 'f <id>' -- send the frame behind a sighting, in as many signed
        ;;; chunks as it takes.  Same mechanism deploy.p uses for source.
        if length(f) >= 2 and hd(f) = 'f' then
            lvars want = hd(tl(f)), d = locchar(`-`, 1, want), sq;
            if d and substring(1, d - 1, want) = sight_me
               and (strnumber(allbutfirst(d, want)) ->> sq) then
                lvars img = sight_frame(sq);
                net_send_big(s, hd(sender), hd(tl(sender)), img);
                printf('  -> frame %p, %p bytes\n', [% want, length(img) %]);
            else
                net_send(s, hd(sender), hd(tl(sender)), net_sign('no such frame'));
                printf('  -> %p: not mine\n', [% want %]);
            endif;
            sysflush(popdevout);
            nextloop;
        endif;
        nextunless(length(f) >= 3 and hd(f) = 's');
        strnumber(hd(tl(f))) -> max_age;
        nextunless(max_age);
        hd(tl(tl(f))) -> marks;
        ;;; only our own mark matters -- we only ever serve our own sightings
        lvars since = 0, w;
        unless marks = '-' then
            for w in str_split(marks, `,`) do
                lvars c = locchar(`:`, 1, w);
                if c and substring(1, c - 1, w) = sight_me then
                    strnumber(allbutfirst(c, w)) or 0 -> since
                endif;
            endfor;
        endunless;
        sight_local(max_age, since) -> rows;
        ;;; newest first for truncation purposes
        rev(rows) -> rows;
        sight_pack(rows) -> reply;
        until length(reply) =< SIGHT_REPLY_MAX or rows == [] do
            allbutlast(1, rows) -> rows;
            sight_pack(rows) -> reply;
        enduntil;
        rev(rows) -> rows;
        sight_pack(rows) -> reply;
        net_send(s, hd(sender), hd(tl(sender)), net_sign(reply));
        printf('  ?- seen within %p s (since %p) -> %p rows\n',
               [% max_age, since, length(rows) %]);
        sysflush(popdevout);
    endrepeat;
enddefine;

;;; ----------------------------------------------------------------- asking

define sight_ask(max_age) -> rows;
    lvars s = net_open(0), peer, c, text, sender, waited = 0, got = 0, r;
    [] -> rows;
    lvars q = 's ' <> (max_age sys_>< '') <> ' ' <> sight_marks();
    for peer in sight_peers do
        locchar(`:`, 1, peer) -> c;
        nextunless(c);
        net_send(s, substring(1, c - 1, peer),
                 strnumber(allbutfirst(c, peer)), net_sign(q));
    endfor;
    until got >= length(sight_peers) or waited >= SIGHT_WAIT do
        if net_ready(s) then
            net_recv_signed(s) -> (text, sender);
            if text then
                got + 1 -> got;
                rows <> sight_unpack(text) -> rows;
            endif;
        else
            syssleep(2);
            waited + 2 -> waited;
        endif;
    enduntil;
    sysclose(s);
    ;;; a row we have now seen is a row we will not ask for again
    for r in rows do sight_note(subscrv(1, r)) endfor;
enddefine;

;;; ------------------------------------------ Pop-11 AS Prolog predicates
;;; Both the local store and the remote fleet are reached the same way: a
;;; Pop-11 procedure that calls its continuation once per answer, which is
;;; what makes it a nondeterministic predicate rather than a function.
;;; The store is mutable and expiring, which is exactly why Pop-11 owns it
;;; and Prolog reads it through here -- one heap, no marshalling.

define lconstant yield4(rows, id, r, l, c, a, contn);
    lvars row;
    for row in rows do
        prolog_unifyc(id, subscrv(1, row), procedure;
          prolog_unifyc(r, consword(sight_me), procedure;
            prolog_unifyc(l, subscrv(2, row), procedure;
              prolog_unifyc(c, subscrv(3, row), procedure;
                prolog_unifyc(a, subscrv(4, row), contn);
              endprocedure);
            endprocedure);
          endprocedure);
        endprocedure);
    endfor;
enddefine;

define :prolog local_sighting/5(id, r, l, c, a, contn);
    lvars id, r, l, c, a, contn;
    yield4(sight_local(SIGHT_TTL, 0), id, r, l, c, a, contn);
enddefine;

define :prolog remote_sighting/5(id, r, l, c, a, contn);
    lvars id, r, l, c, a, contn, row, robot, d;
    for row in sight_ask(SIGHT_TTL) do
        locchar(`-`, 1, subscrv(1, row)) -> d;
        substring(1, d - 1, subscrv(1, row)) -> robot;
        prolog_unifyc(id, subscrv(1, row), procedure;
          prolog_unifyc(r, consword(robot), procedure;
            prolog_unifyc(l, subscrv(2, row), procedure;
              prolog_unifyc(c, subscrv(3, row), procedure;
                prolog_unifyc(a, subscrv(4, row), contn);
              endprocedure);
            endprocedure);
          endprocedure);
        endprocedure);
    endfor;
enddefine;

;;; ------------------------------------------------------------ canned data
;;; Ages chosen to exercise every window and the expiry boundary at once.

define sight_seed();
    lvars spec, now = sys_microtime();
    ;;; [label confidence age_seconds]
    for spec in [[cat 0.91 12] [dog 0.84 95] [car 0.77 240]
                 [cat 0.62 900] [car 0.88 5400] [dog 0.71 82000]
                 [cat 0.95 90000]]           ;;; the last one is already stale
    do
        sight_seq + 1 -> sight_seq;
        conspair({% sight_seq, hd(spec), hd(tl(spec)),
                    now - intof(hd(tl(tl(spec))) * 1000000),
                    40000 + sight_seq * 7919 %}, sightings)
            -> sightings;
    endfor;
    rev(sightings) -> sightings;
    lvars before = length(sightings);
    sight_prune();
    printf('seeded %p sightings, %p survive ttl of %p s\n',
           [% before, length(sightings), SIGHT_TTL %]);
enddefine;

;;; ---------------------------------------------------------------- fetching

define sight_fetch(peer, id) -> img;
    lvars s = net_open(0), c = locchar(`:`, 1, peer), sender, waited = 0;
    false -> img;
    net_send(s, substring(1, c - 1, peer), strnumber(allbutfirst(c, peer)),
             net_sign('f ' <> id));
    ;;; net_collect reassembles the chunks and returns false until the last
    ;;; one lands, so poll until it yields or we give up.
    until img or waited >= 300 do
        if net_ready(s) then
            net_collect(s) -> (img, sender);
        else
            syssleep(2); waited + 2 -> waited;
        endif;
    enduntil;
    sysclose(s);
enddefine;

;;; ---------------------------------------------------------------- watching

define sight_watch(window);
    lvars rows, r, shouted;
    printf('watching %p peers, window %p s, ttl %p s\n',
           [% length(sight_peers), window, SIGHT_TTL %]);
    sysflush(popdevout);
    repeat
        sight_ask(window) -> rows;      ;;; marks make this new-rows-only
        0 -> shouted;
        for r in rows do
            ;;; The watcher alerts on a SHAPE; what that shape means lives in
            ;;; sight-rules.pl, where it is data the fleet can be retaught.
            if subscrv(2, r) == SIGHT_ALERT and subscrv(3, r) >= 0.8 then
                printf('  ** ALERT %p (%p confidence) seen %p s ago -- %p\n',
                       [% subscrv(2, r), subscrv(3, r),
                          subscrv(4, r), subscrv(1, r) %]);
                shouted + 1 -> shouted;
            endif;
        endfor;
        if rows /== [] then
            printf('  %p new rows, %p alerts\n', [% length(rows), shouted %]);
            sysflush(popdevout);
        endif;
        syssleep(200);
    endrepeat;
enddefine;

;;; ----------------------------------------------------------------- driver

define sight_main();
    lvars args = poparglist, mode;
    returnif(args == []);
    hd(args) -> mode;
    if mode = '--serve' then
        hd(tl(args)) -> sight_me;
        if member('--seed', args) then sight_seed() endif;
        sight_serve(strnumber(hd(tl(tl(args)))));
    elseif mode = '--ask' then
        hd(tl(args)) -> sight_me;
        unless hd(tl(tl(args))) = '-' then
            str_split(hd(tl(tl(args))), `,`) -> sight_peers
        endunless;
        prolog_compile(discin('examples/robotarmy/sight-rules.pl'));
        prolog_compile(stringin(':- ' <> hd(tl(tl(tl(args)))) <> '.'));
    elseif mode = '--fetch' then
        hd(tl(args)) -> sight_me;
        lvars img = sight_fetch(hd(tl(tl(args))), hd(tl(tl(tl(args)))));
        if img then
            printf('fetched %p bytes\n', [% length(img) %]);
            lvars out = discout(hd(tl(tl(tl(tl(args))))));
            procedure; dlocal cucharout = out; printf('%p', [% img %]) endprocedure();
            out(termin);
        else
            printf('fetch failed or timed out\n', []);
        endif;
    elseif mode = '--watch' then
        hd(tl(args)) -> sight_me;
        str_split(hd(tl(tl(args))), `,`) -> sight_peers;
        sight_watch(strnumber(hd(tl(tl(tl(args))))));
    endif;
enddefine;

sight_main();
