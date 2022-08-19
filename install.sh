#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

check_keystroke() {
  while [ true ] ; do
    read -t 3 -n 1
    if [ $? = 0 ] ; then
      exit ;
    else
      echo "waiting for the keypress"
    fi
  done
}

# set username used for rustdesk
USERNAME=rustdesk
USERHOME=/opt/$USERHOME
SCRIPT_URL="https://raw.githubusercontent.com/osiktech/rustdeskinstall/refactor_install.sh"
ADMINTOKEN=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)

# identify OS
if [ -f /etc/os-release ]; then
  # freedesktop.org and systemd
  . /etc/os-release
  OS=$NAME
  VER=$VERSION_ID

  UPSTREAM_ID=${ID_LIKE,,}

  # Fallback to ID_LIKE if ID was not 'ubuntu' or 'debian'
  if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
    UPSTREAM_ID="$(echo ${ID_LIKE,,} | sed s/\"//g | cut -d' ' -f1)"
  fi

elif type lsb_release >/dev/null 2>&1; then
  # linuxbase.org
  OS=$(lsb_release -si)
  VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
  # For some versions of Debian/Ubuntu without lsb_release command
  . /etc/lsb-release
  OS=$DISTRIB_ID
  VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
  # Older Debian/Ubuntu/etc.
  OS=Debian
  VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
  # Older SuSE/etc.
  OS=SuSE
  VER=$(cat /etc/SuSe-release)
elif [ -f /etc/redhat-release ]; then
  # Older Red Hat, CentOS, etc.
  OS=RedHat
  VER=$(cat /etc/redhat-release)
else
  # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
  OS=$(uname -s)
  VER=$(uname -r)
fi

# output ebugging info if $DEBUG set
if [ "$DEBUG" = "true" ]; then
  echo "OS: $OS"
  echo "VER: $VER"
  echo "UPSTREAM_ID: $UPSTREAM_ID"
  exit 0
fi

# Setup prereqs for server
# common named prereqs
PREREQ="curl unzip tar"

echo "Installing prerequisites"
if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ]  || [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
  apt-get update
  apt-get install -y ${PREREQ}
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ]   || [ "${UPSTREAM_ID}" = "rhel" ] ; then
  # opensuse 15.4 fails to run the relay service and hangs waiting for it
  # needs more work before it can be enabled
  # || [ "${UPSTREAM_ID}" = "suse" ]
  yum update -y
  yum install -y ${PREREQ}
else
  echo "Unsupported OS"
  # here you could ask the user for permission to try and install anyway
  # if they say yes, then do the install
  # if they say no, exit the script
  exit 1
fi

# Create user if not existing
getent passwd | grep $USERNAME
if [ $? -eq 0 ]; then
  # ToDo implement proper check to use home dir etc.
  echo "User $USERNAME already exists!"
  exit 1;
else
  useradd -c "RustDesk server" -d $USERHOME -s /bin/false -m $USERNAME
fi

# Choice for DNS or IP
PS3='Choose your preferred option, IP or DNS/Domain:'
WAN=("IP" "DNS/Domain")
select WANOPT in "${WAN[@]}"; do
  case $WANOPT in
    "IP")
      WANIP=$(curl -4 https://ifconfig.co)
    break
    ;;

    "DNS/Domain")
      echo -ne "Enter your preferred domain/dns address ${NC}: "
      read WANIP
      #check WANIP is valid domain
      if ! [[ $WANIP =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
        echo -e "${RED}Invalid domain/dns address${NC}"
        exit 1
      fi
    break
    ;;
    *) echo "invalid option $REPLY";;
  esac
done

# Make Folder $USERHOME/
if [ ! -d "$USERHOME" ]; then
  echo "Creating $USERHOME"
  mkdir -p $USERHOME/
fi
chown "${USERNAME}" -R $USERHOME
cd $USERHOME/ || exit 1

#Download latest version of Rustdesk
RDLATEST=$(curl https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest -s | grep "tag_name"| awk '{print substr($2, 2, length($2)-3) }')
curl -L -o rustdesk-server-linux-x64.zip https://github.com/rustdesk/rustdesk-server/releases/download/${RDLATEST}/rustdesk-server-linux-x64.zip
unzip rustdesk-server-linux-x64.zip

# Make Folder /var/log/rustdesk/
if [ ! -d "/var/log/rustdesk" ]; then
  echo "Creating /var/log/rustdesk"
  mkdir -p /var/log/rustdesk/
fi
chown "${USERNAME}" -R /var/log/rustdesk/

# Setup Systemd to launch hbbs
rustdesksignal=$(curl $SCRIPT_URL/deps/etc/systemd/system/rustdesksignal.service)
echo "${rustdesksignal}" | tee /etc/systemd/system/rustdesksignal.service > /dev/null
sed -i "s|RUSTDESKUSER|${USERNAME}|g" /etc/systemd/system/rustdesksignal.service

# Setup Systemd to launch hbbr
rustdeskrelay=$(curl $SCRIPT_URL/deps/etc/systemd/system/rustdeskrelay.service)
echo "${rustdeskrelay}" | tee /etc/systemd/system/rustdeskrelay.service > /dev/null
sed -i "s|RUSTDESKUSER|${USERNAME}|g" /etc/systemd/system/rustdeskrelay.service

systemctl daemon-reload
systemctl enable rustdesksignal.service rustdeskrelay.service
systemctl start rustdesksignal.service rustdeskrelay.service

while ! [[ $CHECK_RUSTDESK_READY ]]; do
  CHECK_RUSTDESK_READY=$(systemctl status rustdeskrelay.service | grep "Active: active (running)")
  echo -ne "Rustdesk Relay not ready yet...${NC}\n"
  sleep 3
done

PUBNAME=$(find $USERHOME -name "*.pub")
KEY=$(cat "${PUBNAME}")

rm rustdesk-server-linux-x64.zip

# Choice for DNS or IP
PS3='Please choose if you want to download configs and install HTTP server:'
EXTRA=("Yes" "No")
select EXTRAOPT in "${EXTRA[@]}"; do
  case $EXTRAOPT in
    "Yes")

      # Create windows install script
      curl -L -o WindowsAgentAIOInstall.ps1 $SCRIPT_URL/WindowsAgentAIOInstall.ps1
      sed -i "s|wanipreg|${WANIP}|g" WindowsAgentAIOInstall.ps1
      sed -i "s|keyreg|${KEY}|g" WindowsAgentAIOInstall.ps1

      # Create linux install script
      curl -L -o linuxclientinstall.sh $SCRIPT_URL/linuxclientinstall.sh
      sed -i "s|wanipreg|${WANIP}|g" linuxclientinstall.sh
      sed -i "s|keyreg|${KEY}|g" linuxclientinstall.sh

      # Download and install gohttpserver
      # Make Folder /opt/gohttp/
      if [ ! -d "/opt/gohttp" ]; then
        echo "Creating /opt/gohttp"
        mkdir -p /opt/gohttp/public
      fi
      chown "${USERNAME}" -R /opt/gohttp
      cd /opt/gohttp
      GOHTTPLATEST=$(curl https://api.github.com/repos/codeskyblue/gohttpserver/releases/latest -s | grep "tag_name"| awk '{print substr($2, 2, length($2)-3) }')
      curl -L -o gohttpserver_${GOHTTPLATEST}_linux_amd64.tar.gz https://github.com/codeskyblue/gohttpserver/releases/download/${GOHTTPLATEST}/gohttpserver_${GOHTTPLATEST}_linux_amd64.tar.gz
      tar -xf  gohttpserver_${GOHTTPLATEST}_linux_amd64.tar.gz -C /opt/gohttp/

      # Copy Rustdesk install scripts to folder
      mv $USERHOME/WindowsAgentAIOInstall.ps1 /opt/gohttp/public/
      mv $USERHOME/linuxclientinstall.sh /opt/gohttp/public/

      # Make gohttp log folders
      if [ ! -d "/var/log/gohttp" ]; then
        echo "Creating /var/log/gohttp"
        mkdir -p /var/log/gohttp/
      fi
      chown "${USERNAME}" -R /var/log/gohttp/

      rm gohttpserver_"${GOHTTPLATEST}"_linux_amd64.tar.gz

      # Setup Systemd to launch Go HTTP Server
      gohttpserver="$(curl $SCRIPT_URL/deps/etc/systemd/system/gohttpserver.service)"
      echo "${gohttpserver}" | tee /etc/systemd/system/gohttpserver.service > /dev/null
      sed -i "s|RUSTDESKUSER|${USERNAME}|g" /etc/systemd/system/gohttpserver.service
      sed -i "s|ADMINTOKEN|${ADMINTOKEN}|g" /etc/systemd/system/gohttpserver.service

      systemctl daemon-reload
      systemctl enable gohttpserver.service
      systemctl start gohttpserver.service


      echo -e "Your IP/DNS Address is ${WANIP}"
      echo -e "Your public key is ${KEY}"
      echo -e "Install Rustdesk on your machines and change your public key and IP/DNS name to the above"
      echo -e "You can access your install scripts for clients by going to http://${WANIP}:8000"
      echo -e "Username is admin and password is ${ADMINTOKEN}"

      echo "Press any key to finish install"
      check_keystroke

    break
    ;;

    "No")
      echo -e "Your IP/DNS Address is ${WANIP}"
      echo -e "Your public key is ${KEY}"
      echo -e "Install Rustdesk on your machines and change your public key and IP/DNS name to the above"

      echo "Press any key to finish install"
      check_keystroke

    break
    ;;

    *) echo "invalid option $REPLY";;
  esac
done
