## Tested with RHEL 9.6

## Install podman
sudo yum install -y podman
sudo systemctl stop firewalld
sudo systemctl disable firewalld

## Download and create install_quay.sh file
curl -LO https://github.com/theocrithary/scripted_quay_install/raw/refs/heads/main/install-quay.sh
sudo chmod +x install_quay.sh
./install_quay.sh

## If running docker on Mac OS
openssl s_client -showcerts -connect quay.lab.local:443 < /dev/null | sed -n '1,/-----END CERTIFICATE-----/p' > registry.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain registry.crt

## Restart Docker
