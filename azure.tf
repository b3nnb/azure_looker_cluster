provider azurerm {
	version = "~> 1.17.0"
}

variable "count" {default = 2}
variable "domainprefix" {default = "dg"}

resource "azurerm_resource_group" "looker" {
  name     = "lookerrg"
  location = "East US"
}

resource "azurerm_virtual_network" "looker" {
  name                = "lookervn"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

resource "azurerm_subnet" "looker" {
  name                 = "lookersub"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
  virtual_network_name = "${azurerm_virtual_network.looker.name}"
  address_prefix       = "10.0.2.0/24"
}

resource "azurerm_public_ip" "pubip" {
  count = "${var.count}"
  name                         = "lookerpip-${count.index}"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "Dynamic"
  domain_name_label = "${var.domainprefix}-lookerapp${count.index}"
  idle_timeout_in_minutes      = 30

  tags {
    environment = "looker"
  }
}

resource "azurerm_network_interface" "looker" {
  count = "${var.count}"
  name                = "lookernic-${count.index}"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookerconfiguration${count.index}"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${element(azurerm_public_ip.pubip.*.id, count.index)}"
  }
}

resource "azurerm_storage_account" "looker" {
  name                     = "${var.domainprefix}lookerstorage"
  resource_group_name      = "${azurerm_resource_group.looker.name}"
  location                 = "${azurerm_resource_group.looker.location}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags {
    environment = "looker"
  }
}

data "azurerm_storage_account" "looker" {
  depends_on           = ["azurerm_storage_account.looker"]
  name                 = "${var.domainprefix}lookerstorage"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
}

resource "azurerm_storage_container" "looker" {
  name                  = "vhds"
  resource_group_name   = "${azurerm_resource_group.looker.name}"
  storage_account_name  = "${azurerm_storage_account.looker.name}"
  container_access_type = "private"
}

resource "azurerm_storage_share" "looker" {
  name = "lookerfiles"

  resource_group_name  = "${azurerm_resource_group.looker.name}"
  storage_account_name = "${azurerm_storage_account.looker.name}"

  quota = 50
}

resource "azurerm_network_security_group" "looker" {
  name                = "lookersg"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  security_rule {
    name                       = "Port_9999"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags {
    environment = "looker"
  }
}

resource "azurerm_virtual_machine" "looker" {
  name                             = "lookerapp-${count.index}"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${element(azurerm_network_interface.looker.*.id, count.index)}"]
  vm_size                          = "Standard_D2s_V3"
  count                            = "${var.count}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerapp-${count.index}-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/lookerapp-${count.index}-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerapp${count.index}"
    admin_username = "root_looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path = "/home/root_looker/.ssh/authorized_keys"
    }
  }

  connection {
    host = "${var.domainprefix}-lookerapp${count.index}.eastus.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get install libssl-dev -y",
      "sudo apt-get install cifs-utils -y",
      "curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O",
      "sudo mv looker.service /etc/systemd/system/looker.service",
      "sudo chmod 664 /etc/systemd/system/looker.service",
      "echo \"net.ipv4.tcp_keepalive_time=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_intvl=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_probes=5\" | sudo tee -a /etc/sysctl.conf",
      "echo \"looker     soft     nofile     4096\" | sudo tee -a /etc/security/limits.conf",
      "echo \"looker     hard     nofile     4096\" | sudo tee -a /etc/security/limits.conf",
      "sudo groupadd looker",
      "sudo useradd -m -g looker looker",
      "sudo mkdir /home/looker/looker",
      "sudo chown looker:looker /home/looker/looker",
      "cd /home/looker",
      "sudo curl -L -b \"oraclelicense=a\" http://download.oracle.com/otn-pub/java/jdk/8u191-b12/2787e4a523244c269598db4e85c51e0c/jdk-8u191-linux-x64.tar.gz -O",
      "sudo tar zxvf jdk-8u191-linux-x64.tar.gz",
      "sudo chown looker:looker -R jdk1.8.0_191",
      "sudo rm jdk-8u191-linux-x64.tar.gz",
      "cd /home/looker/looker",
      "sudo curl https://s3.amazonaws.com/download.looker.com/aeHee2HiNeekoh3uIu6hec3W/looker-latest.jar -O",
      "sudo mv looker-latest.jar looker.jar",
      "sudo chown looker:looker looker.jar",
      "sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O",
      "sudo chmod 0750 looker",
      "sudo chown looker:looker looker",
      # LOOKERARGS=\"--no-daemonize -d looker-db.yml --clustered -H `ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/'` --shared-storage-dir	/mnt/lookerfiles\"
      "sudo sed -i 's/LOOKERARGS=\"\"/LOOKERARGS=\"--no-daemonize\"/' looker",
      "sudo update-alternatives --install /usr/bin/java java /home/looker/jdk1.8.0_191/bin/java 100",
      "sudo update-alternatives --install /usr/bin/javac javac /home/looker/jdk1.8.0_191/bin/javac 100",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable looker.service",
      "sudo systemctl start looker",
      "sudo mkdir -p /mnt/lookerfiles",
      "sudo mount -t cifs //${azurerm_storage_account.looker.name}.file.core.windows.net/${azurerm_storage_share.looker.name} /mnt/lookerfiles -o vers=3.0,username=${azurerm_storage_account.looker.name},password=${data.azurerm_storage_account.looker.primary_access_key},dir_mode=0777,file_mode=0777,serverino",
    ]
  }

  tags {
    environment = "looker"
  }
}