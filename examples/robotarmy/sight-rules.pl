% sight-rules.pl -- time windows and meaning over what the fleet has seen.
%
% Age is seconds-ago as measured by the robot that saw it.  Nothing here
% compares clocks between machines, because the machines do not agree about
% what time it is -- only about how long a second lasts.

sighting(Id, R, L, C, A) :- local_sighting(Id, R, L, C, A).
sighting(Id, R, L, C, A) :- remote_sighting(Id, R, L, C, A).

% the windows the fleet actually asks about
recently(Id, R, L, C, A)  :- sighting(Id, R, L, C, A), A =< 300.
last_hour(Id, R, L, C, A) :- sighting(Id, R, L, C, A), A =< 3600.
today(Id, R, L, C, A)     :- sighting(Id, R, L, C, A), A =< 86400.

% The classifier reports a SHAPE, because a 256->16->4 network can recognise
% a painted marker and cannot recognise a cat.  What a marker MEANS is a
% separate question, and the answer is data -- so a live fleet can be taught
% a new sign, or a new alarm, with deploy.p and no restart.
means(circle,   cat).
means(square,   crate).
means(triangle, hazard).
means(cross,    blocked).

alarming(cat).
alarming(hazard).

saw(Id, R, Meaning, A) :-
    sighting(Id, R, Shape, _, A), means(Shape, Meaning).

suspicious(Id, R, Meaning, A) :-
    recently(Id, R, Shape, C, A), C >= 0.8,
    means(Shape, Meaning), alarming(Meaning).
