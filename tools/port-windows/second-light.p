;;; Run with basepop11 and the startup image (./poplog pop11 second-light.p).
;;; Exercises what first-light.p could not: autoloading, objectclass,
;;; processes, strings, properties, files, and a library that is compiled
;;; when it is loaded.

uses objectclass;
define :class point; slot px = 3; slot py = 4; enddefine;
define :method norm2(p:point); px(p) * px(p) + py(p) * py(p) enddefine;
norm2(newpoint()) =>

vars p = consproc(0, procedure(); suspend(1, 1); suspend(2, 1); 3 endprocedure);
[% runproc(0, p), runproc(0, p), runproc(0, p) %] =>

vars prop = newproperty([], 16, false, "perm");
"one" -> prop("a"); "two" -> prop("b");
[% prop("a"), prop("b"), prop("c") %] =>

'Windows' <> ' and ' <> uppertolower('POPLOG') =>
syssort([pear apple fig], alphabefore) =>
sqrt(2.0) * sqrt(2.0) =>
2 ** 100 =>
22 / 7 =>

vars f = systmpfile(false, 'poplog', '.txt');
vars d = syscreate(f, 1, "line");
syswrite(d, 'written and read back\n', 22); sysclose(d);
vars buf = inits(80);
sysopen(f, 0, "line") -> d;
substring(1, sysread(d, buf, 80) - 1, buf) =>
sysclose(d); sysdelete(f) =>

length(sys_file_match('*.md', '', false, false)) > 0 =>
datalength(sysdaytime()) > 10 =>
sys_host_name() /= nullstring =>
