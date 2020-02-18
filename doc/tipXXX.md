# TIP ???: Connection Pooling for TDBC
	State:			Draft
	Type:			Process
	Vote:			Pending
	Author:			Cyan Ogilvie <cyan.ogilvie@gmail.com>
	Tdbc-Version:	1.1.1
	Created:		16-Feb-2020
	Post-History:	
------

## Abstract

This TIP proposes adding a connection pooling facility to TDBC, and the
necessary primitives to TDBC drivers to support this.

## Rationale

There is often a significant latency cost when creating new database
connections \(at least 5 - 20 milliseconds even under ideal conditions\),
and so it is desirable to reuse existing idle connections for
applications like web servers where the the individual users of a database
handle are short lived \(often on the tens of milliseconds timescale
themselves\).  A common approach to this is to provide a pool of open
database connections from which handles are issued to workers and to
which they return when the worker is finished with them.

A second use case is for connection pooling is managing the number of allocated
database handles in a threaded application, which would be unnecessarily high if
each thread allocated the maximum number of handles it required
on initialization, and kept them open and idle for most of the lifespan
of the thread.  A connection pool addresses this by matching the number
of allocated database handles to the number of active handles, across the
entire process, decoupling the number of handles from the number of threads.

A third use case addresses the problem of idle database connections being
closed by the database server after some interval of the server's choosing.
This is a problem for applications in which some set of database handles
will experience long periods of being idle.  Servers such as Amazon's
Aurora versions of PostgreSQL and MySQL will terminate such connections
after a few minutes of being idle, and possibly pause the entire database
if configured to do so \(unpausing takes around a minute, during which the
database is unavailable\).  To avoid this an application would have to
implement some sort of connection keepalive on all the database handles
it has open.  A connection pool addresses this by keeping the number of
idle connections to a minimum, and monitoring those connections' health
\(with the side-effect of preventing those connections from being flagged
as idle by the database server\).

## Specification

To request a connection from the pool, an application 

## Implementation

The implementation of `tdbc::pool` and related tests and documentation
is in a private branch of the tdbc fossil repository.  Implementations of
the `detach` mechanism are available in private branches of the
`tdbc::postgres` and `tdbc::mysql` fossil repositories.

## Copyright

This document has been placed in the public domain.
