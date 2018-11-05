provider azurerm {
	version = "~> 1.17.0"
  # optional: subscription_id 
}

# Update these variables to suit your needs 
variable "instance_type" {default = "Standard_D1_v2"} # Azure instance type
variable "location" {default = "eastus"} # Which Azure region?
variable "domainprefix" {default = "dg"} # Choose a unique prefix to ensure there are no DNS naming collisions

###################################################################
## BEGIN IMPORT BLOCK, see https://www.terraform.io/docs/import/ ##
## You must `terraform import` first!                            ##
###################################################################

resource "azurerm_resource_group" "looker" {
  name     = "lookerrg"
  location = "${var.location}"
}

resource "azurerm_virtual_network" "looker" {
  name                = "lookervn"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

data "azurerm_subnet" "looker" {
  name                 = "lookersub"
  virtual_network_name = "lookervn"
  resource_group_name  = "lookerrg"
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

######################
## END IMPORT BLOCK ##
######################

# Create public IPs to connect to each instance individually
resource "azurerm_public_ip" "pubip" {
  name                         = "lookerpipdev"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "Dynamic"
  domain_name_label            = "${var.domainprefix}-lookerappdev"
  idle_timeout_in_minutes      = 30

  tags {
    environment = "lookerdev"
  }
}

# Create a network interfaces for each of the VMs to use
resource "azurerm_network_interface" "looker" {
  name                = "lookernicdev"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookeripconfigurationdev"
    subnet_id                     = "${data.azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.pubip.id}"
  }
}

# Create the virtual machines themselves!
resource "azurerm_virtual_machine" "looker" {

  name                             = "lookerappdev"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${azurerm_network_interface.looker.id}"]
  vm_size                          = "${var.instance_type}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerappdev-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}vhds/lookerapp-dev-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerappdev"
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
    host = "${var.domainprefix}-lookerappdev.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install libssl-dev -y",
      "sudo apt-get install cifs-utils -y",
      "sudo apt-get install fonts-freefont-otf -y",
      "sudo apt-get install chromium-browser -y",
      "curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O",
      "sudo mv looker.service /etc/systemd/system/looker.service",
      "sudo chmod 664 /etc/systemd/system/looker.service",
      "sudo sed -i 's/TimeoutStartSec=500/TimeoutStartSec=500\nEnvironment=CHROMIUM_PATH=\\/usr\\/bin\\/chromium-browser/' /etc/systemd/system/looker.service",
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
      "sudo curl https://s3.amazonaws.com/download.looker.com/aeHee2HiNeekoh3uIu6hec3W/looker-6.0-latest.jar -O",
      "sudo mv looker-6.0-latest.jar looker.jar",
      "sudo chown looker:looker looker.jar",
      "sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O",
      "sudo chmod 0750 looker",
      "sudo chown looker:looker looker",
      "export CMD=\"sudo sed -i 's/LOOKERARGS=\\\"\\\"/LOOKERARGS=\\\"--no-daemonize\\\"/' /home/looker/looker/looker\"",
      "echo $CMD | bash",
      "sudo update-alternatives --install /usr/bin/java java /home/looker/jdk1.8.0_191/bin/java 100",
      "sudo update-alternatives --install /usr/bin/javac javac /home/looker/jdk1.8.0_191/bin/javac 100",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable looker.service",
      "sudo systemctl start looker",
    ]
  }

  tags {
    environment = "lookerdev"
  }
}

output "Instances" {
  value = "Started ${var.domainprefix}-lookerappdev.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
}