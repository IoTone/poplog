/* examples/robotarmy/c2.p -- the command post: a web service for the fleet.

   LIB HTTP_SERVER + LIB JSON + fleet.p.  Routes:

       GET  /fleet             the roster, as JSON
       GET  /status?unit=r1    one unit
       POST /order             body is an order, e.g. "unit r1 advance to ridge"
       GET  /boom              a deliberate handler mishap -> 500, server lives

   Run:  ./poplog basepop11 examples/robotarmy/c2.p 8099
   Try:  curl localhost:8099/fleet
         curl -d 'unit r1 advance to ridge' localhost:8099/order
*/
uses http_server;
uses json;
uses strutils;

vars robotarmy_lib = true;            ;;; suppress fleet.p's demonstration
load 'examples/robotarmy/fleet.p';

enlist("r1", "scout")  -> _;
enlist("r2", "sapper") -> _;
enlist("r3", "medic")  -> _;

vars port = 8099, count = false, args = poparglist;
if args /== [] then strnumber(hd(args)) -> port endif;
unless isinteger(port) then 8099 -> port endunless;
if args /== [] and tl(args) /== [] then strnumber(hd(tl(args))) -> count endif;

define unit_json(r) -> obj;
    newmapping([], 8, false, true) -> obj;
    rb_id(r)     sys_>< '' -> obj('id');
    rb_kind(r)   sys_>< '' -> obj('kind');
    rb_charge(r)           -> obj('charge');
    rb_place(r)  sys_>< '' -> obj('place');
enddefine;

;;; an order arrives as text; the matcher wants a list of words
define words_of(s) -> l;
    lvars w;
    [% for w in str_split(str_trim(s), ` `) do
           if w /= '' then
               if strnumber(w) then strnumber(w) else consword(w) endif
           endif
       endfor %] -> l;
enddefine;

define handler(req) -> resp;
    lvars path = req('path'), obj, r, u;
    if path = '/fleet' then
        http_json({% applist(muster(), unit_json) %}) -> resp;
    elseif path = '/status' then
        allbutfirst(5, req('query')) -> u;          ;;; "unit=r1"
        fleet(consword(u)) -> r;
        if r then http_json(unit_json(r)) -> resp
        else false -> resp endif;                   ;;; unknown unit -> 404
    elseif path = '/order' then
        newmapping([], 4, false, true) -> obj;
        obey(words_of(req('body'))) -> obj('reply');
        http_json(obj) -> resp;
    elseif path = '/boom' then
        mishap(0, 'deliberate handler failure');    ;;; server answers 500
    else
        false -> resp;
    endif;
enddefine;

'command post listening on ' >< port >< '...' =>
http_serve_n(port, handler, count);
'stood down.' =>
