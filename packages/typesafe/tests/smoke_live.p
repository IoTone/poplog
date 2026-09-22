;;; smoke_live.p -- one real call, to check the server agrees with us.
;;;
;;; The offline suite pins the request shape and decodes a response copied
;;; from the docs.  Neither can tell you that `noul` is really the field
;;; name on a live answer, or that `usage` really spells it `input_tokens`.
;;; Only the server can say that, and only once.
;;;
;;;     TYPESAFE_API_KEY=$(cat ~/.typesafe-key) \
;;;         ./poplog basepop11 packages/typesafe/tests/smoke_live.p
;;;
;;; Costs one request with three questions.  Prints the raw body when an
;;; assumption fails, because a schema mismatch you cannot see is a schema
;;; mismatch you cannot fix.  Never prints the key.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
uses typesafe;
uses json;

unless ts_api_key then
    printf('TYPESAFE_API_KEY is not set -- nothing to validate.\n', []);
    printf('  TYPESAFE_API_KEY=$(cat ~/.typesafe-key) \\\n', []);
    printf('      ./poplog basepop11 packages/typesafe/tests/smoke_live.p\n', []);
    sysexit();
endunless;

;;; Keep the raw body so a failure can be read rather than guessed at.
vars raw = false;
vars real_transport = ts_transport;

define watched(method, url, body, headers, timeout) -> (rb, rh, st);
    real_transport(method, url, body, headers, timeout) -> (rb, rh, st);
    rb -> raw;
enddefine;
watched -> ts_transport;

vars fails = 0, total = 0;

define claim(name, ok);
    total + 1 -> total;
    if ok then printf('  ok    %p\n', [% name %])
    else printf('  FAIL  %p\n', [% name %]); fails + 1 -> fails
    endif;
    sysflush(popdevout);
enddefine;

define isnum(x);
    isinteger(x) or isdecimal(x) or isddecimal(x)
enddefine;

printf('asking %p as %p ...\n', [% ts_base_url, ts_model %]);
sysflush(popdevout);

lvars q_noul = ts_noul('Is this text a greeting?',
                       'it greets the reader',
                       'it does not greet the reader');
lvars q_choice = ts_choice('What register is this in?',
                           [[formal 'business register']
                            [casual 'conversational register']]);
lvars q_score = ts_score('How long is this text?',
                         ['very short' 'medium' 'long']);

lvars answers = ts_eval('Hello there, how are you today?',
                        [[greeting ^q_noul]
                         [register ^q_choice]
                         [length   ^q_score]]);

printf('\nschema assumptions this client depends on:\n', []);

;;; --- envelope
claim('response decodes as an object', isproperty(answers));
claim('usage is present',              isproperty(ts_last_usage));
claim('usage.input_tokens is a number',  isnum(ts_last_usage('input_tokens')));
claim('usage.output_tokens is a number', isnum(ts_last_usage('output_tokens')));

;;; --- ids come back the way we sent them
claim('answers keyed by our question ids',
      isproperty(answers('greeting')) and isproperty(answers('register'))
      and isproperty(answers('length')));

;;; --- noul
lvars a = answers('greeting');
claim('noul answer has type=noul', a and a('type') = 'noul');
claim('noul answer has a numeric "noul" field', a and isnum(a('noul')));

;;; --- choice
lvars b = answers('register');
claim('choice answer has type=choice', b and b('type') = 'choice');
claim('choice answer has a "choice" field', b and b('choice') and true);
claim('choice picked one of our keys',
      b and (b('choice') = 'formal' or b('choice') = 'casual'));
claim('choice has probabilities object', b and isproperty(b('probabilities')));
claim('choice has numeric confidence',   b and isnum(b('confidence')));

;;; --- score
lvars c = answers('length');
claim('score answer has type=score', c and c('type') = 'score');
claim('score answer has numeric "score"', c and isnum(c('score')));
claim('score has a legend object',        c and isproperty(c('legend')));
claim('score has probabilities object',   c and isproperty(c('probabilities')));
claim('score has numeric confidence',     c and isnum(c('confidence')));

printf('\nwhat the server actually said:\n', []);
printf('  greeting : %p\n', [% a and a('noul') %]);
printf('  register : %p (confidence %p)\n', [% b and b('choice'), b and b('confidence') %]);
printf('  length   : %p (confidence %p)\n', [% c and c('score'), c and c('confidence') %]);
printf('  tokens   : %p in, %p out\n',
       [% ts_last_usage('input_tokens'), ts_last_usage('output_tokens') %]);

if fails > 0 then
    printf('\n%p assumption(s) failed.  Raw response body:\n%p\n', [% fails, raw %]);
    printf('\nThe client is wrong about the schema, not the server.\n', []);
else
    ;;; count the claims, do not assert a number by hand -- the first run of
    ;;; this said "all 18" while printing 17 ok lines
    printf('\nall %p assumptions hold -- the offline suite is testing the right shape.\n',
           [% total %]);
endif;
sysexit();
