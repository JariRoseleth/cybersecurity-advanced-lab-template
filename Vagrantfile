#HOST_ONLY_NETWORK = "vboxnet1" # Typically on Linux/Mac
HOST_ONLY_NETWORK = "VirtualBox Host-Only Ethernet Adapter #2" # Windows fake internet
#HOST_ONLY_NETWORK = "VirtualBox Host-Only Ethernet Adapter #2" # Typically on Windows

Vagrant.configure("2") do |config|
    config.vm.define "companyrouter" do |host|
        host.vm.box = "ubuntu/jammy64"
        host.vm.hostname = "companyrouter"

        host.vm.network "private_network", ip: "192.168.62.253", netmask: "255.255.255.0", name: HOST_ONLY_NETWORK
        host.vm.network "private_network", ip: "172.30.255.254", netmask: "255.255.0.0", virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "companyrouter"
            v.cpus = "1"
            v.memory = "1024"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # Default gateway
            nmcli connection modify "System eth1" ipv4.gateway 192.168.62.254
            systemctl restart NetworkManager
        SHELL
    end

    config.vm.define "dns" do |host|
        host.vm.box = "generic/alpine318"
        host.vm.hostname = "dns"

        host.vm.network "private_network", ip: "172.30.0.4", netmask: "255.255.255.0", virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "dns"
            v.cpus = "1"
            v.memory = "256"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # For ansible
            apk --no-cache add python3

            # Default gateway
            echo "gateway 172.30.255.254" >> /etc/network/interfaces
            service networking restart
        SHELL
    end

    config.vm.define "web" do |host|
        host.vm.box = "ubuntu/jammy64"
        host.vm.hostname = "web"

        host.vm.network "private_network", ip: "172.30.0.10", netmask: "255.255.255.0", virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "web"
            v.cpus = "1"
            v.memory = "1024"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # Default gateway
            nmcli connection modify "System eth1" ipv4.gateway 172.30.255.254
            systemctl restart NetworkManager
        SHELL
    end

    config.vm.define "database" do |host|
        host.vm.box = "generic/alpine318"
        host.vm.hostname = "database"

        host.vm.network "private_network", ip: "172.30.0.15", netmask: "255.255.255.0", virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "database"
            v.cpus = "1"
            v.memory = "256"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # For ansible
            apk --no-cache add python3

            # Default gateway
            echo "gateway 172.30.255.254" >> /etc/network/interfaces
            service networking restart
        SHELL
    end

    config.vm.define "employee" do |host|
        host.vm.box = "generic/alpine318"
        host.vm.hostname = "employee"

        # TODO DHCP
        host.vm.network "private_network", ip: "172.30.0.123", netmask: "255.255.255.0", virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "employee"
            v.cpus = "1"
            v.memory = "256"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # For ansible
            apk --no-cache add python3

            # Default gateway
            echo "gateway 172.30.255.254" >> /etc/network/interfaces
            service networking restart
        SHELL
    end

    config.vm.define "isprouter" do |host|
        host.vm.box = "generic/alpine318"
        host.vm.hostname = "isprouter"

        host.vm.network "private_network", ip: "192.168.62.254", netmask: "255.255.255.0", name: HOST_ONLY_NETWORK

        host.vm.provider :virtualbox do |v|
            v.name = "isprouter"
            v.cpus = "1"
            v.memory = "256"
        end

        host.vm.provision "shell", inline: <<-SHELL
            apk --no-cache add python3 # For ansible
        SHELL
        host.vm.provision "file", source: "ansible", destination: "$HOME/ansible"
    end

    config.vm.define "homerouter" do |host|
        host.vm.box = "ubuntu/jammy64"
        host.vm.hostname = "homerouter"

        host.vm.network "private_network", ip: "192.168.62.42", netmask: "255.255.255.0", name: HOST_ONLY_NETWORK
        host.vm.network "private_network", ip: "172.10.10.254", netmask: "255.255.255.0", virtualbox__intnet: "employee-home-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "homerouter"
            v.cpus = "1"
            v.memory = "1024"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # Default gateway
            nmcli connection modify "System eth1" ipv4.gateway 192.168.62.254
            systemctl restart NetworkManager
        SHELL
    end

    config.vm.define "remote-employee" do |host|
        host.vm.box = "ubuntu/jammy64"
        host.vm.hostname = "remote-employee"

        host.vm.network "private_network", ip: "172.10.10.123", netmask: "255.255.255.0", virtualbox__intnet: "employee-home-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "remote-employee"
            v.cpus = "1"
            v.memory = "1024"
        end

        host.vm.provision "shell", inline: <<-SHELL
            # Default gateway
            nmcli connection modify "System eth1" ipv4.gateway 172.10.10.254
            systemctl restart NetworkManager
        SHELL
    end

    # BEGIN LAB 7 SIEM
    config.vm.define "siem" do |host|
        host.vm.box = "ubuntu/jammy64"
        host.vm.box_version = "20241002.0.0"
        host.vm.box_check_update = false
        host.vm.hostname = "siem"
        host.vm.boot_timeout = 900

        host.vm.network "private_network", ip: "172.30.0.20", netmask: "255.255.255.0", virtualbox__intnet: "internal-company-lan"
        host.vm.network "forwarded_port", guest: 443, host: 8443, host_ip: "127.0.0.1", protocol: "tcp", auto_correct: false

        host.vm.disk :disk, size: "50GB", primary: true

        host.vm.provider :virtualbox do |v|
            v.name = "siem"
            v.cpus = 4
            v.memory = 4608
        end

        host.vm.provision "shell", path: "scripts/lab7/provision-siem.sh", privileged: true
    end
    # END LAB 7 SIEM
    # BEGIN LAB 7 LINUX ENDPOINT
    config.vm.define "lab7-linux" do |host|
        host.vm.box = "almalinux/9"
        host.vm.box_version = "9.4.20240805"
        host.vm.hostname = "lab7-linux"
        host.vm.boot_timeout = 600

        host.vm.network "private_network",
            ip: "172.30.0.21",
            netmask: "255.255.255.0",
            virtualbox__intnet: "internal-company-lan"

        host.vm.provider :virtualbox do |v|
            v.name = "lab7-linux"
            v.cpus = "1"
            v.memory = "1024"
        end

        host.vm.provision "shell",
            path: "scripts/lab7/provision-linux-endpoint.sh",
            privileged: true
    end
    # END LAB 7 LINUX ENDPOINT
    # BEGIN LAB 7 WINDOWS ENDPOINT
    config.vm.define "lab7-windows" do |host|
        host.vm.box = "gusztavvargadr/windows-10-22h2-enterprise"
        host.vm.box_version = "2506.0.0"
        # Windows hostname intentionally managed outside Vagrant

        host.vm.guest = :windows
        host.vm.communicator = "winrm"
        host.vm.boot_timeout = 1800

        host.winrm.username = "vagrant"
        host.winrm.password = "vagrant"
        host.winrm.timeout = 1800

        host.vm.network "private_network",
            ip: "172.30.0.22",
            netmask: "255.255.255.0",
            virtualbox__intnet: "internal-company-lan"

        host.vm.synced_folder ".", "C:/vagrant", disabled: true

        host.vm.provider :virtualbox do |v|
            v.name = "lab7-windows"
            v.cpus = 2
            v.memory = 2560
        end
    end
    # END LAB 7 WINDOWS ENDPOINT
end
