/* patrol_order.p -- a capability deployed to a robot over the network.

   Nothing here is special: it is ordinary Pop-11 that happens to arrive by
   UDP rather than off disk.  It is a few kilobytes, so it crosses the wire
   as several signed chunks and is reassembled before a single character of
   it reaches the compiler.

   After this lands, the robot can plan a patrol it could not plan before.
*/

;;; A waypoint is [name cost]; a route is a list of waypoints.

define wp_name(w); hd(w) enddefine;
define wp_cost(w); hd(tl(w)) enddefine;

;;; Total cost of a route.
define route_cost(route) -> total;
    lvars w;
    0 -> total;
    for w in route do wp_cost(w) + total -> total endfor;
enddefine;

;;; The cheapest ordering by repeated nearest-neighbour choice: not optimal,
;;; but it is deterministic, which matters when several robots must agree on
;;; the same plan without talking to each other again.
define plan_patrol(waypoints, budget) -> route;
    lvars remaining = waypoints, best, w, spent = 0;
    [] -> route;
    until remaining == [] do
        false -> best;
        for w in remaining do
            if not(best) or wp_cost(w) < wp_cost(best) then w -> best endif
        endfor;
        quitif(spent + wp_cost(best) > budget);
        spent + wp_cost(best) -> spent;
        route <> [^best] -> route;
        lvars keep = [], x;
        for x in remaining do unless x == best then keep <> [^x] -> keep endunless endfor;
        keep -> remaining;
    enduntil;
enddefine;

;;; Render a route the way the command post likes to read it.
define describe_patrol(route) -> s;
    lvars w;
    '' -> s;
    for w in route do
        if s = '' then '' else s <> ' -> ' endif -> s;
        s <> (wp_name(w) sys_>< '') -> s;
    endfor;
    if s = '' then 'nowhere (budget too small)' -> s endif;
    s <> ' [cost ' <> (route_cost(route) sys_>< '') <> ']' -> s;
enddefine;
