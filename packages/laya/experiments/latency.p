;;; E3: per-call latency of ts_eval through LIB LAYA (stdio) or a loopback laya_serve.py
;;; (HTTP via LIB HTTP_CLIENT), plus Pop-11's own JSON encode/decode cost.
;;;
;;; Driven by latency.py; run from the root of an IoTone/poplog checkout.

extend_searchlist('packages/typesafe', popuseslist) -> popuseslist;
extend_searchlist('packages/laya', popuseslist) -> popuseslist;
uses fileutils;
uses laya;

;;; Poplog's own clocks tick in seconds or hundredths; macOS gives nanoseconds.
exload latency_clock []
(language C)
    lconstant clock_gettime_nsec_np(id) :ulong;
endexload;
define lconstant now_ns();
    exacc clock_gettime_nsec_np(4)       ;;; CLOCK_MONOTONIC_RAW
enddefine;

lvars mode = systranslate('LATENCY_MODE');
lvars n = strnumber(systranslate('LATENCY_N'));
lvars warm = strnumber(systranslate('LATENCY_WARMUP'));
systranslate('LAYA_MODEL') -> laya_model;
systranslate('LAYA_DTYPE') -> laya_dtype;
false -> ts_api_key;

true -> json_ordered_objects;
lvars req = json_parse(file_to_string(systranslate('LATENCY_REQUEST')));
false -> json_ordered_objects;
lvars state = req('state'), qs = [% json_object_app(req('questions'),
                                     procedure(id, q); [% id, q %] endprocedure) %];

if mode = 'http' then
    laya_uninstall();
    'http://127.0.0.1:' <> systranslate('LATENCY_PORT') <> '/v1' -> ts_base_url;
else
    laya_start();
endif;

;;; Keep each raw response so the server's own time for the call (server_ns, added by
;;; timed_serve.py) can be read back after the clock stops.
lvars last_body = false;
lvars procedure inner = ts_transport;
define lconstant capture(m, u, b, h, t) -> (rb, rh, st);
    inner(m, u, b, h, t) -> (rb, rh, st);
    rb -> last_body;
enddefine;
capture -> ts_transport;

lvars i, t0, total;
repeat warm times ts_eval(state, qs) -> endrepeat;

lvars calls = {}, server = {};
{% for i from 1 to n do
       now_ns() -> t0; ts_eval(state, qs) -> ; now_ns() - t0 -> total;
       total, json_parse(last_body)('server_ns')
   endfor %} -> calls;
;;; split the interleaved (total, server) pairs
{% for i from 1 by 2 to length(calls) do subscrv(i + 1, calls) endfor %} -> server;
{% for i from 1 by 2 to length(calls) do subscrv(i, calls) endfor %} -> calls;
inner -> ts_transport;

;;; JSON work Pop-11 does around every call, timed apart from any transport
lvars body = ts_request(state, qs), status, hdrs;
lvars resp = (laya_transport('POST', '', body, [], 0) -> (hdrs, status));
if mode = 'http' then laya_stop() endif;
lvars encode = {% for i from 1 to n do
                     now_ns() -> t0; ts_request(state, qs) -> ; now_ns() - t0
                  endfor %};
lvars decode = {% for i from 1 to n do
                     now_ns() -> t0; ts_decode(resp) -> (,,); now_ns() - t0
                  endfor %};

lvars out = json_object();
calls -> out('calls_ns'); server -> out('server_ns'); encode -> out('encode_ns'); decode -> out('decode_ns');
string_to_file(json_generate(out), systranslate('LATENCY_OUT'));
laya_stop();
npr('LATENCY-DONE');
