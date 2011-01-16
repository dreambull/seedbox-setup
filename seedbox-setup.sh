#!/bin/bash

function check_install {
    if [ -z "`which "$1" 2>/dev/null`" ]
    then
        executable=$1
        shift
        while [ -n "$1" ]
        do
            DEBIAN_FRONTEND=noninteractive apt-get -q -y install "$1"
            print_info "$1 installed for $executable"
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
    # TODO: check the validity of user input
    echo "Please input your username and password below."
    echo "They will be used to login Transmission and/or FTP."
    read -p "Username: " USERNAME
    PASSWORD1="1"
    PASSWORD2="2"
    while [ "$PASSWORD1" != "$PASSWORD2" ]
    do
        read -s -p "Password: " PASSWORD1; echo
        read -s -p "Password again: " PASSWORD2; echo
        if [ "$PASSWORD1" != "$PASSWORD2" ]
        then
            print_warn "Two passwords not match"
        fi
    done
    PASSWORD="$PASSWORD1"
}

# Install and configure Transmission, the Bittorrent client. A user is created
# and all downloads will be in this user's home directory.  
function install_transmission {
    read -p "Transmission control port: " RPC_PORT
    check_install transmission-daemon transmission-daemon
    check_install mkpasswd mkpasswd
    
    invoke-rc.d transmission-daemon stop
    
    useradd -d /home/$USERNAME -m -p `mkpasswd $PASSWORD` $USERNAME
    
    sed -i "s/^USER.*/USER=$USERNAME/" /etc/init.d/transmission-daemon
    chown -R $USERNAME:$USERNAME /var/lib/transmission-daemon/*
    chown root:$USERNAME /etc/transmission-daemon/
    chown $USERNAME:$USERNAME /etc/transmission-daemon/settings.json
    
    # TODO: check if the file exists
    # Another possible location is /etc/transmission-daemon/settings.json, 
    # sometimes /var/lib/.../settings.json is a symbolic link to it.
    SETTING=/var/lib/transmission-daemon/info/settings.json
    cp $SETTING $SETTING.orig
    
    cat > $SETTING <<END
{
    "download-dir": "\/home\/$USERNAME",
    "port-forwarding-enabled": false,
    "rpc-authentication-required": true,
    "rpc-enabled": true,
    "rpc-password": "$PASSWORD",
    "rpc-port": $RPC_PORT,
    "rpc-username": "$USERNAME",
    "rpc-whitelist-enabled": false,
    "speed-limit-down": 5000,
    "speed-limit-down-enabled": true,
    "speed-limit-up": 1000,
    "speed-limit-up-enabled": true,
    "upload-slots-per-torrent": 10
}
END
    
    invoke-rc.d transmission-daemon start
}

# Install and configure nginx, the web server, with Perl fastcgi support. 
function install_nginx {
    check_remove /usr/sbin/apache2 'apache2*'
    
    check_install nginx nginx
    check_install libfcgi-perl libfcgi-perl
    # psmisc package is needed because perl-fastcgi script calls `killall`
    check_install psmisc psmisc
    
    wget $WGET_PARAMS -O /usr/bin/fastcgi-wrapper.pl http://github.com/bull/seedbox-setup/raw/master//fastcgi-wrapper.pl
    chmod a+x /usr/bin/fastcgi-wrapper.pl
    wget $WGET_PARAMS -O /etc/init.d/perl-fastcgi http://github.com/bull/seedbox-setup/raw/master//perl-fastcgi
    chmod a+x /etc/init.d/perl-fastcgi
    mkdir -p /var/run/www
    chown www-data:www-data /var/run/www
    update-rc.d perl-fastcgi defaults
    invoke-rc.d perl-fastcgi restart
    wget $WGET_PARAMS -O /etc/nginx/fastcgi_perl http://github.com/bull/seedbox-setup/raw/master//fastcgi_perl
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
}
END
    invoke-rc.d nginx restart  
}

# Install and configure vnStat, a traffic monitor tool. A graph representation
# can be reached via Web at http://<VPS IP>/vnstat.cgi
function install_vnstat {
    check_install vnstat vnstat vnstati

    if [ -n "$(cat /etc/network/interfaces | grep venet0)" ]
    then
        INTERFACE="venet0"
        print_info "Network interface is venet0"
    elif [ -n "$(cat /etc/network/interfaces | grep eth0)" ]
    then
        INTERFACE="eth0"
        print_info "Network interface is eth0"
    else
        die "Unknown network interface"
    fi
    sed -i "s/^Interface.*/Interface \"$INTERFACE\"/" /etc/vnstat.conf
    vnstat -u -i $INTERFACE
    invoke-rc.d vnstat restart
    wget $WGET_PARAMS -O /var/www/nginx-default/vnstat.cgi http://github.com/bull/seedbox-setup/raw/master//vnstat.cgi
    sed -i "s/eth0/$INTERFACE/" /var/www/nginx-default/vnstat.cgi
    chmod a+x /var/www/nginx-default/vnstat.cgi
}

function install_vsftpd {
    read -p "FTP port: " FTP_PORT
    check_install vsftpd vsftpd
    
    # For a full list of available options, see http://vsftpd.beasts.org/vsftpd_conf.html
    cp /etc/vsftpd.conf /etc/vsftpd.conf.orig
    cat > /etc/vsftpd.conf <<END
listen=YES
listen_port=$FTP_PORT
anonymous_enable=NO
local_enable=YES
local_umask=022
write_enable=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/private/vsftpd.pem
END

    invoke-rc.d vsftpd restart
}

###############################################################################
# START OF PROGRAM
###############################################################################
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

check_sanity

# get some parameters
USERNAME=
PASSWORD=
RPC_PORT=
FTP_PORT=

WGET_PARAMS="--no-check-certificate"

case $1 in
transmission)
    get_auth_info
    install_transmission
    ;;
nginx)
    install_nginx
    ;;
vnstat)
    install_vnstat
    ;;
vsftpd)
    get_auth_info
    install_vsftpd
    ;;
all)
    get_auth_info
    install_transmission
    install_nginx
    install_vnstat
    install_vsftpd
    ;;
*)
    echo 'Usage:' `basename $0` '[option]'
    echo 'Available option:'
    for option in transmission nginx vnstat vsftpd all
    do
        echo '  -' $option
    done
    ;;
esac