#!/bin/bash

set -e
 
ANSIBLE_USER="ansible"

ANSIBLE_HOME="/home/${ANSIBLE_USER}"

SSH_DIR="${ANSIBLE_HOME}/.ssh"

AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
 
AWX_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBEuxy3oDAAUDqVY4pDOISchf5DDrU491kluibL64HqK awx-ansible"
 
echo "=== [1/6] Creating ansible user if it does not exist ==="

if ! id "${ANSIBLE_USER}" &>/dev/null; then

    useradd -m -s /bin/bash "${ANSIBLE_USER}"

fi
 
echo "=== [2/6] Setting up SSH directory ==="

mkdir -p "${SSH_DIR}"

chmod 700 "${SSH_DIR}"

chown "${ANSIBLE_USER}:${ANSIBLE_USER}" "${SSH_DIR}"
 
echo "=== [3/6] Installing AWX public SSH key ==="

touch "${AUTHORIZED_KEYS}"

chmod 600 "${AUTHORIZED_KEYS}"

chown "${ANSIBLE_USER}:${ANSIBLE_USER}" "${AUTHORIZED_KEYS}"
 
if ! grep -Fxq "${AWX_PUBLIC_KEY}" "${AUTHORIZED_KEYS}"; then

    echo "${AWX_PUBLIC_KEY}" >> "${AUTHORIZED_KEYS}"

fi
 
echo "=== [4/6] Configuring passwordless sudo ==="

SUDO_FILE="/etc/sudoers.d/${ANSIBLE_USER}"

echo "${ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDO_FILE}"

chmod 440 "${SUDO_FILE}"
 
echo "=== [5/6] Fixing SELinux context (if applicable) ==="

if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then

    restorecon -Rv "${SSH_DIR}" || true

fi
 
echo "=== [6/6] Ensuring SSH allows key authentication ==="

SSHD_CONFIG="/etc/ssh/sshd_config"
 
grep -q "^PubkeyAuthentication" "${SSHD_CONFIG}" \
&& sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' "${SSHD_CONFIG}" \

    || echo "PubkeyAuthentication yes" >> "${SSHD_CONFIG}"
 
grep -q "^AuthorizedKeysFile" "${SSHD_CONFIG}" \

    || echo "AuthorizedKeysFile .ssh/authorized_keys" >> "${SSHD_CONFIG}"
 
systemctl restart sshd
 
echo "=== ✅ AWX bootstrap completed successfully ==="

 
