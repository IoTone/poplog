% sight-rules.pl -- time windows over what the fleet has seen.
%
% Age is seconds-ago as measured by the robot that saw it, converted on
% arrival.  Nothing here compares clocks between machines, because the
% machines do not agree about what time it is -- only about how long a
% second lasts.

sighting(Id, R, L, C, A) :- local_sighting(Id, R, L, C, A).
sighting(Id, R, L, C, A) :- remote_sighting(Id, R, L, C, A).

% the windows the fleet actually asks about
recently(Id, R, L, C, A)  :- sighting(Id, R, L, C, A), A =< 300.
last_hour(Id, R, L, C, A) :- sighting(Id, R, L, C, A), A =< 3600.
today(Id, R, L, C, A)     :- sighting(Id, R, L, C, A), A =< 86400.

% what counts as worth shouting about.  This is data, so a live fleet can
% be taught a new alarm with deploy.p without restarting anything.
alarming(cat).

suspicious(Id, R, L, A) :-
    recently(Id, R, L, C, A), C >= 0.8, alarming(L).
