#!/bin/sh

create_ssh_agent_launchagent() {
  local mode="$1"
  local domain_name="$2"
  local agent_sockets_dir="${3:-$HOME/.ssh/agents}"
  if [[ -z "$mode" ]]; then
    echo "Usage: create_ssh_agent_launchagent <mode>"
    echo "mode: sudo | ca"
    return 1
  fi

  if [[ "$mode" != "sudo" && "$mode" != "ca" ]]; then
    echo "Invalid mode: $mode. Choose 'sudo' or 'ca'."
    return 1
  fi

  local label="com.boxforming.ssh-agent.${mode}.${domain_name}"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/${label}.plist"
  local socket_path="$agent_sockets_dir/${mode}.${domain_name}.sock"
  local log_path="$HOME/Library/Logs/${label}.log"
  local askpass_bin="/opt/homebrew/bin/touch2sudo"

  # mkdir -p "$plist_dir" "$HOME/Library/Logs" "$agent_sockets_dir"
  mkdir -p "$agent_sockets_dir"

  if [[ "$mode" == "sudo" ]]; then
    if [[ ! -x "$askpass_bin" ]]; then
      cat <<MSG
Warning: ASKPASS binary not found at $askpass_bin.
Install it from: https://github.com/prbinu/touch2sudo:

brew tap prbinu/touch2sudo
brew install touch2sudo
MSG
    fi
  fi

  cat > "$plist_path" <<EOF
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/bin/ssh-agent</string>
      <string>-a</string>
      <string>${socket_path}</string>
      <string>-d</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${log_path}</string>

    <key>StandardErrorPath</key>
    <string>${log_path}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SSH_ASKPASS</key>
        <string>${askpass_bin}</string>
        <key>SSH_ASKPASS_REQUIRE</key>
        <string>force</string>
    </dict>
</dict>
</plist>
EOF

  echo "Created LaunchAgent plist: ${plist_path}"

  # Try to unload old instance, then load the new one (works on modern macOS).
  if command -v launchctl >/dev/null 2>&1; then
    if launchctl bootout gui/"$UID" "$plist_path" 2>/dev/null; then
      echo "Unloaded existing LaunchAgent (if present)."
    fi

    if launchctl bootstrap gui/"$UID" "$plist_path" 2>/dev/null; then
      echo "Loaded LaunchAgent for $label."
      echo "ssh-agent socket: ${socket_path}"
      return 0
    else
      # fallback to legacy load (older macOS)
      if launchctl load "$plist_path" 2>/dev/null; then
        echo "Loaded LaunchAgent (legacy load) for $label."
        return 0
      fi

      echo "Could not automatically load the LaunchAgent. To load it manually run:"
      echo "  launchctl bootstrap gui/$UID \"${plist_path}\""
      echo "or (older macOS):"
      echo "  launchctl load \"${plist_path}\""
    fi
  else
    echo "launchctl not found; created plist at ${plist_path} but couldn't load it."
  fi
}

gen_password_with_symbols() {
    local base64_data symbols offsets result pos insert_pos
    local base64_len=64
    local static_offset=6
    local min_offset=1
    local num_symbols

    # Calculate how many symbols we need with minimum offsets
    # Formula: (base64_len + num_symbols) / (min_offset + static_offset)
    # Solving: num_symbols = base64_len / (min_offset + static_offset)
    num_symbols="$(( (base64_len + min_offset + static_offset - 1) / (min_offset + static_offset) ))"

    # Generate 40 chars of base64 data (URL-safe)
    base64_data="$(openssl rand -base64 64 | tr '\n+/' '-_' | tr -d '=' | head -c $base64_len)"

    # Generate required number of random non-alphanumeric symbols
    symbols="$(LC_ALL=C tr -dc '!@#%-_?|~=' < /dev/urandom | head -c $num_symbols)"

    # Generate offsets (each 1-3) for all symbols
    offsets="$(LC_ALL=C tr -dc '1-3' < /dev/urandom | head -c $num_symbols)"

    # Build result by inserting symbols
    result="$base64_data"
    pos=0

    for (( i=0; i<num_symbols; i++ )); do
        local symbol="${symbols:$i:1}"
        local offset="${offsets:$i:1}"

        # Calculate insertion position
        insert_pos=$((pos + offset))

        # Stop if we've reached the end of the string
        if [ $insert_pos -gt ${#result} ]; then
            break
        fi

        # Insert symbol at position
        result="${result:0:$insert_pos}${symbol}${result:$insert_pos}"

        # Update position (add static_offset from current insertion position)
        pos=$((insert_pos + static_offset))
    done

    echo "$result"
}

generate_key () {
    local key_path="$1"
    local key_comment="$2"
    local ssh_agent_socket="$3"
    local key_password="$(gen_password_with_symbols)"

    # Security considerations:
    # - Use a strong long password with big entropy.
    # - Do not expose password unless necessary, even for end user.
    # - Ensure the programs are provided by Apple (from /usr/bin)
    # - Disable echo and logs to prevent password leakage for shell (set -x) and expect (log_user, exp_internal)
    (
        set +x
        printf -v key_password_esc "%q" "$key_password"
        /usr/bin/expect << EOF
          log_user 0
          exp_internal 0
          spawn /usr/bin/ssh-keygen -q -t ed25519 -f "$key_path" -C "$key_comment"
          expect "Enter passphrase*"
          send "$key_password_esc\r\n"
          expect "Enter same passphrase*"
          send "$key_password_esc\r\n"
          expect eof
EOF
        # echo "$key_password"
        env ${ssh_agent_socket:+SSH_AUTH_SOCK="$ssh_agent_socket"} /usr/bin/expect << EOF
          log_user 0
          exp_internal 0
          spawn /usr/bin/ssh-add --apple-use-keychain -c "$key_path"
          expect "Enter passphrase*"
          send "$key_password_esc\r\n"
          expect eof
EOF
    )

}

sign_key() {
    local key_path="$1"
    local ca_pk_path="$2"
    local ca_agent_socket="$3"
    local identity="$4"
    local expires="$5"

    SSH_AUTH_SOCK="$ca_agent_socket" /usr/bin/ssh-keygen -s "$ca_pk_path" -U -I "$identity" -n "$identity" -V "-5m:$expires" "$key_path"

}

domain_name="$1"
identity="$2"
expires="${3:-+30d}"
key_name="${4:-$domain_name}"

if [[ -z "$identity" ]] || [[ -z "$domain_name" ]] ; then
    echo "Usage: $0 <domain_name> <identity> [expires] [key_name]"
    exit 1
fi

agent_sockets_dir="$HOME/.ssh/agents"
ca_agent_socket="$agent_sockets_dir/ca.${domain_name}.sock"
ca_pk_path="$HOME/.ssh/ca=${domain_name}"
sudo_agent_socket="$agent_sockets_dir/sudo.${domain_name}.sock"
sudo_pk_path="$HOME/.ssh/sudo=${domain_name}"
pk_path="$HOME/.ssh/${key_name}"

# default ssh agent env vars
# ssh-agent -s | head -n 2 | cut -d ';' -f 1

if ! SSH_AUTH_SOCK="$ca_agent_socket" /usr/bin/ssh-add -L 2>&1 >/dev/null ; then
    create_ssh_agent_launchagent "ca" "$domain_name" "$agent_sockets_dir"
fi

if [[ ! -f "$ca_pk_path" ]] ; then
    generate_key "$ca_pk_path" "${domain_name} certificate authority key" "$ca_agent_socket"
fi

if ! SSH_AUTH_SOCK="$sudo_agent_socket" /usr/bin/ssh-add -L 2>&1 >/dev/null ; then
    create_ssh_agent_launchagent "sudo" "$domain_name" "$agent_sockets_dir"
fi

if [[ ! -f "$sudo_pk_path" ]] ; then
    generate_key "$sudo_pk_path" "${domain_name} sudo key" "$sudo_agent_socket"
fi

if [[ ! -f "$pk_path" ]] ; then
    generate_key "$pk_path" "${identity}@${key_name}"
fi

sign_key "$pk_path" "$ca_pk_path" "$ca_agent_socket" "$identity" "$expires"
