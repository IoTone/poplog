% chain-rules.pl -- the chain of command, in two clauses that do not care
% which machine an answer came from.
%
% commands/2 is the join: whatever this node knows itself, plus whatever
% the rest of the fleet answers.  remote_commands/2 is Pop-11 (chainnet.p)
% and does a UDP round trip, but nothing below this line can tell.

commands(X, Y) :- local_commands(X, Y).
commands(X, Y) :- remote_commands(X, Y).

can_order(X, Y) :- commands(X, Y).
can_order(X, Z) :- commands(X, Y), can_order(Y, Z).

reports_to(Unit, Boss) :- commands(Boss, Unit).
obeys(Unit, From) :- can_order(From, Unit).
