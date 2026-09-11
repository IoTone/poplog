% examples/robotarmy/chain.pl -- the chain of command, in Poplog Prolog.
%
%     ./poplog basepop11 -target/psv/prolog.psv
%     ?- ['examples/robotarmy/chain.pl'].
%     ?- can_order(commander, r4).
%     ?- reports_to(r4, Who).

commands(commander, sq1).
commands(commander, sq2).
commands(sq1, r1).
commands(sq1, r2).
commands(sq2, r3).
commands(sq2, r4).

% X may order Y if X commands Y directly, or commands someone who may
can_order(X, Y) :- commands(X, Y).
can_order(X, Z) :- commands(X, Y), can_order(Y, Z).

reports_to(Unit, Boss) :- commands(Boss, Unit).

% a unit obeys an order only from up its own chain
obeys(Unit, From) :- can_order(From, Unit).
