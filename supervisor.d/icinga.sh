#! /bin/sh
# icinga host/service/network monitoring and management system
#
#		Written by Miquel van Smoorenburg <miquels@cistron.nl>.
#		Modified for Debian GNU/Linux
#		by Ian Murdock <imurdock@gnu.ai.mit.edu>.
#               Clamav version by Magnus Ekdahl <magnus@debian.org>
#		Nagios version by Sean Finney <seanius@debian.org> and probably others
#		nagios2 version by Marc Haber <mh+debian-packages@zugschlus.de>
#		icinga version by Alexander Wirt <formorer@debian.org>
#               supervisor version by phre <phre@gmx.com>


. /lib/lsb/init-functions

DAEMON=/usr/sbin/icinga
NAME="icinga"
DESC="icinga monitoring daemon"
ICINGACFG="/etc/icinga/icinga.cfg"
CGICFG="/etc/icinga/cgi.cfg"
NICENESS=5

[ -x "$DAEMON" ] || exit 0
[ -r /etc/default/icinga ] && . /etc/default/icinga

# this is from madduck on IRC, 2006-07-06
# There should be a better possibility to give daemon error messages
# and/or to log things
log()
{
  case "$1" in
    [[:digit:]]*) success=$1; shift;;
    *) :;;
  esac
  log_action_begin_msg "$1"; shift
  log_action_end_msg ${success:-0} "$*"
}

check_run () {
	if [ ! -d '/var/run/icinga' ];
	then
		mkdir /var/run/icinga
		chown nagios:nagios /var/run/icinga
		chmod 0750 /var/run/icinga
	fi
}

check_started () {
  if [ -e "$CGICFG" ]
  then
  	check_cmd=$(get_config icinga_check_command $CGICFG)
  	if [ ! "$check_cmd" ]; then
    		log 6 "unable to determine icinga_check_command from $CGICFG!" 
    		return 6
	fi
   else 
        check_cmd="/usr/lib/nagios/plugins/check_nagios /var/lib/icinga/status.dat 5 '/usr/sbin/icinga'"
   fi

  eval $check_cmd >/dev/null
		
  if [ -f "$THEPIDFILE" ]; then
    pid="$(cat $THEPIDFILE)"
    if [ "$pid" ] && kill -0 $pid >/dev/null 2>/dev/null; then
      return 0    # Is started
    fi
  fi
  return 1	# Isn't started
}

#
#	get_config()
#
#	grab a config option from icinga.cfg (or possibly another icinga config
#	file if specified).  everything after the '=' is echo'd out, making
#	this a nice generalized way to get requested settings.
#
get_config () {
  CFG=$ICINGACFG
  test "$2" && CFG="$2"
  if [ "$2" ]; then
    set -- `grep ^$1 $2 | sed 's@=@ @'`
  else
    set -- `grep ^$1 $ICINGACFG | sed 's@=@ @'`
  fi
  if [ -n "$1" ]
  then
      shift
      echo $*
  fi
}

check_config () {
  if $DAEMON -v $ICINGACFG >/dev/null 2>&1 ; then
    # First get the user/group etc Icinga is running as
    nagios_user="$(get_config icinga_user)"
    nagios_group="$(get_config icinga_group)"
    log_file="$(get_config log_file)"
    log_dir="$(dirname $log_file)"

    return 0    # Config is ok
  else
    # config is not okay, so let's barf the error to the user
    $DAEMON -v $ICINGACFG
  fi
}

check_named_pipe () {
  icingapipe="$(get_config command_file)"
  if [ -p "$icingapipe" ]; then
    return 1   # a named pipe exists
  elif [ -e "$icingapipe" ];then
    return 1
  else
    return 0   # no named pipe exists
  fi
}

if [ ! -f "$ICINGACFG" ]; then
  log_failure_msg "There is no configuration file for Icinga."
  exit 6
fi

THEPIDFILE=$(get_config "lock_file")
[ -n "$THEPIDFILE" ] || THEPIDFILE='/var/run/icinga/icinga.pid'

start () {
  DIRECTORY=$(dirname $THEPIDFILE)
  [ ! -d $DIRECTORY ] && mkdir -p $DIRECTORY
  chown nagios:nagios $DIRECTORY

    if ! check_named_pipe; then
      log_action_msg "named pipe exists - removing"
      rm -f $icingapipe
    fi
    if check_config; then
      exec $DAEMON $ICINGACFG
    else
      log_failure_msg "errors in config!"
      log_end_msg 1
      exit 1
    fi
}


check_run
start
