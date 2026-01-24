#!/usr/bin/env bash

set -e

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root or with sudo"
   exit 1
fi

apt install sudo libpam-ssh-agent-auth -y

create_or_modify_user () {
    local USER_NAME="$1"

    if ! id "$USER_NAME" &>/dev/null; then
        useradd -m -s /bin/bash -U -G sudo "$USER_NAME"
        # adduser --shell /bin/bash --disabled-password "$USER_NAME"
    fi

    if ! groups $USER_NAME | grep -q sudo; then
        usermod -a -G sudo "$USER_NAME"
    fi
}

configure_sshd () {
    local PUBLIC_KEY="$1"
    local ETC_SSH_TRUSTED_KEYS="/etc/ssh/trusted_user_ca_keys"
    local ETC_SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
    local CONFIG_FILE_CA="$ETC_SSHD_CONFIG_D/01_trusted_user_ca.conf"
    local CONFIG_FILE_SUDO="$ETC_SSHD_CONFIG_D/02_sudo_pam_socket.conf"

    if [[ ! -f "$ETC_SSH_TRUSTED_KEYS" ]] || ! grep -Fxq "$PUBLIC_KEY" "$ETC_SSH_TRUSTED_KEYS"; then
        echo "$PUBLIC_KEY" >> "$ETC_SSH_TRUSTED_KEYS"
    fi
    mkdir -p "$ETC_SSHD_CONFIG_D"
    if [[ ! -f "$CONFIG_FILE_CA" ]]; then
        echo "TrustedUserCAKeys $ETC_SSH_TRUSTED_KEYS" > "$CONFIG_FILE_CA"
    else
        if grep -q "TrustedUserCAKeys" "$CONFIG_FILE_CA" 2>/dev/null; then
            if ! grep -q "TrustedUserCAKeys $ETC_SSH_TRUSTED_KEYS" "$CONFIG_FILE_CA" 2>/dev/null; then
                echo "Warning: $CONFIG_FILE_CA exists but directive TrustedUserCAKeys have unexpected value"
                echo "Manual review recommended"
            fi
        else
            echo "TrustedUserCAKeys $ETC_SSH_TRUSTED_KEYS" >> "$CONFIG_FILE_CA"
            echo "Warning: $CONFIG_FILE_CA exists but directive TrustedUserCAKeys is missing, fixed"
        fi
    fi

    if [[ ! -f "$CONFIG_FILE_SUDO" ]]; then
        echo "StreamLocalBindUnlink yes" > "$CONFIG_FILE_SUDO"
    fi

    if ! sshd -t; then
        echo "SSH configuration check failed"
        exit 1
    fi

    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
        echo "SSH service reloaded successfully"
    elif service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
        echo "SSH service reloaded successfully"
    else
        echo "Failed to reload SSH service"
        exit 1
    fi

}

configure_sudo () {
    local KEEP_SOCK_FILE=/etc/sudoers.d/00_keep_ssh_auth_sock
    echo 'Defaults env_keep += "SSH_AUTH_SOCK"' >"$KEEP_SOCK_FILE"
    chmod 0440 "$KEEP_SOCK_FILE"

    # RHEL/CentOS and derivatives
    # auth     sufficient    pam_ssh_agent_auth.so file=/etc/security/authorized_keys
    local PAMD_SUDO=/etc/pam.d/sudo
    if ! grep -q 'pam_ssh_agent_auth.so' "$PAMD_SUDO" 2>/dev/null; then
        if grep -q '^@include common-auth' "$PAMD_SUDO" 2>/dev/null; then
            sed -i '/^@include common-auth.*/i auth sufficient pam_ssh_agent_auth.so file=%h/.ssh/authorized_keys' "$PAMD_SUDO"
        else
            echo "Warning: Cannot find '@include common-auth' in $PAMD_SUDO"
            echo "Manual PAM configuration may be required"
        fi
    fi
}

configure_user_ssh_access () {
    local USER_NAME="$1"
    local PUBLIC_KEY="$2"
    local USER_HOME="/home/$USER_NAME"
    local DOT_SSH_DIR="$USER_HOME/.ssh"
    local AUTH_KEYS="$DOT_SSH_DIR/authorized_keys"

    mkdir -p "$DOT_SSH_DIR"
    chmod 700 "$DOT_SSH_DIR"
    chown -R $USER_NAME:$USER_NAME "$DOT_SSH_DIR"

    if [ -f "$AUTH_KEYS" ]; then
        if ! grep -q "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null; then
            echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
        fi
    else
        echo "$PUBLIC_KEY" > "$AUTH_KEYS"
    fi

    chmod 600 "$AUTH_KEYS"
    chown -R $USER_NAME:$USER_NAME "$AUTH_KEYS"

    PROFILE="$USER_HOME/.profile"
    SNIPPET_MARKER="# ssh-pam: set SSH_AUTH_SOCK to latest ssh-pam socket"
    if [ ! -f "$PROFILE" ]; then
        # Ensure profile exists and is owned by the user
        touch "$PROFILE"
        chown "$USER_NAME:$USER_NAME" "$PROFILE"
        chmod 644 "$PROFILE"
    fi

    if ! grep -Fq "$SNIPPET_MARKER" "$PROFILE" 2>/dev/null; then
        cat >> "$PROFILE" <<EOF
$SNIPPET_MARKER
EOF
        cat >> "$PROFILE" <<'EOF'
#if [ -z "$SSH_AUTH_SOCK" ]; then
LATEST_SOCK=$(ls -t /tmp/ssh-pam.$USER.*.sock 2>/dev/null | head -n 1)
if [ -n "$LATEST_SOCK" ] && [ -S "$LATEST_SOCK" ]; then
    export SSH_AUTH_SOCK="$LATEST_SOCK"
fi
#fi
EOF
    fi
}

if [[ $# -eq 3 ]]; then
    USER_NAME="$1"
    CA_PUBLIC_KEY="$2"
    SUDO_PUBLIC_KEY="$3"
elif [[ $# -eq 2 ]]; then
    if [[ -z "$SUDO_USER" ]]; then
        echo "Error: Cannot determine sudo user"
        exit 1
    fi
    USER_NAME="$SUDO_USER"
    CA_PUBLIC_KEY="$1"
    SUDO_PUBLIC_KEY="$2"
else
    echo "Usage as user: sudo $0 <ssh_ca_public_key>"
    echo "Usage as root: $0 <user> <ssh_ca_public_key>"
    exit 1
fi

create_or_modify_user "$USER_NAME"
configure_sshd "$CA_PUBLIC_KEY"
configure_sudo
configure_user_ssh_access "$USER_NAME"  "$SUDO_PUBLIC_KEY"


# if [ -t 0 ] ; then
#     read -p "Public key: " PUB_KEY
#     if [ -z "$PUB_KEY" ] ; then
#         echo "Empty public key."
#         exit 1;
#     fi
# else
#     echo "Script intended to be run interactively"
#     exit 1
# fi

# echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/disable_password_login.conf

# SSH_PERMITS_PASSWORDS=$(sshd -T | grep -E -i 'passwordauth|permitroot' | grep yes)
