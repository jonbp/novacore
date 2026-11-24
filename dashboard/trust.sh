#!/bin/sh
#
# Trust the Novacore Local CA on this machine (macOS or Linux), so browsers
# accept the HTTPS certificates of the Novacore server it came from.
# Downloaded from that server's dashboard. Run it with: sh novacore-trust.sh

set -eu

FINGERPRINT='{{CA_SHA256}}'

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'EOF'
{{CA_PEM}}
EOF

echo "Novacore Local CA"
echo "SHA-256 fingerprint: $FINGERPRINT"
echo "Check that it matches the one on the dashboard, or on the server:"
echo "  openssl x509 -in data/certs/ca.crt -noout -fingerprint -sha256"
printf "Trust this CA? [y/N] "
read -r answer </dev/tty
case $answer in y|Y|yes|YES) ;; *) echo "Nothing changed."; exit 1 ;; esac

if [ "$(uname)" = Darwin ]; then
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$tmp"
elif [ -d /etc/pki/ca-trust/source/anchors ]; then   # Fedora, RHEL
    sudo cp "$tmp" /etc/pki/ca-trust/source/anchors/novacore.crt
    sudo chmod 644 /etc/pki/ca-trust/source/anchors/novacore.crt
    sudo update-ca-trust
elif [ -d /usr/local/share/ca-certificates ]; then   # Debian, Ubuntu
    sudo cp "$tmp" /usr/local/share/ca-certificates/novacore.crt
    sudo chmod 644 /usr/local/share/ca-certificates/novacore.crt
    sudo update-ca-certificates
elif command -v trust >/dev/null 2>&1; then         # Arch
    sudo trust anchor --store "$tmp"
else
    echo "Don't know how to update the trust store here. Import the CA into your browser by hand." >&2
    exit 1
fi
echo "Added to the system trust store"

# Chrome and Chromium on Linux keep their own certificate database.
if command -v certutil >/dev/null 2>&1 && [ -d "$HOME/.pki/nssdb" ]; then
    certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n "Novacore Local CA" -i "$tmp"
    echo "Added to Chrome's certificate store"
fi

echo "Done. Restart your browser if it was already open."
