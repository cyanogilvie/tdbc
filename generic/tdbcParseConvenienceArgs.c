#if DEBUG
#    include <signal.h>
#    include <unistd.h>
#    include <time.h>
#    include "names.h"
#    define DBG(...) fprintf(stdout, ##__VA_ARGS__)
#    define FDBG(...) fprintf(stdout, ##__VA_ARGS__)
#    define DEBUGGER raise(SIGTRAP)
#    define TIME(label, task) \
    do { \
	struct timespec first; \
	struct timespec second; \
	struct timespec after; \
	double empty; \
	double delta; \
	clock_gettime(CLOCK_MONOTONIC, &first); /* Warm up the call */ \
	clock_gettime(CLOCK_MONOTONIC, &first); \
	clock_gettime(CLOCK_MONOTONIC, &second); \
	task; \
	clock_gettime(CLOCK_MONOTONIC, &after); \
	empty = second.tv_sec - first.tv_sec + (second.tv_nsec - first.tv_nsec)/1e9; \
	delta = after.tv_sec - second.tv_sec + (after.tv_nsec - second.tv_nsec)/1e9 - empty; \
	DBG("Time for %s: %.1f microseconds\n", label, delta * 1e6); \
    } while(0)

#else
#    define DBG(...) /* nop */
#    define FDBG(...) /* nop */
#    define DEBUGGER /* nop */
#    define TIME(label, task) task
#endif
/*
 * tdbcParseConvenienceArgs.c --
 *
 *	Parse the args: -as {lists dicts} -columnsvariable foo sql ?dict?
 *
 * Copyright (c) 2020 by Cyan Ogilvie
 *
 * Please refer to the file, 'license.terms' for the conditions on
 * redistribution of this file and for a DISCLAIMER OF ALL WARRANTIES.
 *
 * RCS: @(#) $Id$
 *
 *-----------------------------------------------------------------------------
 */

#include "tdbcInt.h"
#include <ctype.h>

struct ParseLit {
    Tcl_Obj*	as;
    Tcl_Obj*	columnsvar;
    Tcl_Obj*	dicts;
    Tcl_Obj*	empty;
};


/*
 *-----------------------------------------------------------------------------
 *
 * DeletePiData --
 *
 *	Frees our per-interp literal Tcl_Objs
 *
 *-----------------------------------------------------------------------------
 */

static void
DeleteParseLit(
    ClientData clientData,
    Tcl_Interp* interp
) {
    struct ParseLit* lit = clientData;

    if (lit) {
	if (lit->as) {
	    Tcl_DecrRefCount(lit->as);
	    lit->as = NULL;
	}
	if (lit->columnsvar) {
	    Tcl_DecrRefCount(lit->columnsvar);
	    lit->columnsvar = NULL;
	}
	if (lit->dicts) {
	    Tcl_DecrRefCount(lit->dicts);
	    lit->dicts = NULL;
	}
	if (lit->empty) {
	    Tcl_DecrRefCount(lit->empty);
	    lit->empty = NULL;
	}

	ckfree(lit);
	lit = NULL;
    }
}

/*
 *-----------------------------------------------------------------------------
 *
 * Tdbc_ParseConvenienceArgs --
 *
 *	Parse the standard allrows (and similar) args
 *
 * Usage:
 *	argv - a list of the arguments to parse.
 *	opts - will be replaced with a dictionary containing the parsed options.
 *	tail - will be set to a list of elements from argv that follow the
 *		options.
 *	opts and tail have references and must be released by the caller.  If
 *	opts or tail aren't NULL when they are set, their refs will be
 *	decremented before being replaced.
 *
 * Result:
 *	Standard Tcl result.  opts and tail will only be set if the result is
 *	TCL_OK.  An error message will be left in interp if the result is
 *	TCL_ERROR
 *
 *-----------------------------------------------------------------------------
 */

TDBCAPI int
Tdbc_ParseConvenienceArgs(
    Tcl_Interp* interp,
    Tcl_Obj* args,
    Tcl_Obj** opts,
    Tcl_Obj** tail
){
    int res = TCL_OK;
    Tcl_Obj* newopts = NULL;
    Tcl_Obj** argv = NULL;
    Tcl_Obj* newtail = NULL;
    int argc, i;
    const char* options[] = {"-as", "-columnsvariable", "--", NULL};
    enum {OPT_AS, OPT_COLUMNSVARIABLE, OPT_END};
    int option_index;
    const char* formats[] = {"lists", "dicts", NULL};
    enum {FMT_DICTS, FMT_LISTS};
    int fmt_index;
    int saw_as = 0;
    struct ParseLit* lit = Tcl_GetAssocData(interp,
	    "tdbc::ParseConvenienceArgs", NULL);

    if (lit == NULL) {
	/* Initialize our per-interp literal Tcl_Objs */

	lit = ckalloc(sizeof(struct ParseLit));

	lit->as = Tcl_NewStringObj("-as", 3);
	lit->columnsvar = Tcl_NewStringObj("-columnsvariable", 16);
	lit->dicts = Tcl_NewStringObj("dicts", 5);
	lit->empty = Tcl_NewStringObj("", 0);

	Tcl_IncrRefCount(lit->as);
	Tcl_IncrRefCount(lit->columnsvar);
	Tcl_IncrRefCount(lit->dicts);
	Tcl_IncrRefCount(lit->empty);

	Tcl_SetAssocData(interp, "tdbc::ParseConvenienceArgs",
		&DeleteParseLit, lit);
    }

    res = Tcl_ListObjGetElements(interp, args, &argc, &argv);
    if (res != TCL_OK) {
	goto finally;
    }

    Tcl_IncrRefCount(newopts = Tcl_NewDictObj());

    for (i = 0; i < argc; i++) {
	const char* s = Tcl_GetString(argv[i]);

	if (s[0] != '-') {
	    /* Not an option, signals the end of options */
	    break;
	}
	if (s[0] == '-' && s[1] == '-' && s[2] != 0) {
	    /*
	     * Not an option - a SQL string that starts with a comment:
	     * end of options
	     */
	    break;
	}

	res = Tcl_GetIndexFromObj(interp, argv[i], options, "option", 0,
				  &option_index);
	if (res != TCL_OK) {
	    goto finally;
	}

	switch (option_index) {
	case OPT_AS:
	    if (i == argc-1) {
		Tcl_SetObjResult(interp, Tcl_NewStringObj(
			    "No value given for -as", -1));
		res = TCL_ERROR;
		goto finally;
	    }

	    i++;

	    /* Ensure that the value for -as is a valid format */
	    res = Tcl_GetIndexFromObj(interp, argv[i], formats, "variable type",
		    0, &fmt_index);
	    if (res != TCL_OK) {
		goto finally;
	    }

	    res = Tcl_DictObjPut(interp, newopts, lit->as, argv[i]);
	    if (res != TCL_OK) {
		goto finally;
	    }

	    saw_as = 1;
	    break;

	case OPT_COLUMNSVARIABLE:
	    if (i == argc-1) {
		Tcl_SetObjResult(interp, Tcl_NewStringObj(
			    "No value given for -columnsvariable", -1));
		res = TCL_ERROR;
		goto finally;
	    }

	    i++;

	    res = Tcl_DictObjPut(interp, newopts, lit->columnsvar, argv[i]);
	    if (res != TCL_OK) {
		goto finally;
	    }
	    break;

	case OPT_END:
	    i++;
	    goto endOptions;

	default:
	    /* Should be unreachable */
	    Tcl_SetObjResult(interp,
		    Tcl_ObjPrintf("Invalid option index %d", option_index));
	    res = TCL_ERROR;
	    goto finally;
	}
    }

 endOptions:
    /* If -as wasn't provided, set it with the default of "dicts" */

    if (!saw_as) {
	res = Tcl_DictObjPut(interp, newopts, lit->as, lit->dicts);
	if (res != TCL_OK) {
	    goto finally;
	}
    }

    /* Package the remaining args into a list */

    if (i >= argc) {
	Tcl_IncrRefCount(newtail = lit->empty);
    } else {
	Tcl_IncrRefCount(newtail = Tcl_NewListObj(argc - i, argv + i));
    }

    if (*opts) {
	Tcl_DecrRefCount(*opts);
    }
    Tcl_IncrRefCount(*opts = newopts);

    if (*tail) {
	Tcl_DecrRefCount(*tail);
    }
    Tcl_IncrRefCount(*tail = newtail);

 finally:
    if (newopts) {
	Tcl_DecrRefCount(newopts);
	newopts = NULL;
    }
    if (newtail) {
	Tcl_DecrRefCount(newtail);
	tail = NULL;
    }
    return res;
}

/*
 *-----------------------------------------------------------------------------
 *
 * TdbcParseConvenienceArgsObjCmd --
 *
 *	Parse the standard allrows (and similar) args
 *
 * Usage:
 *	::tdbc::ParseConvenienceArgs argv optsVar
 *
 * Results:
 *	Sets a variable with the name given in optsVar to a dictionary
 *	containing the -as $format and -columnsvariable varname options.
 *	The dictionary will always contain -as, defaulting to dicts,
 *	-columnsvariable will only be present if it was supplied.
 *	Returns the remaining argments after the options have been stripped off
 *
 *-----------------------------------------------------------------------------
 */

MODULE_SCOPE int
TdbcParseConvenienceArgsObjCmd(
    ClientData clientData,	/* Unused */
    Tcl_Interp* interp,		/* Tcl interpreter */
    int objc,			/* Parameter count */
    Tcl_Obj *const objv[]	/* Parameter vector */
) {
    int res = TCL_OK;
    Tcl_Obj* opts = NULL;
    Tcl_Obj* tail = NULL;

    /* Check param count */

    if (objc != 3) {
	Tcl_WrongNumArgs(interp, 1, objv, "argv optsVar");
	return TCL_ERROR;
    }

    res = Tdbc_ParseConvenienceArgs(interp, objv[1], &opts, &tail);
    if (res != TCL_OK) {
	goto finally;
    }

    /* Store the parsed opts dictionary into the variable optsVar */

    if (NULL==Tcl_ObjSetVar2(interp, objv[2], NULL, opts, TCL_LEAVE_ERR_MSG)) {
	res = TCL_ERROR;
	goto finally;
    }

    Tcl_SetObjResult(interp, tail);

 finally:
    if (opts) {
	Tcl_DecrRefCount(opts);
	opts = NULL;
    }
    if (tail) {
	Tcl_DecrRefCount(tail);
	tail = NULL;
    }
    return res;
}
