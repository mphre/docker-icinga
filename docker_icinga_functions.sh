#!/bin/bash

set -e


# Runtime parameters
: ${DBSERVER:=$DB_PORT_5432_TCP_ADDR} \
  ${DBPORT:=$DB_PORT_5432_TCP_PORT}
: ${DBSERVER:?required parameter missing: DBSERVER (or -link X:db)} \
  ${DBADMIN:?required parameter missing: DBADMIN} \
  ${DBADMPASS:?required parameter missing: DBADMPASS}
# optional:
# PREFIX, DBPORT, WEBPASS (def: auto-generated),
# MSMTP_CONFIG_URL (def: use etcd)
: ${WEBPASS:=$(apg -m 16 -n 1)}

# Internal parameters (defaults, values preserved)
PREFIX=${PREFIX:+${PREFIX}_}
DBUSER=${PREFIX}icinga
DBPASS=$(apg -m 16 -n 1)

##

function main() {
    di_setup
    di_start
}

# Setup everything (according to runtime parameters) so we can run.
function di_setup() {
    di_reconfigure icinga-idoutils ${PREFIX}icinga
    di_reconfigure icinga-web ${PREFIX}icinga_web
    di_configure_msmtp
}

# Start all daemons and serve forever.
function di_start() {
    local x
    x=exec
    if [[ ${-/i} != $- ]]; then
	# don't exec in interactive shell
	x=
    fi
    $x /usr/bin/supervisord
}

# Update configuration according to runtime config parameters and setup the
# database and user accordingly.
function di_reconfigure() { # pkg dbname
    local pkg dbname func

    pkg=${1:?specify pkg}
    dbname=${2:?specify dbname}

    # prepare configuration and scripts
    di_reconfigure_prepare $pkg $dbname
    # pkg-specific, look for di_reconfigure_prepare__PKG (where PKG is $pkg
    # escaped)
    func=di_reconfigure_prepare__${pkg//[-]/_}
    if typeset -F $func >/dev/null; then
	$func $dbname
    fi

    # reconfigure, will write app config files and setup the databases if
    # necessary (db users, structure, populate contents)
    dpkg-reconfigure -f noninteractive $pkg
}

# Prepare state for (re-)running config and postinst scripts (dpkg-reconfigure)
# Update dbconfig-common configuration and debconf flags according to runtime
# config parameters (specified via environment).  Update the database user
# details so that we may connect normally.
function di_reconfigure_prepare() { # pkg dbname
    local pkg dbname

    pkg=${1:?specify pkg}
    dbname=${2:?specify dbname}

    di_reconfigure_prepare_dbc_config $pkg $dbname
    di_reconfigure_prepare_db_dbuser $pkg
    di_reconfigure_prepare_dbc_flags $pkg
}

# Additional setup for icinga-web.
# - update icinga-web DB install script; upstream hardcodes owner username,
#   replace it with the configured username
# - configure web user password and print it so it's available via
#   `docker logs`
function di_reconfigure_prepare__icinga_web() (
    pkg=icinga-web

    # load values stored in dbconfig-common configs
    . /usr/share/dbconfig-common/dpkg/common

    dbc_config $pkg configure
    dbc_read_package_config

    script=$dbc_share/data/$dbc_basepackage/install/pgsql

    sed -i -re "/^\\\set icinga_web_owner/s/'[^']+'/'$dbc_dbuser'/" $script
    dbc_logline "Updated icinga_web_owner to '$dbc_dbuser' in '$script'"

    cat <<EOF |debconf-set-selections
icinga-web  icinga-web/rootpassword-repeat  password  $WEBPASS
icinga-web  icinga-web/rootpassword  password  $WEBPASS
EOF
    dbc_logline "Configured icinga-web admin credentials"
    dbc_logline "WEBUSER: root"
    dbc_logline "WEBPASS: $WEBPASS"
)

# Update dbconfig-common config for package with values passed into the
# container at runtime.
function di_reconfigure_prepare_dbc_config() ( # pkg dbname
    pkg=${1:?specify pkg}
    dbname=${2:?specify dbname}

    # parameters managed internally, we want to preserve those between runs
    # of the same container
    dbc_dbuser=$DBUSER
    dbc_dbpass=$DBPASS
    dbc_authmethod_admin='password'
    dbc_authmethod_user='password'

    # load values stored in dbconfig-common configs; on first run this won't
    # do anything, but on subsequent runs it will load first-time config
    . /usr/share/dbconfig-common/dpkg/common

    dbc_config $pkg configure
    dbc_read_package_config

    # user-controlled runtime parameters and hardcoded values
    dbc_install='true'
    dbc_dbserver=$DBSERVER
    dbc_dbport=$DBPORT
    dbc_dbtype='pgsql'
    dbc_dbname="$dbname"
    dbc_dbadmin=$DBADMIN
    dbc_dbadmpass=$DBADMPASS
    dbc_ssl=true
    dbc_authmethod_admin='password'
    dbc_authmethod_user='password'

    # write values back to dbconfig-common config (for next run)
    export UCF_FORCE_CONFFNEW=true
    dbc_write_package_config
    # this isn't normally stored, but we need it to be able to reconfigure on
    # restart
    echo "dbc_dbadmpass='$dbc_dbadmpass'" >> $dbc_packageconfig
)

# Update flags in debconf.  Normally dbconfig-common uses flags in debconf to
# remember when things (like updating cache or setting up DB) have already been
# done.  With docker, this needs to be controlled at runtime because a package
# is installed once in an image, but the image could be run against different
# databases, etc.
# Note: watch this bug, may change what we need to do with debconf when fixed
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=476946
function di_reconfigure_prepare_dbc_flags() ( # pkg
    pkg=${1:?specify pkg}

    # load values stored in dbconfig-common configs
    . /usr/share/dbconfig-common/dpkg/common

    dbc_config $pkg configure
    dbc_read_package_config

    # config may have changed so ensure reconfigure doens't skip writing it to
    # debconf and update reinstall flag to ensure DB install scripts are run
    echo reset $pkg/internal/skip-preseed |debconf-communicate
    # try to figure out if DB needs to be installed; this is here because
    # icinga DB install script
    # (/usr/share/dbconfig-common/data/icinga-idoutils/install/pgsql) is not
    # idempotent and would fail if tables already exist
    key=$dbc_package/dbconfig-reinstall
    if pkg_db_exists && pkg_db_populated; then
	reinstall=false
    else
	reinstall=true
    fi
    echo "$dbc_package $key boolean $reinstall" |debconf-set-selections
    dbc_logline "updated $key to '$reinstall'"
)

# Since we're using a random generated password for dbuser, it is going to
# change on each image re-run (not stop+start, just new run).  Make sure it's
# updated in the DB before we try connecting to it.
function di_reconfigure_prepare_db_dbuser() ( # pkg
    pkg=${1:?specify pkg}

    # load values stored in dbconfig-common configs
    . /usr/share/dbconfig-common/dpkg/common

    dbc_config $pkg configure
    dbc_read_package_config
    dbc_set_dbtype_defaults $dbc_dbtype

    $dbc_createuser_cmd
)

# Configure msmtp for sending emails through a mail hub.
# Cut down permissions on the config file as it may contain passwords in clear
# text, add any users who need to send mail to 'mail' group.
# see http://devblog.virtage.com/2013/05/email-sending-from-ubuntu-server-via-google-apps-smtp-with-msmtp/
function di_configure_msmtp() {
    if [[ -n $MSMTP_CONFIG_URL ]]; then
	di_configure_msmtp_cfgurl
    fi

    [[ -e /etc/msmtprc ]] || return 1
    chgrp mail /etc/msmtprc
    chmod 640 /etc/msmtprc
}

# Get msmtp config from a URL
function di_configure_msmtp_cfgurl() {
    wget -qO /etc/msmtprc ${MSMTP_CONFIG_URL:?}
}

function psqlq() { # PSQL_ARGS
    psql -qtA --host=$dbc_dbserver ${dbc_dbport:+--port=$dbc_dbport} "$@"
}

function psqladmq() { # PSQL_ARGS
    PGPASSWORD="$dbc_dbadmpass" psqlq --username=$dbc_dbadmin "$@"
}

function psqlusrq() { # PSQL_ARGS
    PGPASSWORD="$dbc_dbpass" psqlq --username=$dbc_dbuser \
	--dbname=$dbc_dbname "$@"
}

function pkg_db_exists() {
    # could use _dbc_pgsql_check_database instead
    local q
    q="select 1 from pg_database where datname='$dbc_dbname';"
    [[ -n $(psqladmq --command="$q") ]]
}

# A hack to check if it looks like the DB has already been populated.
function pkg_db_populated() {
    local q sqlfile tbl
    # find first table being created by the install script
    sqlfile=$dbc_share/data/$dbc_basepackage/install/$dbc_dbtype
    tbl=$(sed -nre '/^CREATE TABLE/{s/CREATE TABLE\s+(.*)\s+\($/\1/p;q}' \
	$sqlfile)
    q="select exists(select * from information_schema.tables \
       where table_name='$tbl')"
    [[ $(psqlusrq --command="$q") == t ]]
}

# For debugging/dev
function _dbc_run() ( # pkg cmd [args..]
    pkg=${1:?specify pkg}
    shift

    # load values stored in dbconfig-common configs
    . /usr/share/dbconfig-common/dpkg/common

    dbc_config $pkg configure
    dbc_read_package_config

    # remaining args are the command + args to run
    "$@"
)
