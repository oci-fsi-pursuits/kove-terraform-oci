#cloud-config
# ssh-rsa in OCI metadata is rejected by default on some OpenSSH 9+ / Oracle Linux images.
# Also write authorized_keys from Terraform (same bytes as ssh_authorized_keys metadata) so login
# works even if the platform agent skips key injection for opc.
write_files:
  - path: /etc/ssh/sshd_config.d/98-oci-allow-rsa-userkeys.conf
    content: |
      PubkeyAcceptedAlgorithms +ssh-rsa,rsa-sha2-256,rsa-sha2-512
      CASignatureAlgorithms +ssh-rsa
    permissions: '0644'
  - path: /opt/oci-write-authorized-keys.sh
    content: |
      #!/bin/bash
      set -euo pipefail
      U='${head_ssh_user}'
      KEYS_B64='${authorized_keys_b64}'
      id "$$U" &>/dev/null || exit 0
      install -d -m 700 -o "$$U" -g "$$U" "/home/$$U/.ssh"
      printf '%s' "$$KEYS_B64" | base64 -d > "/home/$$U/.ssh/authorized_keys"
      chmod 600 "/home/$$U/.ssh/authorized_keys"
      chown "$$U:$$U" "/home/$$U/.ssh/authorized_keys"
    permissions: '0755'
  - path: /home/${head_ssh_user}/README.md
    content: ${head_home_readme_b64}
    encoding: b64
    owner: ${head_ssh_user}:${head_ssh_user}
    permissions: '0644'
%{ if run_bootstrap ~}
  # Playbooks zip as its own file avoids embedding ~9KB base64 inside the bootstrap script (which is itself base64 in user_data — that double chain blew past OCI's 32KiB metadata limit).
  - path: /opt/oci-hpc-playbooks.zip
    content: ${playbooks_zip_b64}
    encoding: b64
    permissions: '0644'
  - path: /opt/oci-hpc-bootstrap.sh
    content: ${bootstrap_script_b64}
    encoding: b64
    permissions: '0755'
%{ endif ~}
runcmd:
  - bash /opt/oci-write-authorized-keys.sh
  - test -d /etc/ssh/sshd_config.d && (systemctl try-reload-or-restart sshd 2>/dev/null || service sshd reload 2>/dev/null || true)
%{ if run_bootstrap ~}
  - bash /opt/oci-hpc-bootstrap.sh
%{ endif ~}
