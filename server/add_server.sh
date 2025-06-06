#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# variables
cert_file="/etc/ssh/ssh_host_rsa_key.pub"
private_key_file="/etc/ssh/ssh_host_rsa_key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/jump_servers.conf"
server_description=""
server_name=""
server_ip=""
ssh_user="root" #maybe?
ssh_port=22
ssh_password=""
selected_users=""

# Parse long options
for arg in "$@"; do
  case $arg in
    --description=*)
      server_description="${arg#*=}"
      shift
      ;;
    --name=*)
      server_name="${arg#*=}"
      shift
      ;;
    --ip=*)
      server_ip="${arg#*=}"
      shift
      ;;
    --user=*)
      ssh_user="${arg#*=}"
      shift
      ;;
    --port=*)
      ssh_port="${arg#*=}"
      shift
      ;;
    --password=*)
      ssh_password="${arg#*=}"
      shift
      ;;
    --users=*)
      selected_users="${arg#*=}"
      shift
      ;;
    *)
      # unknown option
      ;;
  esac
done




# Prompts
if [[ -z "$server_description" ]]; then
  read -p "Enter the server description: " server_description
fi

if [[ -z "$server_name" ]]; then
  read -p "Enter the server name (e.g., webserver1): " server_name
fi

if [[ -z "$server_ip" ]]; then
  read -p "Enter the server IP address: " server_ip
fi

if [[ -z "$ssh_user" ]]; then
  read -p "Enter SSH username for the new server: " ssh_user
  ssh_user=${ssh_user:-root}
fi

if [[ -z "$ssh_port" ]]; then
  read -p "Enter SSH port for the new server (default 22): " ssh_port
  ssh_port=${ssh_port:-22}
fi


# Add server to a configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi


# Copy the certificate to the new server's authorized keys
echo "Copying SSH certificate to the new server..."

if [[ -z "$server_description" ]]; then
   echo "Insert password for $ssh_user@$server_ip:$ssh_port"
   read -r USERPASS
else
   USERPASS="$ssh_password"
fi

#clear 


# check first
if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass not found. Installing..."
    apt update -qq >/dev/null && apt install -y -qq sshpass >/dev/null
    echo "sshpass installed successfully."
    #clear
fi

# run!
timeout 15s bash -c "echo \"$USERPASS\" | sshpass ssh-copy-id -p \"$ssh_port\" -o StrictHostKeyChecking=no -f -i \"$cert_file\" \"$ssh_user@$server_ip\"" >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "Error copying SSH key to remote server."
    echo "Please try manually with the following command:"
    echo "sshpass -p '$USERPASS' ssh-copy-id -p $ssh_port -o StrictHostKeyChecking=no -i $cert_file $ssh_user@$server_ip"
    exit 1
fi


get_server_ipv4(){
	# list of ip servers for checks
	IP_SERVER_1="https://ip.openpanel.com"
	IP_SERVER_2="https://ipv4.openpanel.com"
	IP_SERVER_3="https://ifconfig.me"

	master_ip=$(curl --silent --max-time 2 -4 $IP_SERVER_1 || wget --inet4-only --timeout=2 -qO- $IP_SERVER_2 || curl --silent --max-time 2 -4 $IP_SERVER_3)

	if [ -z "$master_ip" ]; then
	    master_ip=$(ip addr|grep 'inet '|grep global|head -n1|awk '{print $2}'|cut -f1 -d/)
	fi
 }


jail_all_users_on_remote() {
# jail the remote user!
ssh -p "$ssh_port" -o StrictHostKeyChecking=no -i "$private_key_file" "$ssh_user@$server_ip" << EOF
set -e

SCRIPT_PATH="/usr/local/bin/restricted_command.sh"
MASTER_IP="$master_ip"

# Download restricted command script if not present
if [ ! -f "\$SCRIPT_PATH" ]; then
    wget --no-verbose -O "\$SCRIPT_PATH" https://raw.githubusercontent.com/stefanpejcic/openjumpserver/refs/heads/main/behind-jumserver/restricted_command.sh
    chmod +x "\$SCRIPT_PATH"
    chattr +i "\$SCRIPT_PATH"
fi

# Add ForceCommand only if not already added
SSH_CONFIG_BLOCK="##### 🦘 Kangaroo SSH JumpServer #####"
SSH_CONFIG_MATCH="Match User $ssh_user"
if ! grep -q "\$SSH_CONFIG_MATCH" /etc/ssh/sshd_config; then
    bash -c "cat >> /etc/ssh/sshd_config << EOL

\$SSH_CONFIG_BLOCK
\$SSH_CONFIG_MATCH
    ForceCommand \$SCRIPT_PATH
EOL"
    systemctl restart ssh >/dev/null
fi


fi

EOF

if [ $? -ne 0 ]; then
    echo "❌ Error running commands on remote server."
    exit 1
fi



: '
# Add rsyslog forwarding only if not already added
RSYSLOG_LINE="*.* @\${MASTER_IP}:514"
if ! grep -qF "\$RSYSLOG_LINE" /etc/rsyslog.conf; then
    bash -c "cat >> /etc/rsyslog.conf << EOL

\$SSH_CONFIG_BLOCK
\$RSYSLOG_LINE
EOL"
    systemctl restart rsyslog >/dev/null
'

}






# MAIN

get_server_ipv4
jail_all_users_on_remote




add_ssh_kagaroo_for_user() {
    local user=$1
    if [ "$user" == "root" ]; then
        return
    fi
    
    user_home_dir="$(eval echo ~$user)"

    # Ensure .ssh directory exists
    mkdir -p "$user_home_dir/.ssh"
    
    chmod 700 "$user_home_dir/.ssh"

    user_ssh_config="$user_home_dir/.ssh/config"

	# Ensure the user has an SSH config file
	if [ ! -f "$user_ssh_config" ]; then
	    touch "$user_ssh_config"
	    chmod 600 "$user_ssh_config"
	fi

	# add for root
	{
	    echo "# Description: $server_description"
	    echo "Host $server_name"
	    echo "    HostName $server_ip"
	    echo "    User $ssh_user"
	    echo "    Port $ssh_port"
	    echo "    IdentityFile ~/.ssh/jumpserver_key"
	    echo "    CertificateFile $cert_file"
	    echo ""
	} >> "$user_ssh_config"
	
	chown -R "$user:$user" "$user_home_dir/.ssh"


    # Create symlink to the SSH key if it doesn't already exist
    local ssh_key_link="$user_home_dir/.ssh/jumpserver_key"
    if [ ! -L "$ssh_key_link" ]; then
        ln -s "$private_key_file" "$ssh_key_link" >/dev/null 2>&1
    fi

    # Add entries to .bash_profile only if they don't already exist
    local bash_profile="$user_home_dir/.bash_profile"
    touch "$bash_profile"

    grep -qxF "export PATH=$user_home_dir/bin" "$bash_profile" || echo "export PATH=$user_home_dir/bin" >> "$bash_profile"
    grep -qxF "$HOME/kangaroo.sh" "$bash_profile" || echo "$HOME/kangaroo.sh" >> "$bash_profile"
    grep -qxF "logout" "$bash_profile" || echo "logout" >> "$bash_profile"

    # Set ownership and permissions
    chown "$user:$user" "$bash_profile"
    chmod 700 "$bash_profile"
}


# Function to set up SSH certificate-based authentication for existing users
setup_ssh_access() {
    local user=$1
    local authorized_keys_dir="$(eval echo ~$user)/.ssh"
    mkdir -p $authorized_keys_dir
    local authorized_keys_file="$authorized_keys_dir/authorized_keys"
    local user_ssh_config="$authorized_keys_dir/config"
    local user_home_dir="$(eval echo ~$user)"
    cp "$private_key_file" "$user_home_dir/.ssh/jumpserver_key" >/dev/null 2>&1
    ln -s "$SCRIPT_DIR/client.sh" "$user_home_dir/kangaroo.sh" >/dev/null 2>&1
    echo "export PATH=$user_home_dir/bin" >> "/home/$username/.bash_profile"
    echo "$HOME/kangaroo.sh" >> "$user_home_dir/.bash_profile"
    echo "logout" >> "$user_home_dir/.bash_profile"
      
    if [ -f "$cert_file" ]; then
        echo "Setting up SSH access for user $user"
        add_ssh_kagaroo_for_user "$user"
        echo "command=\"ssh -i $cert_file -p $ssh_port $ssh_user@$server_ip\" $cert_file" >> "$authorized_keys_file"
        chown "$user:$user" "$authorized_keys_file" "$user_home_dir/.ssh/jumpserver_key"
        chmod 600 "$authorized_keys_file" "$user_home_dir/.ssh/jumpserver_key"

	if ! grep -q "Host $server_name" "$user_ssh_config"; then
	    {
	        echo "# Description: $server_description"
	        echo "Host $server_name"
	        echo "    HostName $server_ip"
	        echo "    User $ssh_user"
	        echo "    Port $ssh_port"
	        echo "    IdentityFile ~/.ssh/jumpserver_key"
	        echo "    CertificateFile $cert_file"
	        echo ""
	    } >> "$user_ssh_config"
	    echo "Added $server_name to SSH config."
	else
	    echo "Host $server_name already exists in SSH config. Skipping."
	fi


        
    else
        echo "No SSH certificate found."
        exit 1
    fi
}


setup_for_all_users() {
   existing_users=$(awk -F: '($7 == "/bin/bash" || $7 == "/bin/sh") {print $1}' /etc/passwd)
       for user in $existing_users; do
           setup_ssh_access "$user"
       done
}

setup_for_some_users() {
   users="$1"
   for user in $users; do
         if id "$user" &>/dev/null; then
            setup_ssh_access "$user"
         else
            echo "User $user does not exist."
         fi
   done
}

# Set up SSH access for all existing users or specified users
if [[ -z "$selected_users" ]]; then
   read -p "Do you want to set up SSH access for all existing users? (y/n): " add_to_all
   if [[ "$add_to_all" =~ ^[Yy]$ ]]; then
      setup_for_all_users
   else
       read -p "Enter the usernames to setup SSH access for (space-separated): " specific_users
       setup_for_some_users "$specific_users"
   fi
else
   if [[ "$selected_users" == "all" ]]; then
      setup_for_all_users
   else
      setup_for_some_users "$selected_users"
   fi
fi


echo "$server_name $server_ip" >> "$CONFIG_FILE"

#clear
echo "Server $server_name ($server_ip:$ssh_port) added, and SSH access configured using certificates from Kangaroo 🦘"

exit 0
