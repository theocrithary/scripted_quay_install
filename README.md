## Tested with RHEL 9.6

## Install podman
```
sudo yum install -y podman
sudo systemctl stop firewalld
sudo systemctl disable firewalld
```

## Download and create install_quay.sh file
```
curl -LO https://github.com/theocrithary/scripted_quay_install/raw/refs/heads/main/install-quay.sh
sudo chmod +x install_quay.sh
./install_quay.sh
```