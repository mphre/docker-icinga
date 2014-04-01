#! /bin/sh
# icinga-dataobjects daemon

# Author: Alexander Wirt <formorer@debian.org>
# Supervisor version: phre <phre@gmx.com>

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="icinga-dataobjects daemon"
NAME=ido2db
DAEMON=/usr/sbin/$NAME
PIDFILE=/var/run/icinga/$NAME.pid
SCRIPTNAME=/etc/init.d/$NAME
CFG=/etc/icinga/ido2db.cfg 

# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0

# Read configuration variable file if it is present
[ -r /etc/default/icinga ] && . /etc/default/icinga

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.0-6) to ensure that this file is present.
. /lib/lsb/init-functions


check_started () {
	start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON --test > /dev/null 
	if [ $? -eq 0 ]
	then
		return 1
	else
		return 0
	fi
}

cleanup_socket () {
	SOCKET=$( get_config socket_name )
	test -z "$SOCKET" && return
	check_started
	[ $? -eq 1 ] && return
	if [ -e $SOCKET ] 
	then
		log_warning_msg "Remove stale socket $SOCKET"
		rm $SOCKET
	fi

}

#
#	get_config()
#
#	grab a config option from icinga.cfg (or possibly another icinga config
#	file if specified).  everything after the '=' is echo'd out, making
#	this a nice generalized way to get requested settings.
#
get_config () {
  if [ "$2" ]; then
    set -- `grep ^$1 $2 | sed 's@=@ @'`
  else
    set -- `grep ^$1 $CFG | sed 's@=@ @'`
  fi
  shift
  echo $*
}

#
# Function that starts the daemon/service
#
do_start()
{
	test -d $(dirname $PIDFILE) || mkdir -p $(dirname $PIDFILE) 
	chown nagios:nagios $(dirname $PIDFILE)
	#cleanup stale socket
	cleanup_socket

	exec $DAEMON -f -c $CFG || return 2
}


do_start
