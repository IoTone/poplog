% tools/tests/data/plog_commands.pl -- clause heads that used to be eaten.
%
% Every functor here is one of the twelve interactive command words in
% pop/plog/src/commands.p.  Consulting this file used to run the command
% instead of defining the predicate, and said nothing about it.
% See docs/bugs/prolog-commands-swallow-clauses.md

before(1).
help(a).
source(x, y).
cd(p, q).
ref(r).
showlib(s).
pwd(w).
before(2).
