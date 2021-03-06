# tdbc.tcl --
#
#	Definitions of base classes from which TDBC drivers' connections,
#	statements and result sets may inherit.
#
# Copyright (c) 2008 by Kevin B. Kenny
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#
# RCS: @(#) $Id$
#
#------------------------------------------------------------------------------

package require TclOO

namespace eval ::tdbc {
    namespace export connection statement resultset
    variable generalError [list TDBC GENERAL_ERROR HY000 {}]
}

namespace eval ::tdbc::thread {
    namespace export *
    namespace ensemble create -prefixes no

    proc create script {
	package require Thread
	thread::create -preserved "$script\nthread::wait"
    }

    proc send {thread script} {
	package require Thread
	thread::send -async $thread $script
    }

    proc release thread {
	package require Thread
	thread::release $thread
    }
}

namespace eval ::tdbc::ns_thread {
    namespace export *
    namespace ensemble create -prefixes no

    proc create script {
	package require Thread

	lassign [chan pipe] read write
	chan configure $write -buffering full -encoding utf-8 -translation lf -eofchar {} -blocking 0
	chan configure $read  -buffering none -encoding utf-8 -translation lf -eofchar {} -blocking 1
	thread::detach $read
	thread::detach $write

	# Need to test again because the test suite triggers
	# this path even when not on NaviServer.

	if {[info commands ns_thread] eq ""} {
	    set startThread	{thread::create -preserved}
	} else {
	    set startThread	{ns_thread begindetached}
	}

	{*}$startThread [string map [list %chan% [list $read] %script% $script] {
	    %script%

	    proc release {} {
		set ::exit 0
	    }

	    proc readable chan {
		set len	[gets $chan]
		if {[eof $chan]} {
		    # Lost our control channel
		    set ::exit 1
		    return
		}

		# Isolate the control channel from the effects of $script
		after idle [read $chan $len]
	    }

	    set chan	%chan%
	    thread::attach $chan
	    chan event $chan readable [list readable $chan]

	    vwait ::exit
	}]

	# For these threads, the handle is the write end of the chan pipe
	set write
    }

    proc send {thread script} {
	package require Thread
	tsv::lock tdbcThreads {
	    thread::attach $thread
	    try {
		puts -nonewline $thread [string length $script]\n$script
		flush $thread
	    } finally {
		thread::detach $thread
	    }
	}
    }

    proc release thread {
	package require Thread
	send $thread release
    }
}


#------------------------------------------------------------------------------
#
# tdbc::PoolInit --
#
#	Initialize the connection pool machinery
#
# Results:
#	None
#
# Side effects:
#	Creates ::tdbc::pool, ::tdbc::poolDestroy and starts a thread
#	to manage the background tasks associated with the connection pools.
#
#------------------------------------------------------------------------------

proc ::tdbc::PoolInit {{threadPlugin ::tdbc::thread}} {
    variable _thread
    set _thread $threadPlugin

    if {[catch {package require Thread}]} {
	# If threads aren't available, fall back to unpooled connections.
	# TODO: provide a single interp implementation using a namespace
	# variable?  How would detached connection grooming work reliably
	# without assuming the event loop is running?

	proc ::tdbc::pool {driver constructor args} {
	    try {
		uplevel 1 \
		    [list tdbc::${driver}::connection $constructor {*}$args]
	    } on ok connobj {
		oo::objdefine $connobj method forceclose {} {my destroy}
		set connobj
	    }
	}

	proc ::tdbc::poolDestroy {driver args} {}
    } else {
	# Retrieve a connection from the pool for $driver {*}$args
	# If a detached connection wasn't found in the pool, create
	# a fresh one.  If the pool is empty after retrieving a
	# connection, add a connection to the pool in a background thread.
	# Call the release method on the returned connection to
	# release it back to the pool.
	# Handles are issued from the pool in reverse order of which
	# they were added - that is: the most recently released handle
	# will be the next returned.  This is done to allow the pool
	# size to shrink back down to match requirements after a spike
	# in requirements (older handles will remain in the pool until
	# they time out)

	proc ::tdbc::pool {driver constructor args} {
	    variable _thread
	    switch -- $constructor {
		new {}

		create {
		    set args	[lassign $args cmdname]
		    lappend constructor	$cmdname
		}

		default {
		    error "constructor must be new or create"
		}
	    }

	    #package require Thread	;# TIDPOOL
	    #set pool	[list $driver [thread::id] {*}$args]	;# TIDPOOL
	    set pool	[list $driver {*}$args]

	    tsv::lock tdbcPools {
		if {![tsv::exists tdbcPools $pool]} {
		    tsv::set tdbcPools $pool {}
		}
	    }

	    if {![tsv::exists tdbcThreads poolWorker]} {
		# Since we were last called the application destroyed
		# all the pools, shutting down the background thread.
		# Start it back up
		tdbc::PoolInit $_thread
	    }

	    package require tdbc::$driver

	    if {"detach" ni [info class methods ::tdbc::${driver}::connection -all]} {
		# This driver doesn't support detach, fall back to providing a
		# vanilla connection instance
		return [uplevel 1 [list tdbc::${driver}::connection $constructor {*}$args]]
	    }

	    # Create a wrapper class for this driver's connection class 
	    # that automagically retuns this connection to the pool when
	    # the instance is destroyed (unless the forceclose method is
	    # called instead)

	    if {![info object isa object ::tdbc::${driver}::pooledconnection]} {
		oo::class create ::tdbc::${driver}::pooledconnection {
		    variable prevent_release _pool

		    constructor {pool args} {
			set _pool $pool
			next {*}$args
		    }

		    destructor {
			if {![info exists prevent_release]} {
			    # Ensure we aren't returning a connection to the pool that
			    # is in an open transaction.
			    # TODO: is there a reliable way to know if a transaction
			    # is open?
			    catch {my rollback}

			    set handle	[my detach]
			    if {$handle ne ""} {
				# Segfault if we access _pool inside
				# tsv::lock tdbcPools - by then our namespace
				# has gone away.  TclOO bug?  More likely
				# a driver destructor bug.  Could be this bug:
				# https://core.tcl-lang.org/tcl/tktview/37efead06408d9aedd46d0e7f3eeb5910470e65e
				set pool	$_pool
				set driver	[lindex $pool 0]
				tsv::lock tdbcPools {
				    # If tdbcPools $pool doesn't exist, it
				    # means that the application removed it
				    # with tdbc::destroyPool, so don't create
				    # it again by putting this handle back.
				    if {[tsv::exists tdbcPools $pool]} {
					tsv::lpush tdbcPools $pool \
					    [list $handle [clock microseconds]]
					unset handle
				    }
				}
				if {[info exists handle]} {
				    # If the handle var still exists, we didn't
				    # return it to the pool, so clean it up
				    tsv::lappend tdbcZombies $driver $handle
				    if {[tsv::exists tdbcThreads poolWorker]} {
					$::tdbc::_thread send \
					    [tsv::get tdbcThreads poolWorker] \
					    groomDetached
				    }
				}
			    }
			}
			if {[self next] ne ""} next
		    }

		    method forceclose {} {
			set prevent_release 1
			my destroy
		    }
		}
		oo::define ::tdbc::${driver}::pooledconnection superclass ::tdbc::${driver}::connection
	    }

	    while 1 {
		lassign [tsv::lpop tdbcPools $pool] handle lastUsed
		if {$handle eq ""} break	;# Ran out of detached handles

		try {
		    uplevel 1 [list tdbc::${driver}::pooledconnection {*}$constructor $pool -attach $handle]
		} on ok connobj {
		    break
		} on error {errmsg options} {
		    #puts "[thread::id] Error attaching to detached handle $handle [dict get $options -errorcode]: [dict get $options -errorinfo]"
		    continue
		}
	    }

	    if {![info exists connobj]} {
		# No detached handles in the pool, open a new one
		set connobj	[uplevel 1 [list tdbc::${driver}::pooledconnection {*}$constructor $pool {*}$args]]
	    }

	    if {[tsv::llength tdbcPools $pool] == 0} {
		# Connection pool is empty, kick off a connection attempt in
		# the background to prime the pool for the next request
		$::tdbc::_thread send [tsv::get tdbcThreads poolWorker] [list prime $pool]
	    }

	    set connobj
	}

	proc ::tdbc::poolDestroy {driver args} {
	    #package require Thread	;# TIDPOOL
	    #set pool	[list $driver [thread::id] {*}$args]	;# TIDPOOL
	    set pool	[list $driver {*}$args]

	    if {![tsv::exists tdbcPools $pool]} return

	    foreach detachedhandle [tsv::pop tdbcPools $pool] {
		lassign $detachedhandle handle lastUsed
		try {
		    tdbc::${driver}::connection new -attach $handle
		} on ok obj {
		    $obj destroy
		} on error {errmsg options} {}
	    }

	    tsv::lock tdbcThreads {
		if {[tsv::array size tdbcPools] == 0} {
		    # No more pools to mind, release the background thread
		    if {[tsv::exists tdbcThreads poolWorker]} {
			    # TIDPOOL: don't release the background thread, there are multiple pools (one for each thread)
			    $::tdbc::_thread release [tsv::pop tdbcThreads poolWorker]
		    }
		}
	    }
	}

	tsv::lock tdbcThreads {
	    if {![tsv::exists tdbcThreads poolWorker]} {
		tsv::set tdbcThreads poolWorker [$threadPlugin create {
		    # Every 20 seconds, run through the detached handles and remove
		    # those that aren't connected, or have been idle longer than
		    # two minutes, unless it is the last handle in the pool, in
		    # which case the timeout does not apply

		    proc groomDetached {{timeout 120}} {
			global groom_afterid
			after cancel $groom_afterid; set groom_afterid	""

			try {
			    foreach pool [tsv::array names tdbcPools] {
				set driver	[lindex $pool 0]
				package require tdbc::$driver
				# microseconds mainly so that we can use
				# tighter timing in the test suite.
				set now		[clock microseconds]
				tsv::lock tdbcPools {
				    set detachedhandles	[tsv::get tdbcPools $pool]
				    tsv::set tdbcPools $pool {}
				}
				foreach detachedhandle $detachedhandles {
				    lassign $detachedhandle handle lastUsed
				    try {
					tdbc::${driver}::connection new -attach $handle
				    } on ok obj {
					if {
					    (
						[tsv::llength tdbcPools $pool] >= 1 &&
						($now - $lastUsed) / 1e6 > $timeout
					    ) ||
					    ![$obj connected]
					} {
					    $obj destroy
					} else {
					    # Still valid - put it back
					    tsv::lappend tdbcPools $pool [list [$obj detach] $lastUsed]
					}
				    } on error {errmsg options} {
					# TODO: what to do here?  We will leak $handle
					# if we silently ignore this, but the
					# alternative seems worse.
				    }
				}

				if {[tsv::llength tdbcPools $pool] == 0} {
				    prime $pool
				}
				tsv::lock tdbcZombies {
				    foreach driver [tsv::array names tdbcZombies] {
					foreach handle [tsv::pop tdbcZombies $driver] {
					    puts "Dealing with $driver zombie $handle"
					    try {
						tdbc::${driver}::connection new -attach $handle
					    } on ok db {
						$db destroy
					    } on error {errmsg options} {
						# This zombie unkillable.
						# Pretend it doesn't exist.
					    }
					}
				    }
				}
			    }
			} finally {
			    set groom_afterid	[after 20000 groomDetached]
			}
		    }

		    # Attempt to keep at least one detached handle in $pool.

		    proc prime pool {
			global prime_busy
			if {[info exists prime_busy]} return
			set prime_busy	1
			try {
			    if {[tsv::llength tdbcPools $pool] >= 1} return

			    #set args	[lassign $pool driver tid]	;# TIDPOOL
			    set args	[lassign $pool driver]

			    package require tdbc::$driver
			    set connobj	[tdbc::${driver}::connection new {*}$args]
			    set handle	[$connobj detach]
			    if {$handle ne ""} {
				tsv::lock tdbcPools {
				    if {[tsv::exists tdbcPools $pool]} {
					tsv::lappend tdbcPools $pool \
					    [list $handle [clock microseconds]]
				    } else {
					# Most likely the pool was destroyed by
					# tdbc::poolDestroy.  Avoid implicitly
					# recreating it here.
					set db [tdbc::${driver}::connection new -attach $handle]
					$db destroy
				    }
				}
			    }
			} finally {
			    unset -nocomplain prime_busy
			}
		    }

		    set ::groom_afterid	[after 20000 groomDetached]
		}]
	    }
	}
    }
}

proc ::tdbc::pool {driver constructor args} {
    # Defer the pool setup until it's actually needed, so that applications
    # that don't use pools don't have a useless thread started.
    # PoolInit replaces this proc with the real version.

    tdbc::PoolInit
    set tclver	[info tclversion]
    if {[package vsatisfies $tclver 8.6 9.0]} {
	tailcall ::tdbc::pool $driver $constructor {*}$args
    }
    uplevel 1 [list ::tdbc::pool $driver $constructor {*}$args]
}

# This will be replaced with a real implementation when ::tdbc::pool is
# called for the first time

proc ::tdbc::poolDestroy {driver args} {}

#------------------------------------------------------------------------------
#
# tdbc::connection --
#
#	Class that represents a generic connection to a database.
#
#-----------------------------------------------------------------------------

oo::class create ::tdbc::connection {

    # statementSeq is the sequence number of the last statement created.
    # statementClass is the name of the class that implements the
    #	'statement' API.
    # primaryKeysStatement is the statement that queries primary keys
    # foreignKeysStatement is the statement that queries foreign keys

    variable statementSeq primaryKeysStatement foreignKeysStatement

    # The base class constructor accepts no arguments.  It sets up the
    # machinery to do the bookkeeping to keep track of what statements
    # are associated with the connection.  The derived class constructor
    # is expected to set the variable, 'statementClass' to the name
    # of the class that represents statements, so that the 'prepare'
    # method can invoke it.

    constructor {} {
	set statementSeq 0
	namespace eval Stmt {}
    }

    # The 'close' method is simply an alternative syntax for destroying
    # the connection.

    method close {} {
	my destroy
    }

    # The 'prepare' method creates a new statement against the connection,
    # giving its constructor the current statement and the SQL code to
    # prepare.  It uses the 'statementClass' variable set by the constructor
    # to get the class to instantiate.

    method prepare {sqlcode} {
	return [my statementCreate Stmt::[incr statementSeq] [self] $sqlcode]
    }

    # The 'statementCreate' method delegates to the constructor
    # of the class specified by the 'statementClass' variable. It's
    # intended for drivers designed before tdbc 1.0b10. Current ones
    # should forward this method to the constructor directly.

    method statementCreate {name instance sqlcode} {
	my variable statementClass
	return [$statementClass create $name $instance $sqlcode]
    }

    # Derived classes are expected to implement the 'prepareCall' method,
    # and have it call 'prepare' as needed (or do something else and
    # install the resulting statement)

    # The 'statements' method lists the statements active against this 
    # connection.

    method statements {} {
	info commands Stmt::*
    }

    # The 'resultsets' method lists the result sets active against this
    # connection.

    method resultsets {} {
	set retval {}
	foreach statement [my statements] {
	    foreach resultset [$statement resultsets] {
		lappend retval $resultset
	    }
	}
	return $retval
    }

    # The 'transaction' method executes a block of Tcl code as an
    # ACID transaction against the database.

    method transaction {script} {
	my begintransaction
	set status [catch {uplevel 1 $script} result options]
	if {$status in {0 2 3 4}} {
	    set status2 [catch {my commit} result2 options2]
	    if {$status2 == 1} {
		set status 1
		set result $result2
		set options $options2
	    }
	}
	switch -exact -- $status {
	    0 {
		# do nothing
	    }
	    2 - 3 - 4 {
		set options [dict merge {-level 1} $options[set options {}]]
		dict incr options -level
	    }
	    default {
		my rollback
	    }
	}
	return -options $options $result
    }

    # The 'allrows' method prepares a statement, then executes it with
    # a given set of substituents, returning a list of all the rows
    # that the statement returns. Optionally, it stores the names of
    # the columns in '-columnsvariable'.
    # Usage:
    #     $db allrows ?-as lists|dicts? ?-columnsvariable varName? ?--?
    #	      sql ?dictionary?

    method allrows args {

	variable ::tdbc::generalError

	# Grab keyword-value parameters

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]

	# Check postitional parameters 

	set cmd [list [self] prepare]
	if {[llength $args] == 1} {
	    set sqlcode [lindex $args 0]
	} elseif {[llength $args] == 2} {
	    lassign $args sqlcode dict
	} else {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? sqlcode ?dictionary?"
	}
	lappend cmd $sqlcode

	# Prepare the statement

	set stmt [uplevel 1 $cmd]

	# Delegate to the statement to accumulate the results

	set cmd [list $stmt allrows {*}$opts --]
	if {[info exists dict]} {
	    lappend cmd $dict
	}
	set status [catch {
	    uplevel 1 $cmd
	} result options]

	# Destroy the statement

	catch {
	    $stmt close
	}

	return -options $options $result
    }

    # The 'foreach' method prepares a statement, then executes it with
    # a supplied set of substituents.  For each row of the result,
    # it sets a variable to the row and invokes a script in the caller's
    # scope.
    #
    # Usage: 
    #     $db foreach ?-as lists|dicts? ?-columnsVariable varName? ?--?
    #         varName sql ?dictionary? script

    method foreach args {

	variable ::tdbc::generalError

	# Grab keyword-value parameters

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]

	# Check postitional parameters 

	set cmd [list [self] prepare]
	if {[llength $args] == 3} {
	    lassign $args varname sqlcode script
	} elseif {[llength $args] == 4} {
	    lassign $args varname sqlcode dict script
	} else {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? varname sqlcode ?dictionary? script"
	}
	lappend cmd $sqlcode

	# Prepare the statement

	set stmt [uplevel 1 $cmd]

	# Delegate to the statement to iterate over the results

	set cmd [list $stmt foreach {*}$opts -- $varname]
	if {[info exists dict]} {
	    lappend cmd $dict
	}
	lappend cmd $script
	set status [catch {
	    uplevel 1 $cmd
	} result options]

	# Destroy the statement

	catch {
	    $stmt close
	}

	# Adjust return level in the case that the script [return]s

	if {$status == 2} {
	    set options [dict merge {-level 1} $options[set options {}]]
	    dict incr options -level
	}
	return -options $options $result
    }

    # The 'BuildPrimaryKeysStatement' method builds a SQL statement to
    # retrieve the primary keys from a database. (It executes once the
    # first time the 'primaryKeys' method is executed, and retains the
    # prepared statement for reuse.)

    method BuildPrimaryKeysStatement {} {

	# On some databases, CONSTRAINT_CATALOG is always NULL and
	# JOINing to it fails. Check for this case and include that
	# JOIN only if catalog names are supplied.

	set catalogClause {}
	if {[lindex [set count [my allrows -as lists {
	    SELECT COUNT(*) 
            FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
            WHERE CONSTRAINT_CATALOG IS NOT NULL}]] 0 0] != 0} {
	    set catalogClause \
		{AND xtable.CONSTRAINT_CATALOG = xcolumn.CONSTRAINT_CATALOG}
	}
	set primaryKeysStatement [my prepare "
	     SELECT xtable.TABLE_SCHEMA AS \"tableSchema\", 
                 xtable.TABLE_NAME AS \"tableName\",
                 xtable.CONSTRAINT_CATALOG AS \"constraintCatalog\", 
                 xtable.CONSTRAINT_SCHEMA AS \"constraintSchema\", 
                 xtable.CONSTRAINT_NAME AS \"constraintName\", 
                 xcolumn.COLUMN_NAME AS \"columnName\", 
                 xcolumn.ORDINAL_POSITION AS \"ordinalPosition\" 
             FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS xtable 
             INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE xcolumn 
                     ON xtable.CONSTRAINT_SCHEMA = xcolumn.CONSTRAINT_SCHEMA 
                    AND xtable.TABLE_NAME = xcolumn.TABLE_NAME
                    AND xtable.CONSTRAINT_NAME = xcolumn.CONSTRAINT_NAME 
	            $catalogClause
             WHERE xtable.TABLE_NAME = :tableName 
               AND xtable.CONSTRAINT_TYPE = 'PRIMARY KEY'
  	"]
    }

    # The default implementation of the 'primarykeys' method uses the
    # SQL INFORMATION_SCHEMA to retrieve primary key information. Databases
    # that might not have INFORMATION_SCHEMA must overload this method.

    method primarykeys {tableName} {
	if {![info exists primaryKeysStatement]} {
	    my BuildPrimaryKeysStatement
	}
	tailcall $primaryKeysStatement allrows [list tableName $tableName]
    }

    # The 'BuildForeignKeysStatements' method builds a SQL statement to
    # retrieve the foreign keys from a database. (It executes once the
    # first time the 'foreignKeys' method is executed, and retains the
    # prepared statements for reuse.)

    method BuildForeignKeysStatement {} {

	# On some databases, CONSTRAINT_CATALOG is always NULL and
	# JOINing to it fails. Check for this case and include that
	# JOIN only if catalog names are supplied.

	set catalogClause1 {}
	set catalogClause2 {}
	if {[lindex [set count [my allrows -as lists {
	    SELECT COUNT(*) 
            FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
            WHERE CONSTRAINT_CATALOG IS NOT NULL}]] 0 0] != 0} {
	    set catalogClause1 \
		{AND fkc.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG}
	    set catalogClause2 \
		{AND pkc.CONSTRAINT_CATALOG = rc.CONSTRAINT_CATALOG}
	}

	foreach {exists1 clause1} {
	    0 {}
	    1 { AND pkc.TABLE_NAME = :primary}
	} {
	    foreach {exists2 clause2} {
		0 {}
		1 { AND fkc.TABLE_NAME = :foreign}
	    } {
		set stmt [my prepare "
	     SELECT rc.CONSTRAINT_CATALOG AS \"foreignConstraintCatalog\",
                    rc.CONSTRAINT_SCHEMA AS \"foreignConstraintSchema\",
                    rc.CONSTRAINT_NAME AS \"foreignConstraintName\",
                    rc.UNIQUE_CONSTRAINT_CATALOG 
                        AS \"primaryConstraintCatalog\",
                    rc.UNIQUE_CONSTRAINT_SCHEMA AS \"primaryConstraintSchema\",
                    rc.UNIQUE_CONSTRAINT_NAME AS \"primaryConstraintName\",
                    rc.UPDATE_RULE AS \"updateAction\",
		    rc.DELETE_RULE AS \"deleteAction\",
                    pkc.TABLE_CATALOG AS \"primaryCatalog\",
                    pkc.TABLE_SCHEMA AS \"primarySchema\",
                    pkc.TABLE_NAME AS \"primaryTable\",
                    pkc.COLUMN_NAME AS \"primaryColumn\",
                    fkc.TABLE_CATALOG AS \"foreignCatalog\",
                    fkc.TABLE_SCHEMA AS \"foreignSchema\",
                    fkc.TABLE_NAME AS \"foreignTable\",
                    fkc.COLUMN_NAME AS \"foreignColumn\",
                    pkc.ORDINAL_POSITION AS \"ordinalPosition\"
             FROM INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
             INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE fkc
                     ON fkc.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                    AND fkc.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
                    $catalogClause1
             INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE pkc
                     ON pkc.CONSTRAINT_NAME = rc.UNIQUE_CONSTRAINT_NAME
                     AND pkc.CONSTRAINT_SCHEMA = rc.UNIQUE_CONSTRAINT_SCHEMA
                     $catalogClause2
                     AND pkc.ORDINAL_POSITION = fkc.ORDINAL_POSITION
             WHERE 1=1
                 $clause1
                 $clause2
             ORDER BY \"foreignConstraintCatalog\", \"foreignConstraintSchema\", \"foreignConstraintName\", \"ordinalPosition\"
"]
		dict set foreignKeysStatement $exists1 $exists2 $stmt
	    }
	}
    }

    # The default implementation of the 'foreignkeys' method uses the
    # SQL INFORMATION_SCHEMA to retrieve primary key information. Databases
    # that might not have INFORMATION_SCHEMA must overload this method.

    method foreignkeys {args} {

	variable ::tdbc::generalError

	# Check arguments

	set argdict {}
	if {[llength $args] % 2 != 0} {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?..."
	}
	foreach {key value} $args {
	    if {$key ni {-primary -foreign}} {
		set errorcode $generalError
		lappend errorcode badOption
		return -code error -errorcode $errorcode \
		    "bad option \"$key\", must be -primary or -foreign"
	    }
	    set key [string range $key 1 end]
	    if {[dict exists $argdict $key]} {
		set errorcode $generalError
		lappend errorcode dupOption
		return -code error -errorcode $errorcode \
		    "duplicate option \"$key\" supplied"
	    }
	    dict set argdict $key $value
	}

	# Build the statements that query foreign keys. There are four
	# of them, one for each combination of whether -primary
	# and -foreign is specified.

	if {![info exists foreignKeysStatement]} {
	    my BuildForeignKeysStatement
	}
	set stmt [dict get $foreignKeysStatement \
		      [dict exists $argdict primary] \
		      [dict exists $argdict foreign]]
	tailcall $stmt allrows $argdict
    }

    # The default connected method for derived classes that don't
    # support it is just to attempt a select 1

    method connected {} {
	try {
	    my allrows -as lists {select 1}
	} on error {} {
	    return 0
	}
    }

    # Derived classes are expected to implement the 'begintransaction',
    # 'commit', and 'rollback' methods.
	
    # Derived classes are expected to implement 'tables' and 'columns' method.

    # Derived classes may implement a 'detach' method, which should:
    #  - destroy any associated statement and resultset instances
    #  - detach the underlying database connection handle
    #  - destroy the connection instance
    #  - return a string handle that can be used in the future to reattach
    #    to this underlying database connection handle, possibly in a different
    #    thread, by supplying -attach $handle as the only constructor arguments
}

#------------------------------------------------------------------------------
#
# Class: tdbc::statement
#
#	Class that represents a SQL statement in a generic database
#
#------------------------------------------------------------------------------

oo::class create tdbc::statement {

    # resultSetSeq is the sequence number of the last result set created.
    # resultSetClass is the name of the class that implements the 'resultset'
    #	API.

    variable resultSetClass resultSetSeq

    # The base class constructor accepts no arguments.  It initializes
    # the machinery for tracking the ownership of result sets. The derived
    # constructor is expected to invoke the base constructor, and to
    # set a variable 'resultSetClass' to the fully-qualified name of the
    # class that represents result sets.

    constructor {} {
	set resultSetSeq 0
	namespace eval ResultSet {}
    }

    # The 'execute' method on a statement runs the statement with
    # a particular set of substituted variables.  It actually works
    # by creating the result set object and letting that objects
    # constructor do the work of running the statement.  The creation
    # is wrapped in an [uplevel] call because the substitution proces
    # may need to access variables in the caller's scope.

    # WORKAROUND: Take out the '0 &&' from the next line when 
    # Bug 2649975 is fixed
    if {0 && [package vsatisfies [package provide Tcl] 8.6]} {
	method execute args {
	    tailcall my resultSetCreate \
		[namespace current]::ResultSet::[incr resultSetSeq]  \
		[self] {*}$args
	}
    } else {
	method execute args {
	    return \
		[uplevel 1 \
		     [list \
			  [self] resultSetCreate \
			  [namespace current]::ResultSet::[incr resultSetSeq] \
			  [self] {*}$args]]
	}
    }

    # The 'ResultSetCreate' method is expected to be a forward to the
    # appropriate result set constructor. If it's missing, the driver must
    # have been designed for tdbc 1.0b9 and earlier, and the 'resultSetClass'
    # variable holds the class name.

    method resultSetCreate {name instance args} {
	return [uplevel 1 [list $resultSetClass create \
			       $name $instance {*}$args]]
    }

    # The 'resultsets' method returns a list of result sets produced by
    # the current statement

    method resultsets {} {
	info commands ResultSet::*
    }

    # The 'allrows' method executes a statement with a given set of
    # substituents, and returns a list of all the rows that the statement
    # returns.  Optionally, it stores the names of columns in
    # '-columnsvariable'.
    #
    # Usage:
    #	$statement allrows ?-as lists|dicts? ?-columnsvariable varName? ?--?
    #		?dictionary?


    method allrows args {

	variable ::tdbc::generalError

	# Grab keyword-value parameters

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]

	# Check postitional parameters 

	set cmd [list [self] execute]
	if {[llength $args] == 0} {
	    # do nothing
	} elseif {[llength $args] == 1} {
	    lappend cmd [lindex $args 0]
	} else {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? ?dictionary?"
	}

	# Get the result set

	set resultSet [uplevel 1 $cmd]

	# Delegate to the result set's [allrows] method to accumulate
	# the rows of the result.

	set cmd [list $resultSet allrows {*}$opts]
	set status [catch {
	    uplevel 1 $cmd
	} result options]

	# Destroy the result set

	catch {
	    rename $resultSet {}
	}

	# Adjust return level in the case that the script [return]s

	if {$status == 2} {
	    set options [dict merge {-level 1} $options[set options {}]]
	    dict incr options -level
	}
	return -options $options $result
    }

    # The 'foreach' method executes a statement with a given set of
    # substituents.  It runs the supplied script, substituting the supplied
    # named variable. Optionally, it stores the names of columns in
    # '-columnsvariable'.
    #
    # Usage:
    #	$statement foreach ?-as lists|dicts? ?-columnsvariable varName? ?--?
    #		variableName ?dictionary? script

    method foreach args {

	variable ::tdbc::generalError

	# Grab keyword-value parameters

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]
	
	# Check positional parameters

	set cmd [list [self] execute]
	if {[llength $args] == 2} {
	    lassign $args varname script
	} elseif {[llength $args] == 3} {
	    lassign $args varname dict script
	    lappend cmd $dict
	} else {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? varName ?dictionary? script"
	}

	# Get the result set

	set resultSet [uplevel 1 $cmd]

	# Delegate to the result set's [foreach] method to evaluate
	# the script for each row of the result.

	set cmd [list $resultSet foreach {*}$opts -- $varname $script]
	set status [catch {
	    uplevel 1 $cmd
	} result options]

	# Destroy the result set

	catch {
	    rename $resultSet {}
	}

	# Adjust return level in the case that the script [return]s

	if {$status == 2} {
	    set options [dict merge {-level 1} $options[set options {}]]
	    dict incr options -level
	}
	return -options $options $result
    }

    # The 'close' method is syntactic sugar for invoking the destructor

    method close {} {
	my destroy
    }

    # Derived classes are expected to implement their own constructors,
    # plus the following methods:

    # paramtype paramName ?direction? type ?scale ?precision??
    #     Declares the type of a parameter in the statement

}

#------------------------------------------------------------------------------
#
# Class: tdbc::resultset
#
#	Class that represents a result set in a generic database.
#
#------------------------------------------------------------------------------

oo::class create tdbc::resultset {

    constructor {} { }

    # The 'allrows' method returns a list of all rows that a given
    # result set returns.

    method allrows args {

	variable ::tdbc::generalError

	# Parse args

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]
	if {[llength $args] != 0} {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? varName script"
	}

	# Do -columnsvariable if requested

	if {[dict exists $opts -columnsvariable]} {
	    upvar 1 [dict get $opts -columnsvariable] columns
	}

	# Assemble the results

	if {[dict get $opts -as] eq {lists}} {
	    set delegate nextlist
	} else {
	    set delegate nextdict
	}
	set results [list]
	while {1} {
	    set columns [my columns]
	    while {[my $delegate row]} {
		lappend results $row
	    }
	    if {![my nextresults]} break
	}
	return $results
	    
    }

    # The 'foreach' method runs a script on each row from a result set.

    method foreach args {

	variable ::tdbc::generalError

	# Grab keyword-value parameters

	set args [::tdbc::ParseConvenienceArgs $args[set args {}] opts]

	# Check positional parameters

	if {[llength $args] != 2} {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? varName script"
	}

	# Do -columnsvariable if requested
	    
	if {[dict exists $opts -columnsvariable]} {
	    upvar 1 [dict get $opts -columnsvariable] columns
	}

	# Iterate over the groups of results 
	while {1} {

	    # Export column names to caller

	    set columns [my columns]

	    # Iterate over the rows of one group of results

	    upvar 1 [lindex $args 0] row
	    if {[dict get $opts -as] eq {lists}} {
		set delegate nextlist
	    } else {
		set delegate nextdict
	    }
	    while {[my $delegate row]} {
		set status [catch {
		    uplevel 1 [lindex $args 1]
		} result options]
		switch -exact -- $status {
		    0 - 4 {	# OK or CONTINUE
		    }
		    2 {		# RETURN
			set options \
			    [dict merge {-level 1} $options[set options {}]]
			dict incr options -level
			return -options $options $result
		    }
		    3 {		# BREAK
			set broken 1
			break
		    }
		    default {	# ERROR or unknown status
			return -options $options $result
		    }
		}
	    }

	    # Advance to the next group of results if there is one

	    if {[info exists broken] || ![my nextresults]} {
		break
	    }
	}	

	return
    }

    
    # The 'nextrow' method retrieves a row in the form of either
    # a list or a dictionary.

    method nextrow {args} {

	variable ::tdbc::generalError

	set opts [dict create -as dicts]
	set i 0
    
	# Munch keyword options off the front of the command arguments
	
	foreach {key value} $args {
	    if {[string index $key 0] eq {-}} {
		switch -regexp -- $key {
		    -as? {
			dict set opts -as $value
		    }
		    -- {
			incr i
			break
		    }
		    default {
			set errorcode $generalError
			lappend errorcode badOption $key
			return -code error -errorcode $errorcode \
			    "bad option \"$key\":\
                             must be -as or -columnsvariable"
		    }
		}
	    } else {
		break
	    }
	    incr i 2
	}

	set args [lrange $args $i end]
	if {[llength $args] != 1} {
	    set errorcode $generalError
	    lappend errorcode wrongNumArgs
	    return -code error -errorcode $errorcode \
		"wrong # args: should be [lrange [info level 0] 0 1]\
                 ?-option value?... ?--? varName"
	}
	upvar 1 [lindex $args 0] row
	if {[dict get $opts -as] eq {lists}} {
	    set delegate nextlist
	} else {
	    set delegate nextdict
	}
	return [my $delegate row]
    }

    # Derived classes must override 'nextresults' if a single
    # statement execution can yield multiple sets of results

    method nextresults {} {
	return 0
    }

    # Derived classes must override 'outputparams' if statements can
    # have output parameters.

    method outputparams {} {
	return {}
    }

    # The 'close' method is syntactic sugar for destroying the result set.

    method close {} {
	my destroy
    }

    # Derived classes are expected to implement the following methods:

    # constructor and destructor.  
    #        Constructor accepts a statement and an optional
    #        a dictionary of substituted parameters  and
    #        executes the statement against the database. If
    #	     the dictionary is not supplied, then the default
    #	     is to get params from variables in the caller's scope).
    # columns
    #     -- Returns a list of the names of the columns in the result.
    # nextdict variableName
    #     -- Stores the next row of the result set in the given variable
    #        in caller's scope, in the form of a dictionary that maps
    #	     column names to values.
    # nextlist variableName
    #     -- Stores the next row of the result set in the given variable
    #        in caller's scope, in the form of a list of cells.
    # rowcount
    #     -- Returns a count of rows affected by the statement, or -1
    #        if the count of rows has not been determined.

}
