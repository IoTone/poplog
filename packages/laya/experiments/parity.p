;;; E1: send every validation case through ts_eval and LIB LAYA; write what came back.
;;;
;;;     LAYA_MODEL=aac6fef/laya-mlx LAYA_DTYPE=float16 PARITY_DIR=... PARITY_OUT=.../out.json \
;;;         ./poplog ./target/pop/basepop11 packages/laya/experiments/parity.p
;;;
;;; With LAYA_ROUTER set to a nonempty value the child is started with --router
;;; instead of --model, which is E6: the same cases, answered by whichever
;;; checkpoint the router picks per request.  LAYA_MODEL is then ignored, as it is
;;; by laya_serve.py.  One harness for both so the two experiments cannot drift
;;; apart in how they call ts_eval -- which is the thing being measured.
;;;
;;; Each request is parsed with json_ordered_objects on, so choice options and nested
;;; objects keep their order, then rebuilt as a ts_eval call -- the path a Pop-11
;;; program takes, including Pop-11's own JSON generation of the state.
;;;
;;; Run from the root of an IoTone/poplog checkout that has packages/laya.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;
uses fileutils;
uses laya;

lvars router = systranslate('LAYA_ROUTER');
if router and router /= '' then
    true -> laya_router;
else
    systranslate('LAYA_MODEL') -> laya_model;
endif;
systranslate('LAYA_DTYPE') -> laya_dtype;
false -> ts_api_key;

lvars dir = systranslate('PARITY_DIR');
true -> json_ordered_objects;
lvars cases = json_parse(file_to_string(dir dir_>< 'requests.json'));
false -> json_ordered_objects;

lvars results = json_object(), c, qs;
for c in datalist(cases) do
    [% json_object_app(c('questions'), procedure(id, q); [% id, q %] endprocedure) %]
        -> qs;
    lvars answers = ts_eval(c('state'), qs);
    lvars r = json_object();
    ts_last_model -> r('model');
    answers -> r('answers');
    ts_last_usage -> r('usage');
    r -> results(c('name'));
endfor;
string_to_file(json_generate(results), systranslate('PARITY_OUT'));
laya_stop();
npr('PARITY-DONE');
