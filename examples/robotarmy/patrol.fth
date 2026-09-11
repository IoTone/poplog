\ examples/robotarmy/patrol.fth -- robot control words in Poplog Forth.
\
\ Forth's data stack is Poplog's open stack, so these words are native
\ procedures the moment they are defined.
\
\     tools/forth.sh < examples/robotarmy/patrol.fth

variable charge   100 charge !
variable steps      0 steps !

: drain    charge @ swap - charge ! ;          \ ( n -- )  spend n% of charge
: step     steps @ 1+ steps !   2 drain ;
: low?     charge @ 25 < ;
: status   charge @ . steps @ . cr ;           \ prints: charge steps

\ walk n steps, stopping early if the battery gets low
: patrol   0 do  low? if leave then  step  loop  status ;

10 patrol
30 patrol
: fib  dup 2 < if drop 1 else dup 1 - recurse swap 2 - recurse + then ;
20 fib .
