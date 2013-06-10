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
    # Ubuntu 12.04 moved mkpasswd into whois package
    check_install whois whois

    invoke-rc.d transmission-daemon stop

    useradd -d /home/$USERNAME -m -p `mkpasswd $PASSWORD` $USERNAME
    mkdir -p /home/$USERNAME/transmission
    chown debian-transmission:debian-transmission /home/$USERNAME/transmission
    chmod 777 /home/$USERNAME/transmission

    #sed -i "s/^USER.*/USER=$USERNAME/" /etc/init.d/transmission-daemon
    #chown -R $USERNAME:$USERNAME /var/lib/transmission-daemon/*
    #chown root:$USERNAME /etc/transmission-daemon/
    #chown $USERNAME:$USERNAME /etc/transmission-daemon/settings.json

    # TODO: check if the file exists
    # Another possible location is /etc/transmission-daemon/settings.json,
    # sometimes /var/lib/.../settings.json is a symbolic link to it.
    SETTING=/var/lib/transmission-daemon/info/settings.json
    cp $SETTING $SETTING.orig
    cat > $SETTING <<END_TR_SETTING
{
    "download-dir": "\/home\/$USERNAME\/transmission",
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
    "upload-slots-per-torrent": 10,
    "umask": 0
}
END_TR_SETTING

    invoke-rc.d transmission-daemon start
}

# Install and configure nginx, the web server, with Perl fastcgi support.
function install_nginx {
    check_remove /usr/sbin/apache2 'apache2*'

    check_install nginx nginx
    check_install libfcgi-perl libfcgi-perl
    # psmisc package is needed because perl-fastcgi script calls `killall`
    check_install psmisc psmisc
    cat > /usr/bin/fastcgi-wrapper.pl <<END_FASTCGI_WRAPPER
#!/usr/bin/perl

use FCGI;
#perl -MCPAN -e 'install FCGI'
use Socket;
use POSIX qw(setsid);
#use Fcntl;

require 'syscall.ph';

&daemonize;

#this keeps the program alive or something after exec'ing perl scripts
END() { } BEGIN() { }
*CORE::GLOBAL::exit = sub { die "fakeexit\nrc=".shift()."\n"; };
eval q{exit};
if (\$@) {
	exit unless \$@ =~ /^fakeexit/;
};

&main;

sub daemonize() {
    chdir '/'                 or die "Can't chdir to /: \$!";
    defined(my \$pid = fork)   or die "Can't fork: \$!";
    exit if \$pid;
    setsid                    or die "Can't start a new session: \$!";
    umask 0;
}

sub main {
        #\$socket = FCGI::OpenSocket( "127.0.0.1:8999", 10 ); #use IP sockets
        \$socket = FCGI::OpenSocket( "/var/run/www/perl.sock", 10 ); #use UNIX sockets - user running this script must have w access to the 'www' folder!!
        \$request = FCGI::Request( \*STDIN, \*STDOUT, \*STDERR, \%req_params, \$socket );
        if (\$request) { request_loop()};
            FCGI::CloseSocket( \$socket );
}

sub request_loop {
        while( \$request->Accept() >= 0 ) {

           #processing any STDIN input from WebServer (for CGI-POST actions)
           \$stdin_passthrough ='';
           \$req_len = 0 + \$req_params{'CONTENT_LENGTH'};
           if ((\$req_params{'REQUEST_METHOD'} eq 'POST') && (\$req_len != 0) ){
                my \$bytes_read = 0;
                while (\$bytes_read < \$req_len) {
                        my \$data = '';
                        my \$bytes = read(STDIN, \$data, (\$req_len - \$bytes_read));
                        last if (\$bytes == 0 || !defined(\$bytes));
                        \$stdin_passthrough .= \$data;
                        \$bytes_read += \$bytes;
                }
            }

            #running the cgi app
            if ( (-x \$req_params{SCRIPT_FILENAME}) &&  #can I execute this?
                 (-s \$req_params{SCRIPT_FILENAME}) &&  #Is this file empty?
                 (-r \$req_params{SCRIPT_FILENAME})     #can I read this file?
            ){
		pipe(CHILD_RD, PARENT_WR);
		my \$pid = open(KID_TO_READ, "-|");
		unless(defined(\$pid)) {
			print("Content-type: text/plain\r\n\r\n");
                        print "Error: CGI app returned no output - Executing \$req_params{SCRIPT_FILENAME} failed !\n";
			next;
		}
		if (\$pid > 0) {
			close(CHILD_RD);
			print PARENT_WR \$stdin_passthrough;
			close(PARENT_WR);

			while(my \$s = <KID_TO_READ>) { print \$s; }
			close KID_TO_READ;
			waitpid(\$pid, 0);
		} else {
	                foreach \$key ( keys %req_params){
        	           \$ENV{\$key} = \$req_params{\$key};
                	}
        	        # cd to the script's local directory
	                if (\$req_params{SCRIPT_FILENAME} =~ /^(.*)\/[^\/]+$/) {
                        	chdir \$1;
                	}

			close(PARENT_WR);
			close(STDIN);
			#fcntl(CHILD_RD, F_DUPFD, 0);
			syscall(&SYS_dup2, fileno(CHILD_RD), 0);
			#open(STDIN, "<&CHILD_RD");
			exec(\$req_params{SCRIPT_FILENAME});
			die("exec failed");
		}
            }
            else {
                print("Content-type: text/plain\r\n\r\n");
                print "Error: No such CGI app - \$req_params{SCRIPT_FILENAME} may not exist or is not executable by this process.\n";
            }

        }
}
END_FASTCGI_WRAPPER

    chmod a+x /usr/bin/fastcgi-wrapper.pl
    cat > /etc/init.d/perl-fastcgi <<END_PERL_FASTCGI
#!/bin/bash
PERL_SCRIPT=/usr/bin/fastcgi-wrapper.pl
FASTCGI_USER=www-data
FASTCGI_SOCKDIR=/var/run/www
RETVAL=0

# \$FASTCGI_SOCKDIR sometimes gets removed after reboot.
if [ ! -d \$FASTCGI_SOCKDIR ]
then
    mkdir -p \$FASTCGI_SOCKDIR
    chown \$FASTCGI_USER:\$FASTCGI_USER \$FASTCGI_SOCKDIR
fi

case "\$1" in
    start)
      su - \$FASTCGI_USER -c \$PERL_SCRIPT
      RETVAL=\$?
  ;;
    stop)
      killall -9 fastcgi-wrapper.pl
      RETVAL=\$?
  ;;
    restart)
      killall -9 fastcgi-wrapper.pl
      su - \$FASTCGI_USER -c \$PERL_SCRIPT
      RETVAL=\$?
  ;;
    *)
      echo "Usage: perl-fastcgi {start|stop|restart}"
      exit 1
  ;;
esac
exit \$RETVAL
END_PERL_FASTCGI

    chmod a+x /etc/init.d/perl-fastcgi
    mkdir -p /var/run/www
    chown www-data:www-data /var/run/www
    update-rc.d perl-fastcgi defaults
    invoke-rc.d perl-fastcgi restart
    cat > /etc/nginx/fastcgi_perl <<END_FASTCGI_PERL
location ~ \.(cgi|pl)$ {
    gzip off;
    include /etc/nginx/fastcgi_params;
    fastcgi_index index.pl;
    fastcgi_pass unix:/var/run/www/perl.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
}
END_FASTCGI_PERL

    # TODO: authentication
    cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.orig
    cat > /etc/nginx/sites-available/default <<END_NGINX_SETTING
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
END_NGINX_SETTING

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
    cat > /var/www/nginx-default/vnstat.cgi <<END_VNSTAT_CGI
#!/usr/bin/perl -w

# vnstat.cgi -- example cgi for vnStat image output
# copyright (c) 2008-2009 Teemu Toivola <tst at iki dot fi>
#
# based on mailgraph.cgi
# copyright (c) 2000-2007 ETH Zurich
# copyright (c) 2000-2007 David Schweikert <dws@ee.ethz.ch>
# released under the GNU General Public License


my \$host = 'Some Server';
my \$scriptname = 'vnstat.cgi';

# temporary directory where to store the images
my \$tmp_dir = '/tmp/vnstatcgi';

# location of vnstati
my \$vnstati_cmd = '/usr/bin/vnstati';

# cache time in minutes, set 0 to disable
my \$cachetime = '15';

# shown interfaces, remove unnecessary lines
my @graphs = (
        { interface => 'eth0' },
#        { interface => 'eth1' },
);


################


my \$VERSION = "1.2";

sub graph(\$\$\$)
{
	my (\$interface, \$file, \$param) = @_;
	my \$result = \`"\$vnstati_cmd" -i "\$interface" -c \$cachetime \$param -o "\$file"\`;
}


sub print_html()
{
	print "Content-Type: text/html\n\n";

	print <<HEADER;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="Generator" content="vnstat.cgi \$VERSION">
<title>Traffic Statistics for \$host</title>
<style type="text/css">
<!--
a { text-decoration: underline; }
a:link { color: #b0b0b0; }
a:visited { color: #b0b0b0; }
a:hover { color: #000000; }
small { font-size: 8px; color: #cbcbcb; }
-->
</style>
</head>
<body bgcolor="#ffffff">
HEADER

	for my \$n (0..\$#graphs) {
		print "<p><a href=\"\$scriptname?\${n}-f\"><img src=\"\$scriptname?\${n}-hs\" border=\"0\" alt=\"\$graphs[\$n]{interface} summary\"></a></p>\n";
	}

	print <<FOOTER;
<small>Images generated using <a href="http://humdi.net/vnstat/">vnStat</a> image output.</small>
</body>
</html>
FOOTER
}

sub print_fullhtml(\$)
{
	my (\$interface) = @_;

	print "Content-Type: text/html\n\n";

	print <<HEADER;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="Generator" content="vnstat.cgi \$VERSION">
<title>Traffic Statistics for \$host</title>
<style type="text/css">
<!--
a { text-decoration: underline; }
a:link { color: #b0b0b0; }
a:visited { color: #b0b0b0; }
a:hover { color: #000000; }
small { font-size: 8px; color: #cbcbcb; }
-->
</style>
</head>
<body bgcolor="#ffffff">
HEADER

	print "<table border=\"0\"><tr><td>\n";
	print "<img src=\"\$scriptname?\${interface}-s\" border=\"0\" alt=\"\${interface} summary\">";
	print "</td><td>\n";
	print "<img src=\"\$scriptname?\${interface}-h\" border=\"0\" alt=\"\${interface} hourly\">";
	print "</td></tr><tr><td valign=\"top\">\n";
	print "<img src=\"\$scriptname?\${interface}-d\" border=\"0\" alt=\"\${interface} daily\">";
	print "</td><td valign=\"top\">\n";
	print "<img src=\"\$scriptname?\${interface}-t\" border=\"0\" alt=\"\${interface} top 10\"><br>\n";
	print "<img src=\"\$scriptname?\${interface}-m\" border=\"0\" alt=\"\${interface} monthly\" vspace=\"4\">";
	print "</td></tr>\n</table>\n";

	print <<FOOTER;
<small><br>&nbsp;Images generated using <a href="http://humdi.net/vnstat/">vnStat</a> image output.</small>
</body>
</html>
FOOTER
}

sub send_image(\$)
{
	my (\$file)= @_;

	-r \$file or do {
		print "Content-type: text/plain\n\nERROR: can't find \$file\n";
		exit 1;
	};

	print "Content-type: image/png\n";
	print "Content-length: ".((stat(\$file))[7])."\n";
	print "\n";
	open(IMG, \$file) or die;
	my \$data;
	print \$data while read(IMG, \$data, 16384)>0;
}

sub main()
{
	mkdir \$tmp_dir, 0777 unless -d \$tmp_dir;

	my \$img = \$ENV{QUERY_STRING};
	if(defined \$img and \$img =~ /\S/) {
		if(\$img =~ /^(\d+)-s$/) {
			my \$file = "\$tmp_dir/vnstat_\$1.png";
			graph(\$graphs[\$1]{interface}, \$file, "-s");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-hs$/) {
			my \$file = "\$tmp_dir/vnstat_\$1_hs.png";
			graph(\$graphs[\$1]{interface}, \$file, "-hs");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-d$/) {
			my \$file = "\$tmp_dir/vnstat_\$1_d.png";
			graph(\$graphs[\$1]{interface}, \$file, "-d");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-m$/) {
			my \$file = "\$tmp_dir/vnstat_\$1_m.png";
			graph(\$graphs[\$1]{interface}, \$file, "-m");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-t$/) {
			my \$file = "\$tmp_dir/vnstat_\$1_t.png";
			graph(\$graphs[\$1]{interface}, \$file, "-t");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-h$/) {
			my \$file = "\$tmp_dir/vnstat_\$1_h.png";
			graph(\$graphs[\$1]{interface}, \$file, "-h");
			send_image(\$file);
		}
		elsif(\$img =~ /^(\d+)-f$/) {
			print_fullhtml(\$1);
		}
		else {
			die "ERROR: invalid argument\n";
		}
	}
	else {
		if (\$#graphs == 0) {
			print_fullhtml(0);
		} else {
			print_html();
		}
	}
}

main();
END_VNSTAT_CGI

    sed -i "s/eth0/$INTERFACE/" /var/www/nginx-default/vnstat.cgi
    chmod a+x /var/www/nginx-default/vnstat.cgi
}

function install_vsftpd {
    read -p "FTP port: " FTP_PORT
    check_install vsftpd vsftpd

    # For a full list of available options, see http://vsftpd.beasts.org/vsftpd_conf.html
    cp /etc/vsftpd.conf /etc/vsftpd.conf.orig
    cat > /etc/vsftpd.conf <<END_VSFTPD_CONF
listen=YES
listen_port=$FTP_PORT
anonymous_enable=NO
local_enable=YES
chroot_local_user=YES
local_umask=022
write_enable=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/private/vsftpd.pem
END_VSFTPD_CONF

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

#WGET_PARAMS="--no-check-certificate"

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