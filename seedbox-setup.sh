#!/bin/bash

function check_install {
    if [ -z "`which "$1" 2>/dev/null`" ]
    then
        executable=$1
        shift
        while [ -n "$1" ]
        do
            DEBIAN_FRONTEND=noninteractive apt-get -q -y install "$1"
            print_info "$1 installed for $executbale"
            shift
        done
    else
        print_warn "$2 already installed"
    fi
}

function check_remove {
    if [ -n "`which "$1" 2>/dev/null`" ]
    then
        DEBIAN_FRONTEND=noninteractive apt-get -q -y remove --purge "$2"
        print_info "$2 removed"
    else
        print_warn "$2 is not installed"
    fi
}

function check_sanity {
    if [ $(/usr/bin/id -u) != "0" ]
    then
        die "Must be run by root user"
    fi
    
    if [ ! -f /etc/debian_version ]
    then
        die "Distribution not supported"
    fi
}

function print_info {
    echo -n -e '\e[1;36m'
    echo -n $1
    echo -e '\e[0m'
}

function print_warn {
    echo -n -e '\e[1;33m'
    echo -n $1
    echo -e '\e[0m'
}

function die {
    echo "ERROR: $1" > /dev/null 1>&2
    exit 1
}

function get_auth_info {
    read -p "Please input Transmission username: " USERNAME
    PASSWORD1="1"
    PASSWORD2="2"
    while [ $PASSWORD1 != $PASSWORD2 ]
    do
        read -s -p "Please input Transmission password: " PASSWORD1
        read -s -p "Please input Transmission password again: " PASSWORD2
        if [ $PASSWORD1 != $PASSWORD2 ]
        then
            echo "The two passwords you inputed not match!"
        if
    done
    PASSWORD=$PASSWORD1
    read -p "Please input Transmission control port: " PORT
}

function install_transmission {
    check_install transmission transmission-daemon
    
    invoke-rc.d transmission-daemon stop
    
    # TODO: check if the file exists
    SETTING=/etc/transmission-daemon/setting.json
    sed -i "s/^.*rpc-authentication-required.*/\"rpc-authentication-required\": true,/" $SETTING
    sed -i "s/^.*rpc-whitelist-enabled.*/\"rpc-whitelist-enabled\": false,/" $SETTING
    sed -i "s/^.*rpc-username.*/\"rpc-username\": \"$USERNAME\",/" $SETTING
    sed -i "s/^.*rpc-password.*/\"rpc-password\": \"$PASSWORD\",/" $SETTING
    sed -i "s/^.*rpc-port.*/\"rpc-port\": $PORT,/" $SETTING
    
    invoke-rc.d transmission-daemon start
}

function install_monitor {
    check_remove /usr/sbin/apache2 'apache2*'
    check_install monitor vnstat vnstati wget nginx libfcgi-perl
    
    # install nginx web server with perl fastcgi support
    wget -O /usr/bin/fastcgi-wrapper.pl http://github.com/bull/seedbox-setup/raw/master//fastcgi-wrapper.pl
    chmod a+x /usr/bin/fastcgi-wrapper.pl
    wget -O /etc/init.d/perl-fastcgi http://github.com/bull/seedbox-setup/raw/master//perl-fastcgi
    chmod a+x /etc/init.d/perl-fastcgi
    mkdir -p /var/run/www
    chown www-data:www-data /var/run/www
    update-rc.d perl-fastcgi defaults
    invoke-rc.d perl-fastcgi start
    wget -O /etc/nginx/fastcgi_perl http://github.com/bull/seedbox-setup/raw/master//fastcgi_perl
    # TODO: authentication
    cat > /etc/nginx/sites-available/default <<END
server {
        listen   80 default;
        server_name  localhost;

        root   /var/www/nginx-default;
        access_log  /var/log/nginx/localhost.access.log;

        include /etc/nginx/fastcgi_perl;

        location / {
                index  index.html index.htm;
        }

END
    invoke-rc.d nginx restart    
    
    # config vnstat things
    INTERFACE=$(cat /etc/network/interfaces | grep -e venet[0-9] -o -m 1)
    if [ $? -ne 0 ]
    then
        INTERFACE="eth0"
    fi
    sed -i "s/^Interface.*/Interface \"$INTERFACE\"/" /etc/vnstat.conf
    vnstat -u -i $INTERFACE
    invoke-rc.d vnstat restart
    wget -O /var/www/nginx-default/vnstat.cgi http://github.com/bull/seedbox-setup/raw/master//vnstat.cgi
    sed -i "s/eth0/$INTERFACE/" /var/www/nginx-default/vnstat.cgi
    chmod a+x /var/www/nginx-default/vnstat.cgi
}

###############################################################################
# START OF PROGRAM
###############################################################################
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

check_sanity

# get some parameters
USERNAME="Transmission"
PASSWORD="Transmission"
PORT=9091

case $1 in
transmission)
    get_auth_info
    install_transmission
    ;;
monitor)
    install_monitor
    ;;
all)
    get_auth_info
    install_transmission
    install_monitor
*)
    echo 'Usage:' `basename $0` '[option]'
    echo 'Available option:'
    for option in transmission monitor all
    do
        echo '  -' $option
    done
    ;;
esac