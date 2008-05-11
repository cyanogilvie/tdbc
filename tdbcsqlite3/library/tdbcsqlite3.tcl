# tdbcsqlite3.tcl --
#
#    SQLite3 database driver for TDBC
#
# Copyright (c) 2008 by Kevin B. Kenny.
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#
# RCS: @(#) $Id: tdbcodbc.tcl,v 1.47 2008/02/27 02:08:27 kennykb Exp $
#
#------------------------------------------------------------------------------

package require Tdbc
package require sqlite3
package provide Tdbcsqlite3 0.1a0

namespace eval tdbc::sqlite3 {
    namespace export connection
}

#------------------------------------------------------------------------------
#
# tdbc::sqlite3::connection --
#
#	Class representing a SQLite3 database connection
#
#------------------------------------------------------------------------------

::oo::class create ::tdbc::sqlite3::connection {

    superclass ::tdbc::connection

    # The constructor accepts a database name and opens the database.

    constructor databaseName {
	my variable statementClass
	set statementClass ::tdbc::sqlite3::statement
	next
	sqlite3 [namespace current]::db $databaseName
	db nullvalue \ufffd
    }

    # The 'tables' method introspects on the tables in the database.

    method tables {{pattern %}} {
	set retval {}
	my foreach row {
	    SELECT * from sqlite_master
	    WHERE type IN ('table', 'view')
	    AND name LIKE :pattern
	} {
	    dict set row name [string tolower [dict get $row name]]
	    dict set retval [dict get $row name] $row
	}
	return $retval
    }

    # The 'columns' method introspects on columns of a table.

    method columns {table {pattern %}} {
	regsub -all ' $table '' table
	set retval {}
	set pattern [string map [list \
				     * {[*]} \
				     ? {[?]} \
				     \[ \\\[ \
				     \] \\\[ \
				     _ ? \
				     % *] [string tolower $pattern]]
	my foreach origrow "PRAGMA table_info('$table')" {
	    set row {}
	    dict for {key value} $origrow {
		dict set row [string tolower $key] $value
	    }
	    dict set row name [string tolower [dict get $row name]]
	    if {![string match $pattern [dict get $row name]]} {
		continue
	    }
	    switch -regexp -matchvar info [dict get $row type] {
		{^(.+)\(\s*([[:digit:]]+)\s*,\s*([[:digit:]]+)\s*\)\s*$} {
		    dict set row type [string tolower [lindex $info 1]]
		    dict set row precision [lindex $info 2]
		    dict set row scale [lindex $info 3]
		}
		{^(.+)\(\s*([[:digit:]]+)\s*\)\s*$} {
		    dict set row type [string tolower [lindex $info 1]]
		    dict set row precision [lindex $info 2]
		    dict set row scale 0
		}
		default {
		    dict set row type [string tolower [dict get $row type]]
		    dict set row precision 0
		    dict set row scale 0
		}
	    }
	    dict set row nullable [expr {![dict get $row notnull]}]
	    dict set retval [dict get $row name] $row
	}
	return $retval
    }

    # The 'preparecall' method prepares a call to a stored procedure.
    # SQLite3 does not have stored procedures, since it's an in-process
    # server.

    method preparecall {call} {
	return -code error {SQLite3 does not support stored procedures}
    }

    # The 'begintransaction' method launches a database transaction

    method begintransaction {} {
	db eval {BEGIN TRANSACTION}
    }

    # The 'commit' method commits a database transaction

    method commit {} {
	db eval {COMMIT}
    }

    # The 'rollback' method abandons a database transaction

    method rollback {} {
	db eval {ROLLBACK}
    }

    # The 'transaction' method executes a script as a single transaction.
    # We override the 'transaction' method of the base class, since SQLite3
    # has a faster implementation of the same thing. (The base class's generic
    # method should also work.) 
    # (Don't overload the base class method, because 'break', 'continue'
    # and 'return' in the transaction body don't work!)

    #method transaction {script} {
    #	uplevel 1 [list {*}[namespace code db] transaction $script]
    #}

    # TEMP

    method prepare {sqlCode} {
	set result [next $sqlCode]
	return $result
    }
	
    method getDBhandle {} {
	return [namespace which db]
    }
}

#------------------------------------------------------------------------------
#
# tdbc::sqlite3::statement --
#
#	Class representing a statement to execute against a SQLite3 database
#
#------------------------------------------------------------------------------

::oo::class create ::tdbc::sqlite3::statement {

    superclass ::tdbc::statement

    # The constructor accepts the handle to the connection and the SQL
    # code for the statement to prepare.  All that it does is to parse the
    # statement and store it.  The parse is used to support the 
    # 'params' and 'paramtype' methods.

    constructor {connection sqlcode} {
	next
	my variable resultSetClass
	set resultSetClass ::tdbc::sqlite3::resultset
	my variable Params
	set Params {}
	my variable db
	set db [$connection getDBhandle]
	my variable sql
	set sql $sqlcode
	foreach token [::tdbc::tokenize $sqlcode] {
	    if {[string index $token 0] in {$ : @}} {
		dict set Params [string range $token 1 end] \
		    {type Tcl_Obj precision 0 scale 0 nullable 1 direction in}
	    }
	}
    }

    # The 'params' method returns descriptions of the parameters accepted
    # by the statement

    method params {} {
	my variable Params
	return $Params
    }

    # The 'paramtype' method need do nothing; Sqlite3 uses manifest typing.

    method paramtype args {;}

    method getDBhandle {} {
	my variable db
	return $db
    }

    method getSql {} {
	my variable sql
	return $sql
    }

}

#-------------------------------------------------------------------------------
#
# tdbc::sqlite3::resultset --
#
#	Class that represents a SQLlite result set in Tcl
#
#-------------------------------------------------------------------------------

::oo::class create ::tdbc::sqlite3::resultset {

    superclass ::tdbc::resultset

    constructor {statement args} {
	# TODO - Consider deferring running the query until the
	#        caller actually does 'nextrow' or 'foreach' - so that
	#        we know which, and can avoid the strange unpacking of
	#        data that happens in RunQuery in the 'foreach' case.

	next
	my variable db
	set db [$statement getDBhandle]
	my variable sql
	set sql [$statement getSql]
	my variable resultArray
	my variable columns
	set columns {}
	my variable results
	set results {}
	if {[llength $args] == 0} {
	    # Variable substitutions evaluated in caller's context
	    uplevel 1 [list $db eval $sql \
			   [namespace which -variable resultArray] \
			   [namespace code {my RecordResult}]]
	} elseif {[llength $args] == 1} {
	    # Variable substitutions are in the dictionary at [lindex $args 0].
	    # We have to move over into a different proc to get rid of the
	    # 'resultArray' alias in the current callframe
	    my variable paramDict
	    set paramDict [lindex $args 0]
	    my RunQuery
	} else {
	    return -code error "wrong # args: should be\
               [lrange [info level 0] 0 1] statement ?dictionary?"
	}
	my variable RowCount
	set RowCount [$db changes]
	my variable Cursor
	set Cursor -1
    }

    # RunQuery runs the query against the database. This procedure can have
    # no local variables, because they can suffer name conflicts with 
    # variables in the substituents of the query.  It therefore makes
    # method calls to get the SQL statement to execute and the name of the
    # result array (which is a fully qualified name).

    method RunQuery {} {
	dict with [my ParamDictName] {
	    [my getDBhandle] eval [my GetSql] [my ResultArrayName] {
		my RecordResult
	    }
	}
    }

    # Return the fully qualified name of the dictionary containing the 
    # parameters.

    method ParamDictName {} {
	my variable paramDict
	return [namespace which -variable paramDict]
    }

    # Return the SQL code to execute.

    method GetSql {} {
	my variable sql
	return $sql
    }

    # Return the fully qualified name of an array that will hold a row of
    # results from a query

    method ResultArrayName {} {
	my variable resultArray
	return [namespace which -variable resultArray]
    }

    # Record one row of results from a query by appending it as a dictionary
    # to the 'results' list.  As a side effect, set 'columns' to a list
    # comprising the names of the columns of the result.

    method RecordResult {} {
	my variable resultArray
	my variable results
	my variable columns
	set columns $resultArray(*)
	set dict {}
	foreach key $columns {
	    if {$resultArray($key) ne "\ufffd"} {
		dict set dict $key $resultArray($key)
	    }
	}
	lappend results $dict
    }

    method getDBhandle {} {
	my variable db
	return $db
    }

    # Return a list of the columns

    method columns {} {
	my variable columns
	return $columns
    }

    # Return the next row of the result set

    method nextrow args {
	my variable Cursor
	my variable results
	set as dicts
	set i 0

	foreach {key value} $args {
	    if {[string index $key 0] eq {-}} {
		switch -regexp -- $key {
		    -as? {
			set as $value
		    }
		    -- {
			incr i
			break
		    }
		    default {
			return -code error -errorcode {TDBC badOption} \
			    "bad option \"$key\":\
                             must be -as"
		    }
		}
	    } else {
		break
	    }
	    incr i 2
	}
	set args [lrange $args[set args {}] $i end]
	if {[llength $args] != 1} {
	    return -code error "wrong # args: should be\
                [lrange [info level 0] 0 1] ?-as dicts|lists? ?--? varName"
	}
	upvar 1 [lindex $args 0] row
	switch -exact -- $as {
	    dicts - lists {}
	    default {
		return -code error "bad variable type \"$as\":\
                    must be lists or dicts"
	    }
	}
	if {[incr Cursor] >= [llength $results]} {
	    return 0
	} elseif {$as eq {dicts}} {
	    set row [lindex $results $Cursor]
	} else {
	    my variable columns
	    set row {}
	    set d [lindex $results $Cursor]
	    foreach key $columns {
		if {[dict exists $d $key]} {
		    lappend row [dict get $d $key]
		} else {
		    lappend row {}
		}
	    }
	}
	return 1
    }

    # Return the number of rows affected by a statement

    method rowcount {} {
	my variable RowCount
	return $RowCount
    }
}