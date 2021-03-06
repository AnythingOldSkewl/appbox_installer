#!/usr/bin/env bash
# Appbox installer
#
# Just run this on your Ubuntu VNC app via SSH or in the terminal (Applications > Terminal Emulator) using:
# sudo bash -c "bash <(curl -Ls https://raw.githubusercontent.com/coder8338/appbox_installer/main/appbox_installer.sh)"
#
# We do not work for appbox, we're a friendly community helping others out, we will try to keep this as update to date as possible!

set -e
set -u

export DEBIAN_FRONTEND=noninteractive

run_as_root() {
    if ! whoami | grep -q 'root'; then
        echo "Please enter your user password, then run this script again!"
        sudo -s
        return 0
    fi
}

install_nginx() {
    echo -n "Checking if nginx is installed: "
    if [ -f /etc/nginx/sites-enabled/default ]; then
        echo "[ YES ]"
        add_proxy_headers
    else
        if which nginx; then
            echo "[ YES ]"
            echo "nginx is already installed, but /etc/nginx/sites-enabled/default doesn't exist!"
            echo "Please uninstall nginx and completely remove the /etc/nginx folder, try: sudo apt-get purge nginx nginx-common"
            return 1
        fi
        echo "[ NO ]"
        echo "Installing nginx"
        apt update
        apt install -y nginx openssl || true
        add_proxy_headers
    fi
    if [ ! -f /etc/supervisor/conf.d/nginx.conf ]; then
    cat << EOF > /etc/supervisor/conf.d/nginx.conf
[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/nginx.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/nginx.log
stderr_logfile_maxbytes=0
EOF
    fi
}

add_proxy_headers() {
    if ! grep -q "proxy_set_header" /etc/nginx/sites-enabled/default; then
        sed -i '/^server {/i \
map $http_host $port {\
        default 80;\
        "~^[^\:]+:(?<p>\d+)$" $p;\
}\
' /etc/nginx/sites-enabled/default
        sed -i '/server_name _/a \
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Server $host;\
        proxy_set_header X-Forwarded-Port $port;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_http_version 1.1;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection $http_connection;\
        proxy_set_header Host $host;\
        proxy_cache_bypass $http_upgrade;\
        proxy_set_header X-Forwarded-Host $host;\
        proxy_connect_timeout 300s;\
        proxy_read_timeout 300s;\
        client_header_timeout 300s;\
        client_body_timeout 300s;\
        client_max_body_size 1000M;\
        send_timeout 300s;' /etc/nginx/sites-enabled/default
    fi
}

configure_nginx() {
    NAME=$1
    PORT=$2
    APPBOX_USER=$(echo "${HOSTNAME}" | awk -F'.' '{print $2}')
    if ! grep -q "/${NAME} {" /etc/nginx/sites-enabled/default; then
        sed -i '/server_name _/a \
        location /'${NAME}' {\
                proxy_pass http://127.0.0.1:'${PORT}';\
        }' /etc/nginx/sites-enabled/default
    fi
    supervisorctl update
    supervisorctl start ${NAME} || true
    pkill -HUP nginx
    echo -e "\n\n\n\n\n
    Installation sucessful! Please point your browser to:
    \e[4mhttps://${HOSTNAME}/${NAME}\e[39m\e[0m
    
    You can continue the configuration from there.
    \e[96mMake sure you protect the app by setting up and username/password in the app's settings!\e[39m
    
    \e[91mIf you want to use another appbox app in the settings of ${NAME}, make sure you access it on port 80, and without https, for example:
    \e[4mhttp://rutorrent.${APPBOX_USER}.appboxes.co\e[39m\e[0m
    \e[95mIf you want to access Plex from one of these installed apps use port 32400 for example:
    \e[4mhttp://plex.${APPBOX_USER}.appboxes.co:32400\e[39m\e[0m
    
    That's because inside this container, we don't go through the appbox proxy! \n\n\n\n\n\n"
}

setup_radarr() {
    supervisorctl stop radarr || true
	wget https://packages.microsoft.com/config/ubuntu/18.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    dpkg -i packages-microsoft-prod.deb
	rm -f packages-microsoft-prod.deb
    apt update
    apt -y install dotnet-runtime-3.1 libmediainfo0v5 || true
    cd /opt
    curl -L -O $( curl -s https://api.github.com/repos/Radarr/Radarr/releases | grep linux-core-x64.tar.gz | grep browser_download_url | head -1 | cut -d \" -f 4 )
    tar -xvzf Radarr.*.linux-core-x64.tar.gz
    rm -f Radarr.*.linux-core-x64.tar.gz
    chown -R appbox:appbox /opt
    # Generate config
    /bin/su -s /bin/bash -c "/opt/Radarr/Radarr" appbox &
    until grep -q 'UrlBase' /home/appbox/.config/Radarr/config.xml; do
        sleep 1
    done
    kill -9 $(ps aux | grep 'Radarr' | grep -v 'bash' | awk '{print $2}')
    sed -i 's@<UrlBase></UrlBase>@<UrlBase>/radarr</UrlBase>@g' /home/appbox/.config/Radarr/config.xml
cat << EOF > /etc/supervisor/conf.d/radarr.conf
[program:radarr]
command=/bin/su -s /bin/bash -c "rm /home/appbox/.config/Radarr/radarr.pid; /opt/Radarr/Radarr" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/radarr.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/radarr.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'radarr' '7878'
}

setup_sonarr() {
    supervisorctl stop sonarr || true
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 2009837CBFFD68F45BC180471F4F90DE2A9B4BF8
    echo "deb https://apt.sonarr.tv/ubuntu bionic main" | tee /etc/apt/sources.list.d/sonarr.list
    apt update
    apt install -y debconf-utils
    echo "sonarr sonarr/owning_user string appbox" | debconf-set-selections
    echo "sonarr sonarr/owning_group string appbox" | debconf-set-selections
    apt -y install sonarr libmediainfo0v5 || true
    # Generate config
    /bin/su -s /bin/bash -c "/usr/bin/mono --debug /usr/lib/sonarr/bin/Sonarr.exe -nobrowser" appbox &
    until grep -q 'UrlBase' /home/appbox/.config/Sonarr/config.xml; do
        sleep 1
    done
    sleep 5
    kill -9 $(ps aux | grep 'mono' | grep 'Sonarr.exe' | grep -v 'bash' | awk '{print $2}')
    sed -i 's@<UrlBase></UrlBase>@<UrlBase>/sonarr</UrlBase>@g' /home/appbox/.config/Sonarr/config.xml
cat << EOF > /etc/supervisor/conf.d/sonarr.conf
[program:sonarr]
command=/bin/su -s /bin/bash -c "rm /home/appbox/.config/Sonarr/sonarr.pid; /usr/bin/mono --debug /usr/lib/sonarr/bin/Sonarr.exe -nobrowser" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/sonarr.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/sonarr.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'sonarr' '8989'
}

setup_lidarr() {
    supervisorctl stop lidarr || true
    apt update
    apt -y install libmediainfo0v5 libchromaprint-tools || true
    cd /opt
    curl -L -O $( curl -s https://api.github.com/repos/lidarr/Lidarr/releases | grep linux.tar.gz | grep browser_download_url | head -1 | cut -d \" -f 4 )
    tar -xvzf Lidarr.master.*.linux.tar.gz
    rm -f Lidarr.master.*.linux.tar.gz
    chown -R appbox:appbox /opt
    # Generate config
    /bin/su -s /bin/bash -c "/usr/bin/mono --debug /opt/Lidarr/Lidarr.exe -nobrowser" appbox &
    until grep -q 'UrlBase' /home/appbox/.config/Lidarr/config.xml; do
        sleep 1
    done
    kill -9 $(ps aux | grep 'mono' | grep 'Lidarr.exe' | grep -v 'bash' | awk '{print $2}')
    sed -i 's@<UrlBase></UrlBase>@<UrlBase>/lidarr</UrlBase>@g' /home/appbox/.config/Lidarr/config.xml
cat << EOF > /etc/supervisor/conf.d/lidarr.conf
[program:lidarr]
command=/bin/su -s /bin/bash -c "rm /home/appbox/.config/Lidarr/lidarr.pid; /usr/bin/mono --debug /opt/Lidarr/Lidarr.exe -nobrowser" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/lidarr.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/lidarr.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'lidarr' '8686'
}

setup_bazarr() {
    supervisorctl stop bazarr || true
    apt update
    apt -y install git-core python3-pip python3-distutils python3.7 || true
    cd /opt
    git clone --depth 1 https://github.com/morpheus65535/bazarr.git
    cd /opt/bazarr
    pip install -r requirements.txt
    chown -R appbox:appbox /opt
    /bin/su -s /bin/bash -c "python3.7 /opt/bazarr/bazarr.py" appbox &
    until grep -q 'base_url' /opt/bazarr/data/config/config.ini; do
        sleep 1
    done
    kill -9 $(ps aux | grep 'python3.7 -u /opt/bazarr/bazarr/main.py' | grep -v 'grep' | grep -v 'bash' | awk '{print $2}')
    sed -i '0,/base_url = /s//base_url = \/bazarr\//' /opt/bazarr/data/config/config.ini
cat << EOF > /etc/supervisor/conf.d/bazarr.conf
[program:bazarr]
command=/bin/su -s /bin/bash -c "python3.7 /opt/bazarr/bazarr.py" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/bazarr.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/bazarr.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'bazarr' '6767'
}

setup_flexget() {
    supervisorctl stop flexget || true
    apt install -y \
    python-pip \
    libcap2-bin \
    curl || true
    pip install --upgrade pip && \
    hash -r pip && \
    pip install --upgrade setuptools && \
    pip install flexget[webui]
    mkdir -p /home/appbox/.config/flexget
    chown -R appbox:appbox /home/appbox/.config/flexget
cat << EOF > /home/appbox/.config/flexget/config.yml
templates:
  Example-Template:
    accept_all: yes
    download: /APPBOX_DATA/storage
tasks:
  Task-1:
    rss: 'http://example'
    template: 'Example Template'
schedules:
  - tasks: 'Task-1'
    interval:
      minutes: 1
web_server:
  bind: 0.0.0.0
  port: 9797
  web_ui: yes
  base_url: /flexget
  run_v2: yes
EOF
    cat << EOF > /tmp/flexpasswd
#!/usr/bin/env bash
GOOD_PASSWORD=0
until [ "\${GOOD_PASSWORD}" == "1" ]; do
    echo 'Please enter a password for flexget'
    read FLEXGET_PASSWORD
    if ! flexget web passwd "\${FLEXGET_PASSWORD}" | grep -q 'is not strong enough'; then
        GOOD_PASSWORD=1
    else
        echo -e 'Your password is not strong enough, please enter a few more words.';
    fi
done
EOF
    chmod +x /tmp/flexpasswd
    /bin/su -s /bin/bash -c "/tmp/flexpasswd" appbox
    rm -f /tmp/flexpasswd
    cat << EOF > /etc/supervisor/conf.d/flexget.conf
[program:flexget]
command=/bin/su -s /bin/bash -c "flexget daemon start" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/flexget.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/flexget.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'flexget' '9797'
}

setup_filebot() {
    # https://www.oracle.com/webapps/redirect/signon?nexturl=https://download.oracle.com/otn/java/jdk/11.0.4+10/cf1bbcbf431a474eb9fc550051f4ee78/jdk-11.0.4_linux-x64_bin.tar.gz
    mkdir -p /var/cache/oracle-jdk11-installer-local
    wget -c --no-cookies --no-check-certificate -O /var/cache/oracle-jdk11-installer-local/jdk-11.0.9_linux-x64_bin.tar.gz --header "Cookie: oraclelicense=accept-securebackup-cookie" https://download.oracle.com/otn-pub/java/jdk/11.0.9%2B7/eec35ebefb3f4133bd045b891f05db94/jdk-11.0.9_linux-x64_bin.tar.gz
    add-apt-repository -y ppa:linuxuprising/java
    apt update
    echo debconf shared/accepted-oracle-license-v1-2 select true | debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-2 seen true | debconf-set-selections
    apt-get install -y oracle-java11-installer-local libchromaprint-tools || true
    sed -i 's/tar xzf $FILENAME/tar xzf $FILENAME --no-same-owner/g' /var/lib/dpkg/info/oracle-java11-installer-local.postinst
    dpkg --configure -a
    mkdir /opt/filebot && cd /opt/filebot
    sh -xu <<< "$(curl -fsSL https://raw.githubusercontent.com/filebot/plugins/master/installer/tar.sh)"
        cat << EOF > /home/appbox/Desktop/Filebot.desktop
#!/usr/bin/env xdg-open
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Exec=/usr/local/bin/filebot
Name=Filebot
Comment=Filebot
EOF
    chown appbox:appbox /home/appbox/Desktop/Filebot.desktop
    chmod +x /home/appbox/Desktop/Filebot.desktop
    echo -e "\n\n\n\n\n
    Installation sucessful! Please launch filebot using the icon on your desktop."
}

setup_couchpotato() {
    supervisorctl stop couchpotato || true
    apt-get install python git -y || true
    mkdir /opt/couchpotato && cd /opt/couchpotato
    git clone --depth 1 https://github.com/RuudBurger/CouchPotatoServer.git
    cat << EOF > /etc/default/couchpotato
CP_USER=appbox
CP_HOME=/opt/couchpotato/CouchPotatoServer
CP_DATA=/home/appbox/couchpotato
EOF
    chown appbox:appbox /opt/
    cp CouchPotatoServer/init/ubuntu /etc/init.d/couchpotato
    chmod +x /etc/init.d/couchpotato
    sed -i 's/--daemon//g' /etc/init.d/couchpotato
    sed -i 's/--quiet//g' /etc/init.d/couchpotato
    cat << EOF > /etc/supervisor/conf.d/couchpotato.conf
[program:couchpotato]
command=/etc/init.d/couchpotato start
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/couchpotato.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/couchpotato.log
stderr_logfile_maxbytes=0
EOF
    mkdir -p /home/appbox/couchpotato/
    cat << EOF > /home/appbox/couchpotato/settings.conf
[core]
url_base = /couchpotato
show_wizard = 1
launch_browser = False
EOF
    chown -R appbox:appbox /home/appbox/couchpotato
    configure_nginx 'couchpotato' '5050'
}

setup_sickchill() {
    supervisorctl stop sickchill || true
    apt install -y git unrar-free git openssl libssl-dev python2.7 mediainfo || true
    git clone --depth 1 https://github.com/SickChill/SickChill.git /home/appbox/sickchill
    cp /home/appbox/sickchill/contrib/runscripts/init.ubuntu /etc/init.d/sickchill
    chmod +x /etc/init.d/sickchill
    sed -i 's/--daemon//g' /etc/init.d/sickchill
    cat << EOF > /etc/default/sickchill
SR_HOME=/home/appbox/sickchill/
SR_DATA=/home/appbox/sickchill/
SR_USER=appbox
EOF
    cat << EOF >/home/appbox/sickchill/config.ini
[General]
  web_host = 0.0.0.0
  handle_reverse_proxy = 1
  launch_browser = 0
  web_root = "/sickchill"
EOF
    cat << EOF > /etc/supervisor/conf.d/sickchill.conf
[program:sickchill]
command=/etc/init.d/sickchill start
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/sickchill.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/sickchill.log
stderr_logfile_maxbytes=0
EOF
    chown -R appbox:appbox /home/appbox/sickchill
    configure_nginx 'sickchill' '8081'
}

setup_medusa() {
    supervisorctl stop medusa || true
    apt install -y git unrar-free git openssl libssl-dev python3-pip python3-distutils python3.7 mediainfo || true
    git clone --depth 1 https://github.com/pymedusa/Medusa.git /home/appbox/medusa
    cp /home/appbox/medusa/runscripts/init.ubuntu /etc/init.d/medusa
    chmod +x /etc/init.d/medusa
    sed -i 's/--daemon//g' /etc/init.d/medusa
    cat << EOF > /etc/default/medusa
APP_HOME=/home/appbox/medusa/
APP_DATA=/home/appbox/medusa/
APP_USER=appbox
EOF
    cat << EOF >/home/appbox/medusa/config.ini
[General]
  web_host = 0.0.0.0
  handle_reverse_proxy = 1
  launch_browser = 0
  web_root = "/medusa"
  web_port = 8082
EOF
    cat << EOF > /etc/supervisor/conf.d/medusa.conf
[program:medusa]
command=/etc/init.d/medusa start
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/medusa.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/medusa.log
stderr_logfile_maxbytes=0
EOF
    chown -R appbox:appbox /home/appbox/medusa
    configure_nginx 'medusa' '8082'
}

setup_lazylibrarian() {
    supervisorctl stop lazylibrarian || true
    apt install -y git unrar-free git openssl libssl-dev python3-pip python3-distutils python3.7 mediainfo || true
    git clone --depth 1 https://gitlab.com/LazyLibrarian/LazyLibrarian.git /home/appbox/lazylibrarian
    cp /home/appbox/lazylibrarian/init/lazylibrarian.initd /etc/init.d/lazylibrarian
    chmod +x /etc/init.d/lazylibrarian
    sed -i 's/--daemon//g' /etc/init.d/lazylibrarian
    cat << EOF > /etc/default/lazylibrarian
CONFIG=/home/appbox/lazylibrarian/config.ini
APP_PATH=/home/appbox/lazylibrarian/
DATADIR=/home/appbox/lazylibrarian/
RUN_AS=appbox
EOF
    cat << EOF >/home/appbox/lazylibrarian/config.ini
[General]
  http_host = 0.0.0.0
  launch_browser = 0
  http_root = "/lazylibrarian"
EOF
    cat << EOF > /etc/supervisor/conf.d/lazylibrarian.conf
[program:lazylibrarian]
command=/etc/init.d/lazylibrarian start
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/lazylibrarian.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/lazylibrarian.log
stderr_logfile_maxbytes=0
EOF
    chown -R appbox:appbox /home/appbox/lazylibrarian
    configure_nginx 'lazylibrarian' '5299'
}

setup_nzbget() {
    supervisorctl stop nzbget || true
    mkdir /tmp/nzbget
    wget -O /tmp/nzbget/nzbget.run https://nzbget.net/download/nzbget-latest-bin-linux.run
    chown appbox:appbox /tmp/nzbget/nzbget.run
    mkdir -p /opt/nzbget
    chown appbox:appbox /opt/nzbget
    /bin/su -s /bin/bash -c "sh /tmp/nzbget/nzbget.run --destdir /opt/nzbget" appbox
    rm -rf /tmp/nzbget
    cat << EOF > /etc/supervisor/conf.d/nzbget.conf
[program:nzbget]
command=/bin/su -s /bin/bash -c "/opt/nzbget/nzbget -s" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/nzbget.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/nzbget.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'nzbget' '6789'
}

setup_sabnzbdplus() {
    supervisorctl stop sabnzbd || true
    add-apt-repository -y ppa:jcfp/ppa
    apt-get install -y sabnzbdplus
    sed -i 's/--daemon//g' /etc/init.d/sabnzbdplus
    cat << EOF > /etc/supervisor/conf.d/sabnzbdplus.conf
[program:sabnzbdplus]
command=/etc/init.d/sabnzbdplus start
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/sabnzbdplus.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/sabnzbdplus.log
stderr_logfile_maxbytes=0
EOF
    cat << EOF > /etc/default/sabnzbdplus
USER=appbox
HOST=0.0.0.0
PORT=9090
EXTRAOPTS=-b0
EOF
    configure_nginx 'sabnzbd' '9090'
}

setup_ombi() {
    supervisorctl stop ombi || true
    update-locale "LANG=en_US.UTF-8"
    locale-gen --purge "en_US.UTF-8"
    dpkg-reconfigure --frontend noninteractive locales
    echo "deb [arch=amd64,armhf] http://repo.ombi.turd.me/stable/ jessie main" | sudo tee "/etc/apt/sources.list.d/ombi.list"
    wget -qO - https://repo.ombi.turd.me/pubkey.txt | sudo apt-key add -
    apt update && apt -y install ombi || true
    chown -R appbox:appbox /opt
    mkdir -p /home/appbox/ombi
    chown -R appbox:appbox /home/appbox/ombi
    cat << EOF > /etc/supervisor/conf.d/ombi.conf
[program:ombi]
command=/bin/su -s /bin/bash -c "cd /opt/Ombi; /opt/Ombi/Ombi --baseurl /ombi --host http://*:5000 --storage /home/appbox/ombi/" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/ombi.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/ombi.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'ombi' '5000'
}

setup_jackett() {
    supervisorctl stop jackett || true
    apt install -y libicu60 openssl1.0
    cd /opt
    curl -L -O $( curl -s https://api.github.com/repos/Jackett/Jackett/releases/latest | grep LinuxAMDx64 | grep browser_download_url | head -1 | cut -d \" -f 4 )
    tar -xvzf Jackett.Binaries.LinuxAMDx64.tar.gz
    rm -f Jackett.Binaries.LinuxAMDx64.tar.gz
    chown -R appbox:appbox /opt
    mkdir -p /home/appbox/.config/Jackett
    cat << EOF > /home/appbox/.config/Jackett/ServerConfig.json
{
  "Port": 9117,
  "AllowExternal": true,
  "BasePathOverride": "/jackett",
}
EOF
    chown -R appbox:appbox /home/appbox/.config/Jackett
    cat << EOF > /etc/supervisor/conf.d/jackett.conf
[program:jackett]
command=/bin/su -s /bin/bash -c "/opt/Jackett/jackett" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/jackett.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/jackett.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'jackett' '9117'
}

setup_synclounge() {
    supervisorctl stop synclounge_server || true
    supervisorctl stop synclounge || true
    apt install -y git npm
    git clone --depth 1 https://github.com/samcm/SyncLounge /opt/synclounge
    cd /opt/synclounge
    npm install
    sed -i 's@"webroot": ""@"webroot": "/synclounge"@g' /opt/synclounge/settings.json
    sed -i 's@"accessUrl": ""@"accessUrl": "https://'"${HOSTNAME}"'/synclounge"@g' /opt/synclounge/settings.json
    sed -i 's@"serverroot": ""@"serverroot": "/synclounge_server"@g' /opt/synclounge/settings.json
    sed -i 's@"autoJoin": false@"autoJoin": true@g' /opt/synclounge/settings.json
    sed -i 's@"autoJoinServer": ""@"autoJoinServer": "http://'"${HOSTNAME}"'/synclounge_server"@g' /opt/synclounge/settings.json
    sed -i '/webroot/a \ \ \ \ "customServer": "http://'"${HOSTNAME}"'/synclounge_server",' /opt/synclounge/settings.json
    npm run build
    chown -R appbox:appbox /opt/synclounge
    cat << EOF > /etc/supervisor/conf.d/synclounge_webapp.conf
[program:synclounge_webapp]
command=/bin/su -s /bin/bash -c "cd /opt/synclounge && node webapp.js" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/synclounge_webapp.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/synclounge_webapp.log
stderr_logfile_maxbytes=0
EOF
    cat << EOF > /etc/supervisor/conf.d/synclounge_server.conf
[program:synclounge_server]
command=/bin/su -s /bin/bash -c "cd /opt/synclounge && npm run server" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/synclounge_server.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/synclounge_server.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'synclounge_server' '8088'
    configure_nginx 'synclounge' '8088'
}

setup_vnc_ssl() {
    sed -i '/location \/ {/,+5d' /etc/nginx/sites-enabled/default
    configure_nginx '' '6901'
}

setup_nzbhydra2() {
    supervisorctl stop nzbhydra2 || true
    mkdir -p /var/cache/oracle-jdk11-installer-local
    wget -c --no-cookies --no-check-certificate -O /var/cache/oracle-jdk11-installer-local/jdk-11.0.9_linux-x64_bin.tar.gz --header "Cookie: oraclelicense=accept-securebackup-cookie" https://download.oracle.com/otn-pub/java/jdk/11.0.9%2B7/eec35ebefb3f4133bd045b891f05db94/jdk-11.0.9_linux-x64_bin.tar.gz
    add-apt-repository -y ppa:linuxuprising/java
    apt update
    echo debconf shared/accepted-oracle-license-v1-2 select true | debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-2 seen true | debconf-set-selections
    apt-get install -y oracle-java11-installer-local libchromaprint-tools || true
    sed -i 's/tar xzf $FILENAME/tar xzf $FILENAME --no-same-owner/g' /var/lib/dpkg/info/oracle-java11-installer-local.postinst
    dpkg --configure -a
    mkdir -p /opt/nzbhydra2
    cd /opt/nzbhydra2
    curl -L -O $( curl -s https://api.github.com/repos/theotherp/nzbhydra2/releases | grep linux.zip | grep browser_download_url | head -1 | cut -d \" -f 4 )
    unzip -o nzbhydra2*.zip
    rm -f nzbhydra2*.zip
    chmod +x /opt/nzbhydra2/nzbhydra2
    chown -R appbox:appbox /opt
    # Generate config
    /bin/su -s /bin/bash -c "/opt/nzbhydra2/nzbhydra2" appbox &
    until grep -q 'urlBase' /opt/nzbhydra2/data/nzbhydra.yml; do
        sleep 1
    done
    kill -9 $(ps aux | grep 'nzbhydra2' | grep -v 'grep' | grep -v 'bash' | awk '{print $2}')
    sed -i 's@urlBase: "/"@urlBase: "/nzbhydra2"@g' /opt/nzbhydra2/data/nzbhydra.yml
    cat << EOF > /etc/supervisor/conf.d/nzbhydra2.conf
[program:nzbhydra2]
command=/bin/su -s /bin/bash -c "/opt/nzbhydra2/nzbhydra2" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/nzbhydra2.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/nzbhydra2.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'nzbhydra2' '5076'
}

setup_ngpost() {
    mkdir /opt/ngpost && cd /opt/ngpost
    curl -L -O $( curl -s https://api.github.com/repos/mbruel/ngPost/releases | grep 'debian8.AppImage' | grep browser_download_url | head -1 | cut -d \" -f 4 )
    chmod +x /opt/ngpost/*.AppImage
    FILENAME=$(ls -la /opt/ngpost | grep 'AppImage' | awk '{print $9}')
        cat << EOF > /home/appbox/Desktop/ngPost.desktop
#!/usr/bin/env xdg-open
[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Exec=/opt/ngpost/${FILENAME}
Name=ngPost
Comment=ngPost
EOF
    chown appbox:appbox /home/appbox/Desktop/ngPost.desktop
    chmod +x /home/appbox/Desktop/ngPost.desktop
    echo -e "\n\n\n\n\n
    Installation sucessful! Please launch ngpost using the icon on your desktop."
}

setup_pyload() {
    mkdir -p /opt/pyload && cd /opt/pyload
    rm -f /config/pyload.pid
    supervisorctl stop pyload || true
    apt install -y git python python-crypto python-pycurl python-pil tesseract-ocr libtesseract-dev python-qt4 python-jinja2 libmozjs-52-0 libmozjs-52-dev
    ln -sf /usr/bin/js52 /usr/bin/js
    git clone --depth 1 -b stable https://github.com/pyload/pyload.git /opt/pyload
    echo "/home/appbox/.config/pyload" > /opt/pyload/module/config/configdir
    if  [ ! -f "/home/appbox/.config/pyload/files.db" ] || [ ! -f "/home/appbox/.config/pyload/files.version" ] || [ ! -f "/home/appbox/.config/pyload/plugin.conf" ] || [ ! -f "/home/appbox/.config/pyload/pyload.conf" ]
        then
        mkdir -p /home/appbox/.config/pyload
        chmod 777 /home/appbox/.config/pyload
        wget -O /home/appbox/.config/pyload/files.db https://raw.githubusercontent.com/Cobraeti/docker-pyload/master/config/files.db
        wget -O /home/appbox/.config/pyload/files.version https://raw.githubusercontent.com/Cobraeti/docker-pyload/master/config/files.version
        wget -O /home/appbox/.config/pyload/plugin.conf https://raw.githubusercontent.com/Cobraeti/docker-pyload/master/config/plugin.conf
        wget -O /home/appbox/.config/pyload/pyload.conf https://raw.githubusercontent.com/Cobraeti/docker-pyload/master/config/pyload.conf

        sed -i 's#"Path Prefix" =#"Path Prefix" = /pyload#g' /home/appbox/.config/pyload/pyload.conf
        sed -i 's#/downloads#/home/appbox/Downloads/#g' /home/appbox/.config/pyload/pyload.conf
    fi
    chown -R appbox:appbox /home/appbox/.config/pyload
    chown -R appbox:appbox /opt/pyload

    cat << EOF > /etc/supervisor/conf.d/pyload.conf
[program:pyload]
command=/bin/su -s /bin/bash -c "/usr/bin/python /opt/pyload/pyLoadCore.py" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/pyload.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/pyload.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'pyload' '8000'
    echo -e "\n\n\n\n\n
    The default user for pyload is: admin
    The default password for pyload is: pyload"
}

setup_deemixrr() {
    supervisorctl stop deemixrr || true
    wget https://packages.microsoft.com/config/ubuntu/18.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    add-apt-repository "$(wget -qO- https://packages.microsoft.com/config/ubuntu/18.04/mssql-server-2019.list)"
    apt-get update; \
    apt-get install -y apt-transport-https && \
    apt-get update && \
    apt-get install -y dotnet-sdk-5.0 python3 python3-pip aspnetcore-runtime-3.1 mssql-server
    mkdir -p /var/opt/mssql/
    git clone --depth 1 -b master https://github.com/TheUltimateC0der/Deemixrr.git /opt/deemixrr
    cd /opt/deemixrr
    dotnet restore "Deemixrr/Deemixrr.csproj"
    dotnet build "Deemixrr/Deemixrr.csproj" -c Release -o /opt/deemixrr/app/build
    dotnet publish "Deemixrr/Deemixrr.csproj" -c Release -o /opt/deemixrr/app/publish
    python3 -m pip install --quiet deemix
    mkdir /home/appbox/.config/deemix
    chown -R appbox:appbox /opt/deemixrr /home/appbox/.config/deemix /var/opt/mssql
    cat << EOF > /etc/supervisor/conf.d/deemixrr.conf
[program:deemixrr]
command=/bin/su -s /bin/bash -c "export Kestrel__EndPoints__Http__Url=http://0.0.0.0:5555/deemixrr;export ConnectionStrings__DefaultConnection=\"server=localhost;uid=sa;pwd=TAOIDh89333iundafkjasd;database=Deemixrr;pooling=true\";export Hangfire__DashboardPath=/autoloaderjobs;export Hangfire__Password=TAOIDh89333iundafkjasd;export Hangfire__Username=Deemixrr;export Hangfire__Workers=2;export JobConfiguration__GetUpdatesRecurringJob='0 2 * * *';export JobConfiguration__SizeCalculatorRecurringJob='0 12 * * *';export DelayConfiguration__ImportArtistsBackgroundJob_ExecuteDelay=1000;export DelayConfiguration__CheckArtistForUpdatesBackgroundJob_GetTrackCountDelay=1000;export DelayConfiguration__CheckArtistForUpdatesBackgroundJob_ExecuteDelay=1000;export DelayConfiguration__CheckPlaylistForUpdatesBackgroundJob_ExecuteDelay=1000;export DelayConfiguration__CreateArtistBackgroundJob_FromPlaylistDelay=1000;export DelayConfiguration__CreateArtistBackgroundJob_FromUserDelay=1000;export DelayConfiguration__CreateArtistBackgroundJob_FromCsvDelay=1000;export DelayConfiguration__CreatePlaylistBackgroundJob_FromCsvDelay=1000;export PGID=1000;export PUID=1000;dotnet /opt/deemixrr/app/publish/Deemixrr.dll" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/deemixrr.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/deemixrr.log
stderr_logfile_maxbytes=0
EOF
    cat << EOF > /etc/supervisor/conf.d/mssql.conf
[program:mssql]
command=/bin/su -s /bin/bash -c "export SA_PASSWORD=TAOIDh89333iundafkjasd; export ACCEPT_EULA=Y;/opt/mssql/bin/sqlservr" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/mssql.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/mssql.log
stderr_logfile_maxbytes=0
EOF
    configure_nginx 'deemixrr' '5555'
}

setup_organizr() {
    apt install -y php-mysql php-sqlite3 sqlite3 php-xml php-zip php-curl php-fpm git
    mkdir -p /run/php
    mkdir -p /opt/organizr
    git clone --depth 1 -b v2-master https://github.com/causefx/Organizr /opt/organizr/organizr

    echo "Configuring PHP to use sockets"

    if [ ! -f /etc/php/7.2/fpm/pool.d/www.conf.original ]; then
        cp /etc/php/7.2/fpm/pool.d/www.conf /etc/php/7.2/fpm/pool.d/www.conf.original
    fi

    # TODO: Check if settings catch
    # enable PHP-FPM
    sed -i "s#www-data#appbox#g" /etc/php/7.2/fpm/pool.d/www.conf
    sed -i "s#;listen.mode = 0660#listen.mode = 0777#g" /etc/php/7.2/fpm/pool.d/www.conf
    # set our recommended defaults
    sed -i "s#pm = dynamic#pm = ondemand#g" /etc/php/7.2/fpm/pool.d/www.conf
    sed -i "s#pm.max_children = 5#pm.max_children = 4000#g" /etc/php/7.2/fpm/pool.d/www.conf
    sed -i "s#pm.start_servers = 2#;pm.start_servers = 2#g" /etc/php/7.2/fpm/pool.d/www.conf
    sed -i "s#;pm.process_idle_timeout = 10s;#pm.process_idle_timeout = 10s;#g" /etc/php/7.2/fpm/pool.d/www.conf
    sed -i "s#;pm.max_requests = 500#pm.max_requests = 0#g" /etc/php/7.2/fpm/pool.d/www.conf
    chown -R appbox:appbox /var/lib/php

        cat << EOF > /etc/nginx/sites-enabled/organizr
# V0.0.4
server {
  listen 8009;
  root /opt/organizr;
  index index.html index.htm index.php;

  server_name _;
  client_max_body_size 0;

  # Real Docker IP
  # Make sure to update the IP range with your Docker IP subnet
  real_ip_header X-Forwarded-For;
  #set_real_ip_from 172.17.0.0/16;
  real_ip_recursive on;

  # Deny access to Org .git directory
  location ~ /\.git {
    deny all;
  }

  location /organizr {
    try_files \$uri \$uri/ /organizr/index.html /organizr/index.php?\$args =404;
  }

  location /organizr/api/v2 {
    try_files \$uri /organizr/api/v2/index.php\$is_args\$args;
  }

  location ~ \.php$ {
    fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
    fastcgi_pass unix:/run/php/php7.2-fpm.sock;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_buffers 32 32k;
    fastcgi_buffer_size 32k;
  }
}
EOF

    chown -R appbox:appbox /opt/organizr /run/php

    cat << EOF > /etc/supervisor/conf.d/php-fpm.conf
[program:php-fpm]
command=/usr/sbin/php-fpm7.2 -F
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/php-fpm.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/php-fpm.log
stderr_logfile_maxbytes=0
EOF

    configure_nginx 'organizr/' '8009'
}

setup_komga() {
    mkdir -p /var/cache/oracle-jdk11-installer-local
    wget -c --no-cookies --no-check-certificate -O /var/cache/oracle-jdk11-installer-local/jdk-11.0.9_linux-x64_bin.tar.gz --header "Cookie: oraclelicense=accept-securebackup-cookie" https://download.oracle.com/otn-pub/java/jdk/11.0.9%2B7/eec35ebefb3f4133bd045b891f05db94/jdk-11.0.9_linux-x64_bin.tar.gz
    add-apt-repository -y ppa:linuxuprising/java
    apt update
    echo debconf shared/accepted-oracle-license-v1-2 select true | debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-2 seen true | debconf-set-selections
    apt-get install -y oracle-java11-installer-local || true
    sed -i 's/tar xzf $FILENAME/tar xzf $FILENAME --no-same-owner/g' /var/lib/dpkg/info/oracle-java11-installer-local.postinst
    dpkg --configure -a
    mkdir /opt/komga
    cd /opt/komga
    curl -L -O $( curl -s https://api.github.com/repos/gotson/komga/releases | grep jar | grep browser_download_url | head -1 | cut -d \" -f 4 )
    chown -R appbox:appbox /opt/komga
    cat << EOF > /etc/supervisor/conf.d/komga.conf
[program:komga]
command=/bin/su -s /bin/bash -c "export FILENAME=\$(ls -la /opt/komga | grep jar | awk '{print \$9}'); /usr/bin/java -jar /opt/komga/\${FILENAME} --server.servlet.context-path="/komga" --server.port=8443" appbox
autostart=true
autorestart=true
priority=5
stdout_events_enabled=true
stderr_events_enabled=true
stdout_logfile=/tmp/komga.log
stdout_logfile_maxbytes=0
stderr_logfile=/tmp/komga.log
stderr_logfile_maxbytes=0
EOF

    configure_nginx 'komga' '8443'
}

install_prompt() {
    echo "Welcome to the install script, please select one of the following options to install:
    
    1) radarr
    2) sonarr
    3) flexget
    4) filebot
    5) couchpotato
    6) sickchill
    7) nzbget
    8) sabnzbdplus
    9) ombi
    10) jackett
    11) synclounge
    12) lidarr
    13) bazarr
    14) VNC web ui over SSL
    15) medusa
    16) lazylibrarian
    17) nzbhydra2
    18) ngpost
    19) pyload
    20) organizr
    21) komga
    "
    echo -n "Enter the option and press [ENTER]: "
    read OPTION
    echo

    case "$OPTION" in
        1|radarr)
            echo "Setting up radarr.."
            setup_radarr
            ;;
        2|sonarr)
            echo "Setting up sonarr.."
            setup_sonarr
            ;;
        3|flexget)
            echo "Setting up flexget.."
            setup_flexget
            ;;
        4|filebot)
            echo "Setting up filebot.."
            setup_filebot
            ;;
        5|couchpotato)
            echo "Setting up couchpotato.."
            setup_couchpotato
            ;;
        6|sickchill)
            echo "Setting up sickchill.."
            setup_sickchill
            ;;
        7|nzbget)
            echo "Setting up nzbget.."
            setup_nzbget
            ;;
        8|sabnzbdplus)
            echo "Setting up sabnzbdplus.."
            setup_sabnzbdplus
            ;;
        9|ombi)
            echo "Setting up ombi.."
            setup_ombi
            ;;
        10|jackett)
            echo "Setting up jackett.."
            setup_jackett
            ;;
        11|synclounge)
            echo "Setting up synclounge.."
            setup_synclounge
            ;;
        12|lidarr)
            echo "Setting up lidarr.."
            setup_lidarr
            ;;
        13|bazarr)
            echo "Setting up bazarr.."
            setup_bazarr
            ;;
        14|"VNC web ui over SSL")
            echo "Setting up VNC web ui over SSL.."
            setup_vnc_ssl
            ;;
        15|medusa)
            echo "Setting up medusa.."
            setup_medusa
            ;;
        16|lazylibrarian)
            echo "Setting up lazylibrarian.."
            setup_lazylibrarian
            ;;
        17|nzbhydra2)
            echo "Setting up nzbhydra2.."
            setup_nzbhydra2
            ;;
        18|ngpost)
            echo "Setting up ngpost.."
            setup_ngpost
            ;;
        19|pyload)
            echo "Setting up pyload.."
            setup_pyload
            ;;
        20|organizr)
            echo "Setting up organizr.."
            setup_organizr
            ;;
        21|komga)
            echo "Setting up komga.."
            setup_komga
            ;;
        *) 
            echo "Sorry, that option doesn't exist, please try again!"
            return 1
        ;;
        esac
}

run_as_root
install_nginx
echo -e "\nEnsuring opt exists..."
mkdir -p /opt
echo -e "\nUpdating apt packages..."
apt update
until install_prompt ; do : ; done
