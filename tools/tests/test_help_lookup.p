;;; test_help_lookup.p — which file HELP finds for a name (run via tools/test-libs.sh)
;;;
;;; A few documentation files were renamed so that the tree checks out on
;;; Windows, which does not allow < in a file name (issue #18): hash_<
;;; became hash_lt.  The old name must still find the file, through the
;;; table of renamed files in pop/ved/src/vdsysfile.p.
;;;
;;; The lookup is watched through vedsysfilelog, which vedsysfile calls
;;; with the file it found just before handing it to VED; exitfrom then
;;; stops it short of opening the editor.

uses poptest;

vars vedsysfilelog;

;;; The file name (without directory) HELP would show for arg, or false.
;;; exitfrom does not stack output locals, so the answer is kept in a
;;; variable and returned after the lookup.
vars help_found;

define help_lookup(arg);
    lvars arg;
    dlocal vedargument = arg;
    ;;; Skip VED's start-up (init files, then the terminal type, which
    ;;; mishaps with no $TERM, as under ssh or CI); the lookup needs neither.
    dlocal vedsetupdone = true;

    define dlocal vedsysfilelog(cllr, request, file);
        lvars cllr, request, file;
        if file then sys_fname_nam(file) -> help_found endif;
        exitfrom(help_lookup)
    enddefine;

    define dlocal vedsysfileerror(doc_type, doc_name);
        lvars doc_type, doc_name;
        exitfrom(help_lookup)
    enddefine;

    ved_help();
enddefine;

define help_finds(arg);
    lvars arg;
    false -> help_found;
    help_lookup(arg);
    help_found
enddefine;

check('HELP HASH_LT finds hash_lt', help_finds('hash_lt'), 'hash_lt');
check('HELP HASH_< still finds it, by its old name', help_finds('hash_<'), 'hash_lt');
check('so does HASH_< typed in capitals', help_finds('HASH_<'), 'hash_lt');
check('HELP HASH_ is unaffected', help_finds('hash_'), 'hash_');
check('an ordinary name is unaffected', help_finds('if'), 'if');
check('a missing file is still missing', help_finds('no_such_help_file_xyz'), false);

test_summary();
